import { createServer } from 'node:http';
import { BridgeError, describeError } from './bridge.js';

const MAX_BODY_BYTES = 4 * 1024 * 1024;

/** 常数时间比较，别用 === 比令牌。 */
function sameSecret(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index += 1) diff |= left[index] ^ right[index];
  return diff === 0;
}

function send(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

function openAIError(res, status, message, type = 'invalid_request_error') {
  send(res, status, { error: { message, type, code: null } });
}

/** @returns {Promise<any>} */
async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new BridgeError('请求体太大', 413);
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new BridgeError('请求体不是合法 JSON', 400);
  }
}

/**
 * 星伴只认 OpenAI 的 `/chat/completions`，所以这里把最小可用的那部分实现出来：
 * 认证、`/v1/models`、非流式与流式两种回复。
 *
 * @param {{ bridge: import('./bridge.js').StarlitBridge, config: any, logger: any }} options
 */
export function createBridgeServer({ bridge, config, logger }) {
  const started = Math.floor(Date.now() / 1000);

  const server = createServer(async (req, res) => {
    // 星伴是 WebView 里发请求，跨源预检必须有回应。
    res.setHeader('access-control-allow-origin', '*');
    res.setHeader('access-control-allow-headers', 'authorization, content-type, x-api-key');
    res.setHeader('access-control-allow-methods', 'GET, POST, OPTIONS');
    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const path = url.pathname.replace(/\/+$/, '');

    if (path === '/healthz' || path === '/health') {
      send(res, 200, {
        ok: true,
        sessionId: config.mode === 'agent' ? bridge.sessionId : null,
        model: bridge.model(),
        mode: config.mode,
        sessionKey: config.sessionKey ?? 'auto',
        sessions: Object.fromEntries(bridge.sessionIds ?? []),
        persona: config.persona,
        tools: config.tools,
      });
      return;
    }

    // 令牌：星伴把它放在 api_key 里，于是走 Authorization: Bearer。
    if (config.token) {
      const header = req.headers.authorization ?? '';
      const bearer = header.startsWith('Bearer ') ? header.slice(7) : '';
      const apiKey = req.headers['x-api-key'];
      const provided = bearer || (typeof apiKey === 'string' ? apiKey : '');
      if (!provided || !sameSecret(provided, config.token)) {
        openAIError(res, 401, '访问令牌不对：把这里配置的 token 填进星伴的 api_key。', 'authentication_error');
        return;
      }
    }

    if (req.method === 'GET' && path === '/debug/http' && config.debug) {
      send(res, 200, { records: bridge.httpLog ?? [] });
      return;
    }
    if (req.method === 'POST' && path === '/debug/agent' && config.debug) {
      try {
        const body = await readJson(req);
        const result = await bridge.probeAgent({ cwd: body.cwd, text: body.text });
        send(res, 200, { ok: true, ...result });
      } catch (error) {
        send(res, 500, { ok: false, message: error?.message, code: error?.code, cause: describeError(error, true) });
      }
      return;
    }
    if (req.method === 'POST' && path === '/debug/llm' && config.debug) {
      try {
        const echo = await bridge.probeLlm('ping');
        send(res, 200, { ok: true, text: echo });
      } catch (error) {
        send(res, 500, {
          ok: false,
          message: error?.message,
          code: error?.code,
          cause: describeError(error, true),
        });
      }
      return;
    }
    if (req.method === 'POST' && path === '/v1/sessions/delete') {
      let body;
      try {
        body = await readJson(req);
      } catch (error) {
        openAIError(res, error.status ?? 400, error.message);
        return;
      }
      const rawKey = typeof body?.key === 'string' ? body.key : '';
      // 客户端可能带 agent: 前缀，桥内部的键是去掉前缀的那个。
      const key = rawKey.startsWith('agent:') ? rawKey.slice(6) : rawKey;
      if (!key) {
        openAIError(res, 400, '需要 key');
        return;
      }
      try {
        const result = await bridge.removeSession(key);
        send(res, 200, { ok: true, ...result });
      } catch (error) {
        logger?.warn?.(`删除会话失败：${error?.message ?? error}`);
        openAIError(res, 500, String(error?.message ?? error), 'dsh_error');
      }
      return;
    }
    if (req.method === 'GET' && (path === '/v1/models' || path === '/models')) {      const selection = bridge.model();
      send(res, 200, {
        object: 'list',
        data: [
          {
            id: selection.model ?? 'dsh',
            object: 'model',
            created: started,
            owned_by: 'dsh',
          },
        ],
      });
      return;
    }

    if (req.method === 'POST' && (path === '/v1/chat/completions' || path === '/chat/completions')) {
      let body;
      try {
        body = await readJson(req);
      } catch (error) {
        openAIError(res, error.status ?? 400, error.message);
        return;
      }
      if (!Array.isArray(body?.messages)) {
        openAIError(res, 400, 'messages 必须是一个数组');
        return;
      }
      try {
        const { text, sessionId } = await bridge.reply({
          messages: body.messages,
          model: typeof body.model === 'string' ? body.model : '',
        });
        const id = `chatcmpl-${Date.now().toString(36)}`;
        const model = typeof body.model === 'string' && body.model ? body.model : 'dsh';
        logger?.info?.(`星伴 → 会话 ${sessionId}：${text.length} 字`);
        if (body.stream === true) {
          res.writeHead(200, {
            'content-type': 'text/event-stream; charset=utf-8',
            'cache-control': 'no-cache',
            connection: 'keep-alive',
          });
          const chunk = (delta, finish) =>
            `data: ${JSON.stringify({
              id,
              object: 'chat.completion.chunk',
              created: started,
              model,
              choices: [{ index: 0, delta, finish_reason: finish }],
            })}\n\n`;
          res.write(chunk({ role: 'assistant', content: text }, null));
          res.write(chunk({}, 'stop'));
          res.write('data: [DONE]\n\n');
          res.end();
          return;
        }
        send(res, 200, {
          id,
          object: 'chat.completion',
          created: started,
          model,
          choices: [
            {
              index: 0,
              message: { role: 'assistant', content: text },
              finish_reason: 'stop',
            },
          ],
          usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
        });
      } catch (error) {
        const status = error instanceof BridgeError ? error.status : 502;
        logger?.warn?.(`星伴请求失败：${error?.message ?? error}`);
        openAIError(res, status, String(error?.message ?? error), 'dsh_error');
      }
      return;
    }

    openAIError(res, 404, `没有这个接口：${req.method} ${url.pathname}`);
  });

  server.requestTimeout = 0;
  server.headersTimeout = 0;
  return server;
}
