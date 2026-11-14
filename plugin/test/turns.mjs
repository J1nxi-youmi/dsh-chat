/**
 * 回合调度：不同会话并行，同一会话串行。
 *
 * 以前同一个会话连发两条会同时跑：回复交错、历史对不上；
 * 而不同会话本来就该各跑各的。这个测试把两件事都钉住。
 *
 * 跑法：node test/turns.mjs
 */
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('..', import.meta.url));
const SERVER = join(HERE, 'server.mjs');
const UPSTREAM_PORT = 18890;
const CHAT_PORT = 18892;
const TOKEN = 'test-token';
/** 假上游每次回答要花的时间：用它来量并行还是排队。 */
const DELAY = 300;

/** 上游调用记录，用来判断谁先谁后、有没有重叠。 */
const calls = [];
let active = 0;
let peak = 0;

const upstream = createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  let body = {};
  try {
    body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    /* 不是 JSON 就当空请求 */
  }
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const lastUser = [...messages].reverse().find((item) => item.role === 'user')?.content ?? '';
  const call = { text: lastUser, start: Date.now(), end: 0 };
  calls.push(call);
  active += 1;
  peak = Math.max(peak, active);
  await new Promise((resolve) => setTimeout(resolve, DELAY));
  active -= 1;
  call.end = Date.now();
  const payload = JSON.stringify({ choices: [{ message: { content: `echo:${lastUser}` } }] });
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(payload);
});

await new Promise((resolve) => upstream.listen(UPSTREAM_PORT, '127.0.0.1', resolve));

const dataDir = await mkdtemp(join(tmpdir(), 'dsh-chat-turns-'));
const child = spawn(process.execPath, [SERVER], {
  env: {
    ...process.env,
    CHAT_HOST: '127.0.0.1',
    CHAT_PORT: String(CHAT_PORT),
    CHAT_TOKEN: TOKEN,
    CHAT_BASE_URL: `http://127.0.0.1:${UPSTREAM_PORT}/v1`,
    CHAT_DATA_DIR: dataDir,
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
child.stderr.on('data', (chunk) => process.stderr.write(`[server] ${chunk}`));

const waitFor = async (url, tries = 80) => {
  for (let index = 0; index < tries; index += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {
      /* 还没起来 */
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`等不到 ${url}`);
};

const api = async (method, path, body) => {
  const response = await fetch(`http://127.0.0.1:${CHAT_PORT}${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  return { status: response.status, data };
};

const newConversation = async () => (await api('POST', '/api/conversations')).data.conversation;
const say = (id, text, clientMessageId) =>
  api('POST', `/api/conversations/${id}/messages`, { text, clientMessageId });

let failed = 0;
const check = (name, condition, detail = '') => {
  if (!condition) failed += 1;
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${detail ? `  · ${detail}` : ''}`);
};

try {
  await waitFor(`http://127.0.0.1:${CHAT_PORT}/healthz`);

  // 1) 两个会话同时发：应该并排跑，用时接近一次 DELAY。
  {
    const [first, second] = await Promise.all([newConversation(), newConversation()]);
    calls.length = 0;
    peak = 0;
    const began = Date.now();
    const [left, right] = await Promise.all([
      say(first.id, 'conversation A', 'a1'),
      say(second.id, 'conversation B', 'b1'),
    ]);
    const elapsed = Date.now() - began;
    check('两个会话都能回', left.status === 200 && right.status === 200, `${left.status}/${right.status}`);
    check('不同会话并行', peak === 2, `同时在上游的请求数峰值=${peak}`);
    check('用时接近一次上游', elapsed < DELAY * 1.8, `${elapsed}ms（一次上游 ${DELAY}ms）`);
  }

  // 2) 同一个会话连发两条：应该排队，第二条等第一条跑完。
  {
    const conversation = await newConversation();
    calls.length = 0;
    peak = 0;
    const began = Date.now();
    const [first, second] = await Promise.all([
      say(conversation.id, 'first', 'c1'),
      say(conversation.id, 'second', 'c2'),
    ]);
    const elapsed = Date.now() - began;
    check('同会话两条都能回', first.status === 200 && second.status === 200, `${first.status}/${second.status}`);
    check('同一会话不重叠', peak === 1, `同时在上游的请求数峰值=${peak}`);
    check('按发出顺序跑', calls[0]?.text === 'first' && calls[1]?.text === 'second', calls.map((call) => call.text).join(' → '));
    check('第二条等第一条结束', Boolean(calls[1] && calls[1].start >= calls[0].end), `${calls[1]?.start - calls[0]?.end}ms 间隔`);
    check('用时接近两次上游', elapsed >= DELAY * 1.8, `${elapsed}ms`);
  }

  // 3) 两条消息都落库，seq 不乱。
  {
    const conversation = await newConversation();
    await say(conversation.id, 'one', 'd1');
    await say(conversation.id, 'two', 'd2');
    const detail = await api('GET', `/api/conversations/${conversation.id}`);
    const seqs = detail.data.conversation.messages.map((message) => message.seq);
    const sorted = [...seqs].sort((a, b) => a - b);
    check('seq 单调递增', JSON.stringify(seqs) === JSON.stringify(sorted), seqs.join(','));
    check('消息没有丢', detail.data.conversation.messages.length === 4, `${detail.data.conversation.messages.length} 条`);
  }
} finally {
  child.kill();
  upstream.close();
  await rm(dataDir, { recursive: true, force: true }).catch(() => {});
}

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
