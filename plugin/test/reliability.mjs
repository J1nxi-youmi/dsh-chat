/**
 * 可靠投递自测：seq / clientMessageId 幂等 / ack / 断线重发 / since 增量。
 *
 * 跑法（需要 node 22+，仓库里自带的 node 就行）：
 *   node test/reliability.mjs
 *
 * 它会：
 *   1. 起一个假上游（OpenAI 兼容），可以切换到「故意失败」模式；
 *   2. 用临时数据目录起一份聊天服务；
 *   3. 断言：正常发送、重复发送幂等、失败后重发、并发重复返回 202、since 增量、push 的 seq。
 */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('..', import.meta.url));
const SERVER = join(HERE, 'server.mjs');
const UPSTREAM_PORT = 18790;
const CHAT_PORT = 18792;
const TOKEN = 'test-token';

let upstreamFails = false;
let upstreamDelayMs = 0;
let upstreamCalls = 0;

const upstream = createServer(async (req, res) => {
  upstreamCalls += 1;
  if (upstreamDelayMs) await new Promise((resolve) => setTimeout(resolve, upstreamDelayMs));
  if (upstreamFails) {
    res.writeHead(500, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'boom' }));
  }
  const body = JSON.stringify({
    choices: [{ message: { content: JSON.stringify({ bubbles: ['第一句', '第二句'] }) } }],
  });
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(body);
});

const waitFor = async (url, tries = 60) => {
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

const results = [];
function check(name, condition, detail = '') {
  results.push({ name, ok: Boolean(condition), detail });
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${detail ? `  — ${detail}` : ''}`);
}

const api = async (path, options = {}) => {
  const response = await fetch(`http://127.0.0.1:${CHAT_PORT}${path}`, {
    ...options,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${TOKEN}`,
      ...(options.headers ?? {}),
    },
  });
  const data = await response.json().catch(() => ({}));
  return { status: response.status, data };
};

const dataDir = await mkdtemp(join(tmpdir(), 'dsh-chat-test-'));
const child = spawn(process.execPath, [SERVER], {
  env: {
    ...process.env,
    CHAT_HOST: '127.0.0.1',
    CHAT_PORT: String(CHAT_PORT),
    CHAT_TOKEN: TOKEN,
    CHAT_BASE_URL: `http://127.0.0.1:${UPSTREAM_PORT}/v1`,
    CHAT_API_KEY: 'x',
    CHAT_DATA_DIR: dataDir,
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
child.stdout.on('data', () => {});
child.stderr.on('data', (chunk) => console.error('[server]', String(chunk).trim()));

try {
  await new Promise((resolve) => upstream.listen(UPSTREAM_PORT, '127.0.0.1', resolve));
  await waitFor(`http://127.0.0.1:${CHAT_PORT}/healthz`);

  // 1) 建会话
  const created = await api('/api/conversations', { method: 'POST', body: '{}' });
  const conversationId = created.data.conversation.id;
  check('建会话', created.status === 200 && Boolean(conversationId));

  // 2) 正常发送：拿 ack + seq
  const first = await api(`/api/conversations/${conversationId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ text: '你好', clientMessageId: 'c1' }),
  });
  check('发送返回 ack', first.status === 200 && first.data.ack?.clientMessageId === 'c1', JSON.stringify(first.data.ack));
  check('用户消息 seq=1', first.data.user?.seq === 1, `seq=${first.data.user?.seq}`);
  check('回复带 seq', (first.data.replies ?? []).every((item) => Number(item.seq) > 1));
  const firstReplyCount = first.data.replies?.length ?? 0;

  // 3) 同一 clientMessageId 重发：幂等，不再调模型
  const callsBefore = upstreamCalls;
  const duplicate = await api(`/api/conversations/${conversationId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ text: '你好', clientMessageId: 'c1' }),
  });
  check('重发返回 duplicate', duplicate.status === 200 && duplicate.data.duplicate === true);
  check('重发 seq 不变', duplicate.data.ack?.seq === first.data.ack?.seq);
  check('重发不重复调模型', upstreamCalls === callsBefore, `calls ${callsBefore} -> ${upstreamCalls}`);
  check('重发回放同样数量的回复', (duplicate.data.replies ?? []).length === firstReplyCount);

  // 4) 上游失败 → 502；再重发同一条 → 复用用户消息、只补回复
  upstreamFails = true;
  const failed = await api(`/api/conversations/${conversationId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ text: '会失败的一条', clientMessageId: 'c2' }),
  });
  check('上游失败返回 502', failed.status === 502, `status=${failed.status}`);
  check('失败也落库（有 ack）', Number(failed.data.ack?.seq) > 0);

  upstreamFails = false;
  const retried = await api(`/api/conversations/${conversationId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ text: '会失败的一条', clientMessageId: 'c2' }),
  });
  check('重发后成功', retried.status === 200 && retried.data.ok === true, `status=${retried.status}`);
  check('重发复用同一条用户消息', retried.data.user?.id === failed.data.user?.id);
  check('重发只补回复、不新增用户消息', retried.data.user?.seq === failed.data.user?.seq);

  // 5) 并发生成期间重复提交 → 202 pending
  upstreamDelayMs = 400;
  const slow = api(`/api/conversations/${conversationId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ text: '慢一点的一条', clientMessageId: 'c3' }),
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  const pending = await api(`/api/conversations/${conversationId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ text: '慢一点的一条', clientMessageId: 'c3' }),
  });
  const slowResult = await slow;
  upstreamDelayMs = 0;
  check('生成中重发返回 202', pending.status === 202 && pending.data.pending === true, `status=${pending.status}`);
  check('原请求最后成功', slowResult.status === 200);

  // 6) since 增量
  const incremental = await api(`/api/conversations/${conversationId}/messages?since=1`);
  check('since=1 只回 seq>1', incremental.data.messages.every((item) => Number(item.seq) > 1));
  check('since 回包带 lastSeq', Number(incremental.data.lastSeq) >= 2, `lastSeq=${incremental.data.lastSeq}`);

  // 7) push 也分配 seq
  const pushed = await api('/api/push', {
    method: 'POST',
    body: JSON.stringify({ conversationId, text: '主动推来的一条' }),
  });
  check('push 带 seq', Number(pushed.data.message?.seq) > Number(incremental.data.lastSeq));

  // 8) 会话摘要带 lastSeq（客户端用它当游标）
  const list = await api('/api/conversations');
  const summary = list.data.conversations.find((item) => item.id === conversationId);
  check('会话摘要带 lastSeq', Number(summary?.lastSeq) === Number(pushed.data.message?.seq));
} finally {
  child.kill();
  await new Promise((resolve) => upstream.close(resolve));
  await rm(dataDir, { recursive: true, force: true }).catch(() => {});
}

const failedCount = results.filter((item) => !item.ok).length;
console.log(`\n${results.length - failedCount}/${results.length} 通过`);
process.exit(failedCount === 0 ? 0 : 1);
