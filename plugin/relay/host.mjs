/**
 * 主机端适配器：连上中转，把 App 发来的 call 转成对本机聊天服务的 HTTP 请求，
 * 再把本机的实时事件（SSE）推回中转。聊天服务本身一行都不用改。
 *
 * 环境变量：
 *   RELAY_URL   中转地址，如 wss://relay.example/ws
 *   ROOM        房间号（App 配对时用的那个）
 *   KEY         房间密钥
 *   CHAT_TARGET 本机聊天服务，默认 http://127.0.0.1:8792
 *   CHAT_TOKEN  聊天服务的令牌
 */
const relayUrl = process.env.RELAY_URL;
const room = process.env.ROOM;
const key = process.env.KEY;
const target = (process.env.CHAT_TARGET ?? 'http://127.0.0.1:8792').replace(/\/+$/, '');
const chatToken = process.env.CHAT_TOKEN ?? '';

if (!relayUrl || !room || !key) {
  console.error('需要 RELAY_URL / ROOM / KEY');
  process.exit(1);
}

const url = `${relayUrl}?room=${encodeURIComponent(room)}&key=${encodeURIComponent(key)}&role=host`;
let socket = null;
let retry = 1000;

function connect() {
  socket = new WebSocket(url);
  socket.addEventListener('open', () => {
    retry = 1000;
    console.log('[host] 已连上中转');
    subscribe();
  });
  socket.addEventListener('message', (event) => {
    let frame;
    try {
      frame = JSON.parse(String(event.data));
    } catch {
      return;
    }
    if (frame?.type === 'call') handleCall(frame);
  });
  socket.addEventListener('close', () => {
    console.log(`[host] 断开，${retry}ms 后重连`);
    setTimeout(connect, retry);
    retry = Math.min(retry * 2, 15000);
  });
  socket.addEventListener('error', () => {
    /* close 会接着来 */
  });
}

function send(frame) {
  if (socket && socket.readyState === 1) socket.send(JSON.stringify(frame));
}

/** 一次调用 = 对本地聊天服务的一次 HTTP 请求。 */
async function handleCall(frame) {
  const method = String(frame.method ?? 'GET').toUpperCase();
  const path = String(frame.path ?? '/');
  try {
    const response = await fetch(target + path, {
      method,
      headers: {
        ...(frame.body === undefined ? {} : { 'content-type': 'application/json' }),
        ...(chatToken ? { authorization: `Bearer ${chatToken}` } : {}),
      },
      body: frame.body === undefined ? undefined : JSON.stringify(frame.body),
    });
    const text = await response.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
    send({ type: 'result', id: frame.id, status: response.status, body });
  } catch (error) {
    send({ type: 'result', id: frame.id, status: 502, body: { ok: false, error: String(error?.message ?? error) } });
  }
}

/** 本机的实时事件（SSE）原样转成 event 帧推给 App。 */
async function subscribe() {
  try {
    const response = await fetch(`${target}/api/events?t=${encodeURIComponent(chatToken)}`, {
      headers: { accept: 'text/event-stream' },
    });
    if (!response.ok || !response.body) return;
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let index;
      while ((index = buffer.indexOf('\n\n')) >= 0) {
        const chunk = buffer.slice(0, index);
        buffer = buffer.slice(index + 2);
        for (const line of chunk.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          const payload = line.slice(6);
          if (payload.trim() === '') continue;
          try {
            send({ type: 'event', data: JSON.parse(payload) });
          } catch {
            /* 不是 JSON 就跳过 */
          }
        }
      }
    }
  } catch (error) {
    console.warn('[host] 订阅事件失败', error?.message ?? error);
  }
  // 订阅断了就等一会重连
  setTimeout(subscribe, 3000);
}

connect();
