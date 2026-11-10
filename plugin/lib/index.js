import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { StarlitBridge } from './bridge/bridge.js';
import { createBridgeServer } from './bridge/server.js';

/** Cordis 插件名。 */
export const name = 'chat';

/** 二合一：聊天服务自己跑 DSH 会话，所以要模型和会话注册表。 */
export const inject = ['llm', 'agents'];

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const SERVER = join(ROOT, 'server.mjs');
const HOST = join(ROOT, 'relay', 'host.mjs');

/**
 * dsh-chat：聊天 App 的后端（网页端 + HTTP API），自带「跑 DSH 会话」的桥。
 *
 * - 不填 `baseUrl`：插件内部起一座桥（只监听本机回环），把对话交给
 *   指定的 DSH 会话跑，不需要再装 `dsh-plugin-starlit-bridge`；
 * - 填了 `baseUrl`：照旧转发给任意 OpenAI 兼容后端（保留旧用法）。
 *
 * `sessionKey: fixed` + `sessionId` 可以让所有聊天都写进同一条已有会话，
 * 而不是每开一个对话就新建一条。
 *
 * @param {any} ctx
 * @param {any} config
 */
export async function apply(ctx, config = {}) {
  const logger = ctx.logger?.('chat');
  const host = String(config?.host ?? '0.0.0.0');
  const port = Number(config?.port ?? 8792);
  const token = String(config?.token ?? '');
  const relayUrl = String(config?.relayUrl ?? '').trim();
  const relayRoom = String(config?.relayRoom ?? '').trim();
  const relayKey = String(config?.relayKey ?? '').trim();

  let baseUrl = String(config?.baseUrl ?? '').trim();
  let apiKey = String(config?.apiKey ?? '');
  let bridge = null;
  let bridgeServer = null;

  // 没配上游地址 = 用插件自带的桥，直接跑这条 DSH 里的会话。
  if (!baseUrl) {
    const bridgeHost = String(config?.bridgeHost ?? '127.0.0.1');
    const bridgePort = Number(config?.bridgePort ?? 8790);
    const bridgeToken = String(config?.bridgeToken ?? token);
    const bridgeConfig = {
      host: bridgeHost,
      port: bridgePort,
      token: bridgeToken,
      mode: config?.mode === 'agent' ? 'agent' : 'chat',
      // 默认 fixed：所有聊天共用一条会话，而不是每个对话新建一条。
      sessionKey: ['auto', 'model', 'fixed'].includes(config?.sessionKey) ? config.sessionKey : 'fixed',
      sessionId: String(config?.sessionId ?? '').trim(),
      persona: config?.persona === 'dsh' ? 'dsh' : 'starlit',
      tools: config?.tools === true,
      timeoutMs: Number(config?.timeoutMs ?? 120_000),
      provider: String(config?.provider ?? ''),
      model: String(config?.model ?? ''),
      cwd: String(config?.cwd ?? process.cwd()),
      stateFile: join(ROOT, 'data', 'bridge-sessions.json'),
      debug: false,
      captureHttp: false,
    };
    bridge = new StarlitBridge({ ctx, config: bridgeConfig, logger });
    await bridge.start();
    bridgeServer = createBridgeServer({ bridge, config: bridgeConfig, logger });
    await new Promise((resolve, reject) => {
      const onError = (error) => reject(new Error(`内置桥监听 ${bridgeHost}:${bridgePort} 失败：${error.message}`));
      bridgeServer.once('error', onError);
      bridgeServer.listen(bridgePort, bridgeHost, () => {
        bridgeServer.off('error', onError);
        resolve();
      });
    });
    baseUrl = `http://127.0.0.1:${bridgePort}/v1`;
    apiKey = bridgeToken;
    logger?.info?.(`内置桥已启动：${baseUrl}（会话 ${bridge.sessionId ?? '(新建)'}，mode=${bridgeConfig.mode}）`);
  }

  const chat = spawn(process.execPath, [SERVER], {
    cwd: ROOT,
    env: {
      ...process.env,
      CHAT_HOST: host,
      CHAT_PORT: String(port),
      CHAT_TOKEN: token,
      CHAT_BASE_URL: baseUrl,
      CHAT_API_KEY: apiKey,
      CHAT_DATA_DIR: join(ROOT, 'data'),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });

  chat.stdout?.on('data', (chunk) => logger?.info?.(String(chunk).trim()));
  chat.stderr?.on('data', (chunk) => logger?.warn?.(String(chunk).trim()));
  chat.on('exit', (code) => logger?.warn?.(`聊天服务退出（code=${code}）`));
  logger?.info?.(`聊天服务已启动：http://${host}:${port}（上游 ${baseUrl}）`);

  /** @type {import('node:child_process').ChildProcess | null} */
  let relayHost = null;
  if (relayUrl && relayRoom && relayKey) {
    relayHost = spawn(process.execPath, [HOST], {
      cwd: ROOT,
      env: {
        ...process.env,
        RELAY_URL: relayUrl,
        ROOM: relayRoom,
        KEY: relayKey,
        CHAT_TARGET: `http://127.0.0.1:${port}`,
        CHAT_TOKEN: token,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    relayHost.stdout?.on('data', (chunk) => logger?.info?.(`[relay] ${String(chunk).trim()}`));
    relayHost.stderr?.on('data', (chunk) => logger?.warn?.(`[relay] ${String(chunk).trim()}`));
    relayHost.on('exit', (code) => logger?.warn?.(`中转适配器退出（code=${code}）`));
    logger?.info?.(`已连中转：${relayUrl}（房间 ${relayRoom}）`);
  }

  ctx.effect(() => () => {
    for (const child of [relayHost, chat]) {
      try {
        child?.kill();
      } catch {
        /* 已经退了 */
      }
    }
    try {
      bridgeServer?.close();
    } catch {
      /* 已经关了 */
    }
    void bridge?.stop();
  });
}
