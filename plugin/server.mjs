/**
 * dsh-chat：自托管的聊天端。
 *
 * 一个进程、零依赖：手机浏览器打开就是聊天界面，支持文字、图片、文件、语音。
 * 回复来自任意 OpenAI 兼容后端——可以是本机的 DSH 桥（127.0.0.1:8790/v1），
 * 也可以是 https://api.deepseek.com，取决于 config.json / 环境变量。
 */
import { createServer } from 'node:http';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';

const execAsync = promisify(exec);
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const PUBLIC_DIR = join(HERE, 'public');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.webm': 'audio/webm',
  '.ogg': 'audio/ogg',
  '.mp4': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.txt': 'text/plain; charset=utf-8',
};

const DEFAULT_SYSTEM =
  '你是我在自建聊天端里的对话伙伴。回答用中文，简洁、自然，不要使用 Markdown 标题和表格。';

/** 读配置：config.json 优先，环境变量覆盖。 */
async function loadConfig() {
  let saved = {};
  try {
    saved = JSON.parse(await readFile(join(HERE, 'config.json'), 'utf8'));
  } catch {
    /* 没有配置文件就用默认值 */
  }
  const env = process.env;
  return {
    host: env.CHAT_HOST ?? saved.host ?? '0.0.0.0',
    port: Number(env.CHAT_PORT ?? saved.port ?? 8792),
    token: String(env.CHAT_TOKEN ?? saved.token ?? '').trim(),
    baseUrl: String(env.CHAT_BASE_URL ?? saved.baseUrl ?? 'http://127.0.0.1:8790/v1').replace(/\/+$/, ''),
    apiKey: String(env.CHAT_API_KEY ?? saved.apiKey ?? '').trim(),
    model: String(env.CHAT_MODEL ?? saved.model ?? 'dsh'),
    sessionPerConversation: saved.sessionPerConversation !== false,
    fetchLinks: saved.fetchLinks === true,
    asrCommand: String(saved.asrCommand ?? '').trim(),
    bubbles: saved.bubbles !== false,
    systemPrompt: String(saved.systemPrompt ?? DEFAULT_SYSTEM),
    dataDir: env.CHAT_DATA_DIR ?? saved.dataDir ?? join(HERE, 'data'),
    maxUploadBytes: Number(saved.maxUploadBytes ?? 96 * 1024 * 1024),
    historyLimit: Number(saved.historyLimit ?? 24),
    upstreamTimeoutMs: Number(saved.upstreamTimeoutMs ?? 180_000),
  };
}

const config = await loadConfig();
if (!config.token) {
  config.token = randomUUID().replace(/-/g, '').slice(0, 24);
  console.log(`[chat] 没配 token，随机生成了一个：${config.token}`);
}
const MEDIA_DIR = join(config.dataDir, 'media');
await mkdir(MEDIA_DIR, { recursive: true });

/** 会话与媒体的持久化：一个 JSON 文件，改完就落盘。 */
const db = {
  conversations: [],
  media: {},
  async load() {
    try {
      const raw = JSON.parse(await readFile(join(config.dataDir, 'db.json'), 'utf8'));
      this.conversations = Array.isArray(raw.conversations) ? raw.conversations : [];
      this.media = raw.media && typeof raw.media === 'object' ? raw.media : {};
    } catch {
      /* 第一次运行 */
    }
    // 老数据没有 seq：按现有顺序补一遍，保证「since=」增量接口对历史也成立。
    for (const conversation of this.conversations) {
      conversation.messages = Array.isArray(conversation.messages) ? conversation.messages : [];
      let seq = 0;
      for (const message of conversation.messages) {
        seq += 1;
        if (!Number.isFinite(Number(message.seq)) || Number(message.seq) <= 0) message.seq = seq;
        seq = Math.max(seq, Number(message.seq));
      }
      conversation.seq = seq;
    }
  },
  saving: Promise.resolve(),
  save() {
    const snapshot = JSON.stringify({ conversations: this.conversations, media: this.media });
    this.saving = this.saving
      .then(() => writeFile(join(config.dataDir, 'db.json'), snapshot, 'utf8'))
      .catch((error) => console.error('[chat] 保存失败', error));
    return this.saving;
  },
};
await db.load();

// ---------------------------------------------------------------- 工具

const json = (res, status, body) => {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  });
  res.end(payload);
};

const fail = (res, status, message) => json(res, status, { ok: false, error: message });

/** 读 JSON 请求体，带大小上限。base64 会把体积放大 4/3，上限要算进去。 */
async function readJson(
  req,
  limit = Math.ceil((config.maxUploadBytes * 4) / 3) + 1024 * 1024,
) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new Error('请求体太大');
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new Error('请求体不是合法 JSON');
  }
}

function authorized(req, url) {
  const header = req.headers.authorization ?? '';
  const bearer = header.startsWith('Bearer ') ? header.slice(7) : '';
  const provided = bearer || url.searchParams.get('t') || '';
  return provided === config.token;
}

/** 附件在给模型看的文本里长什么样。 */
function describeAttachment(attachment) {
  const label =
    attachment.kind === 'image' ? '图片' : attachment.kind === 'voice' ? '语音' : '文件';
  const size = attachment.size >= 1024 * 1024
    ? `${(attachment.size / 1024 / 1024).toFixed(1)} MB`
    : `${Math.max(1, Math.round(attachment.size / 1024))} KB`;
  const extra = attachment.kind === 'voice' && attachment.duration
    ? `，约 ${Math.round(attachment.duration)} 秒`
    : '';
  let text = `（附件：${attachment.name}，${label}，${size}${extra}）`;
  // 借鉴 dsh-qq-link：把本机路径一起给模型，它想细看可以用自己的文件工具打开。
  if (attachment.diskPath) text += `\n本机路径：${attachment.diskPath}`;
  if (attachment.textPreview) {
    text += `\n${attachment.name} 的内容：\n\`\`\`\n${attachment.textPreview}\n\`\`\``;
  }
  return text;
}

/**
 * 借鉴 dsh-qq-link：语音条交给一条外部命令转写（例如 SenseVoice）。
 * 命令里用 {file} 占位，stdout 就是文字。
 */
async function transcribeVoice(file) {
  if (!config.asrCommand) return '';
  let command = config.asrCommand.replaceAll('{file}', `"${file}"`);
  // 进程的 PATH 里通常没有 node，用当前这个解释器的绝对路径。
  command = command.replace(/^node\b/, `"${process.execPath}"`);
  try {
    const { stdout } = await execAsync(command, {
      timeout: 120_000,
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024,
    });
    return String(stdout ?? '').trim().slice(0, 2000);
  } catch (error) {
    console.warn('[chat] 语音转写失败', error?.message ?? error);
    return '';
  }
}
/** 一条消息投影成给模型的一段文本。 */
function messageToText(message) {
  const parts = [];
  if (message.text) parts.push(message.text);
  for (const attachment of message.attachments ?? []) parts.push(describeAttachment(attachment));
  return parts.join('\n');
}

const URL_PATTERN = /https?:\/\/[^\s<>"'）)】」]+/gi;

/** 从一段文字里挑出网址（最多两个，够用就行）。 */
function extractUrls(text) {
  const found = String(text ?? '').match(URL_PATTERN) ?? [];
  return [...new Set(found)].slice(0, 2);
}

/** 把 HTML 压成能读的纯文本：去掉脚本样式，留标题和正文。 */
function htmlToText(html) {
  const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.trim() ?? '';
  const body = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, ' ')
    .trim();
  return { title, body };
}

/**
 * 真去读用户发来的链接：抓一次、压成文本、截断。
 * 只做 http(s)，8 秒超时，最多 512KB，失败就跳过，不影响正常聊天。
 */
async function readLinks(text) {
  const urls = extractUrls(text);
  if (urls.length === 0) return '';
  const notes = [];
  for (const url of urls) {
    try {
      const response = await fetch(url, {
        headers: { accept: 'text/html,text/plain;q=0.9,*/*;q=0.5', 'user-agent': 'dsh-chat/0.1' },
        redirect: 'follow',
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) {
        notes.push(`（链接 ${url} 打不开：HTTP ${response.status}）`);
        continue;
      }
      const type = response.headers.get('content-type') ?? '';
      const raw = (await response.text()).slice(0, 512 * 1024);
      const { title, body } = type.includes('text/plain')
        ? { title: '', body: raw.replace(/\s+/g, ' ').trim() }
        : htmlToText(raw);
      const excerpt = body.slice(0, 3000);
      notes.push(
        `【用户发来的链接】${url}\n标题：${title || '（无）'}\n正文摘录：\n${excerpt}${body.length > excerpt.length ? '\n…（以下省略）' : ''}`,
      );
    } catch (error) {
      notes.push(`（链接 ${url} 读取失败：${error?.message ?? error}）`);
    }
  }
  return notes.join('\n\n');
}

/** 星伴那套：让模型自己把回复拆成几条气泡。 */
const BUBBLE_RULE = {
  role: 'system',
  content:
    '把回复拆成 1 到 3 条短消息，像在聊天软件里连发几条那样，每条一到两句话。只输出 JSON，格式 {"bubbles":["第一条","第二条"]}，不要输出任何别的文字，也不要用 Markdown。',
};

/** 从模型的输出里取出气泡；解析不了就整段当成一条。 */
function parseBubbles(text) {
  const trimmed = String(text ?? '').trim();
  const jsonText = trimmed
    .replace(/^```(?:json)?/i, '')
    .replace(/```$/, '')
    .trim();
  try {
    const parsed = JSON.parse(jsonText);
    const list = Array.isArray(parsed?.bubbles) ? parsed.bubbles : null;
    if (list) {
      const cleaned = list.map((item) => String(item ?? '').trim()).filter(Boolean);
      if (cleaned.length > 0) return cleaned.slice(0, 4);
    }
  } catch {
    /* 不是 JSON 就按整段处理 */
  }
  return [trimmed];
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
/** 每个会话一条 DSH 会话：把会话 id 塞进 model 字段，桥认 agent:<键>。 */
function modelForConversation(conversation) {
  return config.sessionPerConversation ? `agent:${conversation.id}` : config.model;
}
/** 调上游（OpenAI 兼容）拿一段回复。 */
async function askUpstream(messages, model, signal) {
  let response;
  try {
    response = await fetch(`${config.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(config.apiKey ? { authorization: `Bearer ${config.apiKey}` } : {}),
      },
      body: JSON.stringify({ model: model ?? config.model, messages }),
      signal: signal ?? AbortSignal.timeout(config.upstreamTimeoutMs),
    });
  } catch (error) {
    throw new Error(`连不上回复服务（${config.baseUrl}）：${error?.message ?? error}`);
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    if (response.status === 401) throw new Error('回复服务拒绝了令牌（401），检查 config.json 的 apiKey。');
    throw new Error(`回复服务返回 ${response.status}：${detail.slice(0, 300)}`);
  }
  const data = await response.json().catch(() => null);
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== 'string' || !content.trim()) throw new Error('回复服务没有返回文字');
  return content.trim();
}

// ---------------------------------------------------------------- 路由

/** /api/conversations/:id/... 解析出会话和剩余路径。 */
function conversationOf(pathname) {
  const match = pathname.match(/^\/api\/conversations\/([^/]+)(?:\/(.*))?$/);
  if (!match) return null;
  const conversation = db.conversations.find((item) => item.id === match[1]);
  return { conversation, rest: match[2] ?? '' };
}

/** 删掉这个对话在 DSH 那边对应的会话（桥上的 /v1/sessions/delete）。 */
async function deleteBridgeSession(conversationId) {
  if (!config.sessionPerConversation) return;
  const base = config.baseUrl.replace(/\/v1\/?$/, '');
  try {
    const response = await fetch(`${base}/v1/sessions/delete`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(config.apiKey ? { authorization: `Bearer ${config.apiKey}` } : {}),
      },
      body: JSON.stringify({ key: `agent:${conversationId}` }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) {
      console.warn('[chat] 删除 DSH 会话返回', response.status);
    }
  } catch (error) {
    console.warn('[chat] 删除 DSH 会话失败', error?.message ?? error);
  }
}
const summarize = (conversation) => ({
  id: conversation.id,
  title: conversation.title,
  updatedAt: conversation.updatedAt,
  count: conversation.messages.length,
  lastSeq: Number(conversation.seq) || 0,
  lastRole: conversation.messages.length ? conversation.messages.at(-1).role : '',
  preview: conversation.messages.length
    ? messageToText(conversation.messages.at(-1)).slice(0, 60)
    : '新对话',
});

/**
 * 给会话追加一条消息，自动分配单调递增的 seq。
 * seq 是「增量拉取 + 断线重连」的游标，客户端只记 lastSeq 就够了。
 */
function appendMessage(conversation, message) {
  let maxSeq = Number(conversation.seq) || 0;
  for (const item of conversation.messages) maxSeq = Math.max(maxSeq, Number(item.seq) || 0);
  const stored = { ...message, seq: maxSeq + 1 };
  conversation.messages.push(stored);
  conversation.seq = stored.seq;
  conversation.updatedAt = stored.at;
  return stored;
}

/** 这条用户消息之后、下一条用户消息之前的 assistant 消息（重发时回放用）。 */
function repliesAfter(conversation, seq) {
  const replies = [];
  for (const message of conversation.messages) {
    if ((Number(message.seq) || 0) <= seq) continue;
    if (message.role === 'user') break;
    if (message.role === 'assistant') replies.push(message);
  }
  return replies;
}

/** 正在生成的用户消息 id：同一 clientMessageId 重复重发时不再触发第二次模型调用。 */
const inFlight = new Set();

/** 跑一轮：拿历史 → 调上游 → 拆气泡 → 落库 → 广播。 */
async function runTurn(conversation, userMessage) {
  const history = conversation.messages
    .filter((message) => (Number(message.seq) || 0) <= (Number(userMessage.seq) || 0))
    .slice(-config.historyLimit)
    .map((message) => ({ role: message.role, content: messageToText(message) }))
    .filter((message) => message.content);
  const requestMessages = [{ role: 'system', content: config.systemPrompt }, ...history];

  // 用户发的链接，服务端先去读回来，再一起交给模型。
  const linkNotes = config.fetchLinks ? await readLinks(userMessage.text) : '';
  if (linkNotes && requestMessages.length > 1) {
    const last = requestMessages[requestMessages.length - 1];
    last.content = `${last.content}\n\n${linkNotes}`;
  }

  const requestForBubbles = config.bubbles ? [...requestMessages, BUBBLE_RULE] : requestMessages;
  const replyText = await askUpstream(requestForBubbles, modelForConversation(conversation));
  const bubbles = config.bubbles ? parseBubbles(replyText) : [replyText];

  const replies = [];
  for (let index = 0; index < bubbles.length; index += 1) {
    // 气泡之间停一下，读起来像对方在一条条打字。
    if (index > 0) await sleep(500 + Math.random() * 900);
    const message = appendMessage(conversation, {
      id: randomUUID().replace(/-/g, '').slice(0, 16),
      role: 'assistant',
      text: bubbles[index],
      attachments: [],
      at: new Date().toISOString(),
    });
    await db.save();
    broadcast({ type: 'message', conversationId: conversation.id, message });
    replies.push(message);
  }
  userMessage.replied = true;
  await db.save();
  return replies;
}

/** 在线的事件订阅者（SSE）。DSH 主动推的消息也走这里。 */
const sseClients = new Set();

function broadcast(event) {
  const payload = `data: ${JSON.stringify(event)}\n\n`;
  for (const client of sseClients) {
    try {
      client.write(payload);
    } catch {
      sseClients.delete(client);
    }
  }
}

async function handleApi(req, res, url) {
  const path = url.pathname;

  // 实时事件流：新消息、DSH 主动推送都从这里下发，替代轮询。
  if (req.method === 'GET' && path === '/api/events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
    });
    res.write('retry: 3000\n\n');
    sseClients.add(res);
    const ping = setInterval(() => {
      try {
        res.write(': ping\n\n');
      } catch {
        /* 断开时 close 会清理 */
      }
    }, 25_000);
    req.on('close', () => {
      clearInterval(ping);
      sseClients.delete(res);
    });
    return;
  }

  // 让 DSH 主动开口：外部（agent、cron、脚本）往会话里塞一条 assistant 消息。
  if (req.method === 'POST' && path === '/api/push') {
    const body = await readJson(req);
    const text = String(body.text ?? '').trim();
    if (!text) return fail(res, 400, '空消息');
    const conversation = body.conversationId
      ? db.conversations.find((item) => item.id === body.conversationId)
      : [...db.conversations].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))[0];
    if (!conversation) return fail(res, 404, '没有可用的会话，先在聊天端发一句');
    const message = appendMessage(conversation, {
      id: randomUUID().replace(/-/g, '').slice(0, 16),
      role: 'assistant',
      text,
      attachments: [],
      at: new Date().toISOString(),
    });
    await db.save();
    broadcast({ type: 'message', conversationId: conversation.id, message });
    return json(res, 200, { ok: true, conversationId: conversation.id, message });
  }

  // 网页端的「设置」：只改聊天侧这几项，改完立即生效并写回 config.json。
  if (path === '/api/settings') {
    if (req.method === 'GET') {
      return json(res, 200, {
        ok: true,
        settings: {
          systemPrompt: config.systemPrompt,
          fetchLinks: config.fetchLinks,
          bubbles: config.bubbles,
          maxUploadBytes: config.maxUploadBytes,
          historyLimit: config.historyLimit,
        },
      });
    }
    if (req.method === 'POST') {
      const body = await readJson(req, 64 * 1024);
      let saved = {};
      try {
        saved = JSON.parse(await readFile(join(HERE, 'config.json'), 'utf8'));
      } catch {
        /* 没有就新建 */
      }
      if (typeof body.systemPrompt === 'string' && body.systemPrompt.trim()) {
        config.systemPrompt = body.systemPrompt.trim().slice(0, 8000);
        saved.systemPrompt = config.systemPrompt;
      }
      if (typeof body.fetchLinks === 'boolean') {
        config.fetchLinks = body.fetchLinks;
        saved.fetchLinks = config.fetchLinks;
      }
      if (typeof body.bubbles === 'boolean') {
        config.bubbles = body.bubbles;
        saved.bubbles = config.bubbles;
      }
      const mb = Number(body.maxUploadMb);
      if (Number.isFinite(mb) && mb >= 1 && mb <= 512) {
        config.maxUploadBytes = Math.round(mb * 1024 * 1024);
        saved.maxUploadBytes = config.maxUploadBytes;
      }
      await writeFile(join(HERE, 'config.json'), JSON.stringify(saved, null, 2), 'utf8');
      return json(res, 200, { ok: true });
    }
    return fail(res, 405, '不支持的方法');
  }

  if (req.method === 'POST' && path === '/api/upload') {
    const body = await readJson(req);
    const name = String(body.name ?? 'file').slice(0, 120);
    const mime = String(body.mime ?? 'application/octet-stream');
    const data = String(body.data ?? '');
    if (!data) return fail(res, 400, '没有文件内容');
    const buffer = Buffer.from(data, 'base64');
    if (buffer.length > config.maxUploadBytes) return fail(res, 413, '文件太大');
    const id = randomUUID().replace(/-/g, '').slice(0, 16);
    const ext = extname(name) || '.bin';
    const diskPath = join(MEDIA_DIR, id + ext);
    await writeFile(diskPath, buffer);
    const kind = body.kind === 'voice' ? 'voice' : mime.startsWith('image/') ? 'image' : 'file';
    let textPreview = body.textPreview ? String(body.textPreview).slice(0, 4000) : '';
    if (kind === 'voice' && !textPreview) {
      const transcript = await transcribeVoice(diskPath);
      if (transcript) textPreview = transcript;
    }
    const attachment = {
      id,
      kind,
      name,
      mime,
      size: buffer.length,
      duration: Number(body.duration) || 0,
      diskPath,
      url: `/media/${id}${ext}?t=${config.token}`,
      ...(textPreview ? { textPreview } : {}),
    };
    db.media[id] = { ...attachment, storedAt: new Date().toISOString() };
    await db.save();
    return json(res, 200, { ok: true, attachment });
  }

  if (path === '/api/conversations') {
    if (req.method === 'DELETE') {
      const ids = db.conversations.map((item) => item.id);
      for (const id of ids) await deleteBridgeSession(id);
      db.conversations = [];
      await db.save();
      return json(res, 200, { ok: true });
    }
    if (req.method === 'GET') {
      const list = [...db.conversations].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
      return json(res, 200, { ok: true, conversations: list.map(summarize) });
    }
    if (req.method === 'POST') {
      const now = new Date().toISOString();
      const conversation = {
        id: randomUUID().replace(/-/g, '').slice(0, 16),
        title: '新对话',
        createdAt: now,
        updatedAt: now,
        messages: [],
      };
      db.conversations.unshift(conversation);
      await db.save();
      return json(res, 200, { ok: true, conversation });
    }
    return fail(res, 405, '不支持的方法');
  }

  const found = conversationOf(path);
  if (!found) return fail(res, 404, '没有这个接口');
  if (!found.conversation) return fail(res, 404, '会话不存在');
  const conversation = found.conversation;

  if (req.method === 'GET' && found.rest === '') {
    const since = Math.max(0, Number(url.searchParams.get('since') ?? 0) || 0);
    if (since > 0) {
      const messages = conversation.messages.filter((message) => (Number(message.seq) || 0) > since);
      return json(res, 200, { ok: true, conversation: summarize(conversation), messages });
    }
    return json(res, 200, { ok: true, conversation });
  }

  // 增量拉取：断线重连只补缺的那几条，不再整段重拉。
  if (req.method === 'GET' && found.rest === 'messages') {
    const since = Math.max(0, Number(url.searchParams.get('since') ?? 0) || 0);
    const limit = Math.min(200, Math.max(1, Number(url.searchParams.get('limit') ?? 100) || 100));
    const after = conversation.messages.filter((message) => (Number(message.seq) || 0) > since);
    const slice = after.slice(0, limit);
    return json(res, 200, {
      ok: true,
      messages: slice,
      lastSeq: slice.length ? Number(slice[slice.length - 1].seq) : since,
      hasMore: after.length > slice.length,
      conversation: summarize(conversation),
    });
  }

  if (req.method === 'DELETE' && found.rest === '') {
    await deleteBridgeSession(conversation.id);
    db.conversations = db.conversations.filter((item) => item.id !== conversation.id);
    await db.save();
    return json(res, 200, { ok: true });
  }
  if (req.method === 'POST' && found.rest === 'messages') {
    const body = await readJson(req);
    const text = String(body.text ?? '').trim();
    const attachments = Array.isArray(body.attachments)
      ? body.attachments
          .map((item) => db.media[item?.id])
          .filter(Boolean)
      : [];
    const clientMessageId = String(body.clientMessageId ?? '').trim().slice(0, 80) || null;

    // 幂等：断线重发时同一个 clientMessageId 只入库一次。
    if (clientMessageId) {
      const existing = conversation.messages.find(
        (message) => message.role === 'user' && message.clientMessageId === clientMessageId,
      );
      if (existing) {
        const ack = { clientMessageId, seq: existing.seq, id: existing.id };
        if (existing.replied) {
          const replies = repliesAfter(conversation, existing.seq);
          return json(res, 200, {
            ok: true,
            duplicate: true,
            ack,
            user: existing,
            reply: replies[0],
            replies,
            conversation: summarize(conversation),
          });
        }
        if (inFlight.has(existing.id)) {
          // 上一轮还在生成：让客户端等 SSE，不要重复调模型。
          return json(res, 202, {
            ok: true,
            pending: true,
            ack,
            user: existing,
            conversation: summarize(conversation),
          });
        }
        // 上次生成失败了：复用这条用户消息，重新跑一轮。
        inFlight.add(existing.id);
        try {
          const replies = await runTurn(conversation, existing);
          return json(res, 200, {
            ok: true,
            retried: true,
            ack,
            user: existing,
            reply: replies[0],
            replies,
            conversation: summarize(conversation),
          });
        } catch (error) {
          return json(res, 502, {
            ok: false,
            error: String(error?.message ?? error),
            ack,
            user: existing,
            conversation: summarize(conversation),
          });
        } finally {
          inFlight.delete(existing.id);
        }
      }
    }

    if (!text && attachments.length === 0) return fail(res, 400, '空消息');

    const userMessage = appendMessage(conversation, {
      id: randomUUID().replace(/-/g, '').slice(0, 16),
      role: 'user',
      text,
      attachments,
      at: new Date().toISOString(),
      ...(clientMessageId ? { clientMessageId } : {}),
    });
    if (conversation.title === '新对话') {
      conversation.title = (text || attachments[0]?.name || '新对话').slice(0, 24);
    }
    await db.save();
    // 先广播用户消息：多端能立刻看到「已发出」，不用等模型回完。
    broadcast({ type: 'message', conversationId: conversation.id, message: userMessage });

    const ack = { clientMessageId, seq: userMessage.seq, id: userMessage.id };
    inFlight.add(userMessage.id);
    try {
      const replies = await runTurn(conversation, userMessage);
      return json(res, 200, {
        ok: true,
        ack,
        user: userMessage,
        reply: replies[0],
        replies,
        conversation: summarize(conversation),
      });
    } catch (error) {
      return json(res, 502, {
        ok: false,
        error: String(error?.message ?? error),
        ack,
        user: userMessage,
        conversation: summarize(conversation),
      });
    } finally {
      inFlight.delete(userMessage.id);
    }
  }
  return fail(res, 404, '没有这个接口');
}

async function serveStatic(req, res, url) {
  const path = url.pathname === '/' ? '/index.html' : url.pathname;
  const file = join(PUBLIC_DIR, path.replace(/^\/+/, '').replace(/\.\./g, ''));
  try {
    const body = await readFile(file);
    res.writeHead(200, {
      'content-type': MIME[extname(file)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    });
    res.end(body);
  } catch {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('404');
  }
}

async function serveMedia(req, res, url) {
  const match = url.pathname.match(/^\/media\/([^/]+)$/);
  if (!match) return fail(res, 404, '没有这个文件');
  const name = match[1];
  const id = name.split('.')[0];
  const record = db.media[id];
  if (!record) return fail(res, 404, '文件不存在');
  try {
    const body = await readFile(join(MEDIA_DIR, name));
    res.writeHead(200, {
      'content-type': record.mime ?? 'application/octet-stream',
      'content-length': body.length,
      'content-disposition': `inline; filename*=UTF-8''${encodeURIComponent(record.name)}`,
    });
    res.end(body);
  } catch {
    fail(res, 404, '文件已丢失');
  }
}

const server = createServer(async (req, res) => {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-headers', 'authorization, content-type');
  res.setHeader('access-control-allow-methods', 'GET, POST, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  const url = new URL(req.url ?? '/', 'http://127.0.0.1');
  try {
    if (url.pathname === '/healthz') {
      return json(res, 200, {
        ok: true,
        // 协议版本：客户端可以用它判断服务端支不支持 seq / clientMessageId。
        protocol: 1,
        capabilities: ['seq', 'ack', 'since', 'clientMessageId'],
        maxUploadBytes: config.maxUploadBytes,
        upstream: config.baseUrl,
        model: config.model,
        sessionPerConversation: Boolean(config.sessionPerConversation),
        fetchLinks: Boolean(config.fetchLinks),
      });
    }
    if (url.pathname.startsWith('/media/')) {
      if (!authorized(req, url)) return fail(res, 401, '需要令牌');
      return await serveMedia(req, res, url);
    }
    if (url.pathname.startsWith('/api/')) {
      if (!authorized(req, url)) return fail(res, 401, '令牌不对');
      return await handleApi(req, res, url);
    }
    return await serveStatic(req, res, url);
  } catch (error) {
    console.error('[chat]', error);
    fail(res, 500, String(error?.message ?? error));
  }
});

server.requestTimeout = 0;
server.listen(config.port, config.host, () => {
  console.log(`[chat] http://${config.host}:${config.port}  上游 ${config.baseUrl}  模型 ${config.model}`);
  console.log(`[chat] 令牌：${config.token}`);
});
