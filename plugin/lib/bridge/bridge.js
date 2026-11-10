import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

/** 桥自己的失败类型：带 HTTP 状态码，服务层直接照抄。 */
export class BridgeError extends Error {
  /**
   * @param {string} message
   * @param {number} [status]
   */
  constructor(message, status = 502) {
    super(message);
    this.name = 'BridgeError';
    this.status = status;
  }
}

/** 从 OpenAI 的 content（字符串或分段数组）里取出纯文本。 */
export function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part === 'string') return part;
      if (!part || typeof part !== 'object') return '';
      if (part.type === 'text' && typeof part.text === 'string') return part.text;
      return '';
    })
    .join('');
}

/** 取 DSH 消息里 assistant 的正文，跳过 reasoning 与工具段。 */
function assistantText(message) {
  if (!message || message.role !== 'assistant' || !Array.isArray(message.content)) return '';
  return message.content
    .filter((part) => part && part.type === 'text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('')
    .trim();
}

const PERSONA_HEAD = [
  '【星伴角色设定】下面这段是聊天软件给你的角色设定与记忆。',
  '在接下来的对话里，用这个角色的身份、口吻和记忆跟对方聊天，不要提到「设定」「提示词」或你自己是 AI。',
  '——设定开始——',
].join('\n');

const PERSONA_TAIL = '——设定结束——';

/**
 * 把错误连同 cause 链一起说清楚：适配器常常只把根因挂在 cause 上。
 * @param {unknown} error
 */
export function describeError(error, deep = false) {
  const parts = [];
  let current = error;
  for (let depth = 0; current && depth < 6; depth += 1) {
    const message = current?.message ?? String(current);
    parts.push(message);
    if (deep && current?.stack) parts.push(String(current.stack).split('\n').slice(0, 5).join(' | '));
    current = current?.cause;
  }
  return parts.join(' ← ');
}

/**
 * 这一轮如果以错误收场，把 DSH 记录的原因捞出来，别只回一句「没有回复」。
 * @param {any} agent
 * @param {number} fromSeq
 * @returns {string | undefined}
 */
function turnFailure(agent, fromSeq) {
  try {
    const session = agent.session;
    const end = Number(session.seq ?? 0);
    for (let seq = end - 1; seq >= fromSeq && seq >= 0; seq -= 1) {
      const event = session.eventAt(seq);
      if (!event) continue;
      if (event.type === 'turn/start') break;
      if (event.type === 'turn/end' && event.data?.reason?.kind === 'error') {
        const failure = event.data.reason.error;
        return `DSH 这一轮失败了：${failure?.message ?? JSON.stringify(failure)}`;
      }
    }
  } catch {
    /* 读不到就退回通用文案 */
  }
  return undefined;
}

/**
 * 把「星伴发来的一次 chat/completions 请求」变成 DSH 里的一轮对话。
 *
 * 一个桥对应一个 DSH 会话：第一次请求时创建，之后 resume。这样星伴只是前端，
 * 真正的对话历史在 DSH 里，连到同一台 DSH 的 dsh-Go 也能看到。
 */
export class StarlitBridge {
  /**
   * @param {{ ctx: any, config: any, logger: any }} options
   */
  constructor({ ctx, config, logger }) {
    this.ctx = ctx;
    this.config = config;
    this.logger = logger;
    /** @type {Map<string, string>} 会话键 → DSH 会话 id（一个键一条会话） */
    this.sessionIds = new Map();
    /** @type {boolean} */
    this.loaded = false;
    /** @type {Map<string, any>} 本插件创建的 agent 句柄 */
    this.handles = new Map();
    this.personaSent = false;
    this.queue = Promise.resolve();
  }

  /** 当前固定的那条会话（给 /healthz 和日志用）。 */
  get sessionId() {
    if (this.config.sessionKey === 'fixed') {
      return this.sessionIds.get('fixed') ?? this.config.sessionId ?? '';
    }
    return this.sessionIds.get('fixed') ?? [...this.sessionIds.values()][0] ?? '';
  }

  /** 首次请求前把状态读进来：会话键 → 会话 id 的映射。 */
  async start() {
    if (this.loaded) return this.sessionIds;
    this.loaded = true;
    try {
      const raw = JSON.parse(await readFile(this.config.stateFile, 'utf8'));
      if (raw?.sessionIds && typeof raw.sessionIds === 'object') {
        for (const [key, value] of Object.entries(raw.sessionIds)) {
          if (typeof value === 'string' && value) this.sessionIds.set(key, value);
        }
      }
      // 兼容旧版本只存一个 sessionId 的状态文件
      if (typeof raw?.sessionId === 'string' && raw.sessionId) {
        if (!this.sessionIds.has('fixed')) this.sessionIds.set('fixed', raw.sessionId);
      }
    } catch {
      /* 第一次启动没有状态文件，正常 */
    }
    if (this.config.sessionId && !this.sessionIds.has('fixed')) {
      this.sessionIds.set('fixed', this.config.sessionId);
    }
    return this.sessionIds;
  }

  /**
   * 一条会话键对应的会话 id；没有就生成一个并记住。
   * @param {string} key
   */
  async sessionIdFor(key) {
    await this.start();
    const existing = this.sessionIds.get(key);
    if (existing) return existing;
    const id = `session-starlit-${randomUUID()}`;
    this.sessionIds.set(key, id);
    await this.persistSessionId();
    this.logger?.info?.(`新会话键 ${key} → ${id}`);
    return id;
  }

  async persistSessionId() {
    try {
      await mkdir(dirname(this.config.stateFile), { recursive: true });
      await writeFile(
        this.config.stateFile,
        JSON.stringify(
          { sessionIds: Object.fromEntries(this.sessionIds), sessionId: this.sessionId },
          null,
          2,
        ),
        'utf8',
      );
    } catch (error) {
      this.logger?.warn?.(`保存会话状态失败：${error?.message ?? error}`);
    }
  }

  /** 用 DSH 的默认模型选择；配置里显式给了就听配置的。 */
  model() {
    const defaults = this.ctx.get?.('agentDefaultModel');
    let selection;
    try {
      selection = defaults?.currentSelection?.();
    } catch {
      selection = undefined;
    }
    return {
      provider: this.config.provider || selection?.provider,
      model: this.config.model || selection?.model,
      ...(selection?.reasoningEffort && !this.config.provider
        ? { reasoningEffort: selection.reasoningEffort }
        : {}),
    };
  }

  /** agent 模式的模型选项：不要继承 256k 输出上限那类激进默认值。 */
  agentOptions() {
    const base = this.model();
    return {
      provider: base.provider,
      model: base.model,
      maxTokens: this.config.agentMaxTokens ?? 32768,
      reasoningEffort: this.config.agentReasoningEffort ?? 'low',
    };
  }
  /** 默认不给工具：这是聊天，不想让一句「帮我看看磁盘」就动起手来。 */
  async setupAgent(agentCtx, agent, tools = this.config.tools) {
    if (tools) {
      // 要工具就得套预设：插件作用域自己只能看到很少几个全局工具，
      // web_fetch / shell / 文件这些是预设挂进来的。
      const presets = this.ctx.get?.('agentPresets');
      if (presets?.mount) {
        try {
          const resolved = await presets.resolve(this.config.agentPreset ?? 'standard');
          await presets.mount(agentCtx, resolved.id);
          this.logger?.info?.(`会话套用预设 ${resolved.id}`);
          return;
        } catch (error) {
          this.logger?.warn?.(`套用预设失败：${error?.message ?? error}`);
        }
      }
      return;
    }
    try {
      const names = [...(agentCtx.tools?.view?.(agent)?.restrictableNames ?? [])];
      if (names.length > 0) agentCtx.tools.restrict({ deny: names });
    } catch (error) {
      this.logger?.warn?.(`限制工具失败，这台会话会带工具：${error?.message ?? error}`);
    }
  }

  /**
   * 这次请求该落到哪条会话。
   * - `fixed`：所有来源共用一条（旧行为）
   * - `model`：按请求里的 model 字段分，星伴能给每个角色配不同 model 时用
   * - `auto`：按星伴发来的角色设定开头做指纹，一个角色一条会话
   * @param {{ messages?: any[], model?: string }} [request]
   * @returns {string}
   */
  sessionKeyFor(request = {}) {
    const mode = this.config.sessionKey ?? 'auto';
    if (mode === 'fixed') return 'fixed';
    if (mode === 'model') {
      const model = String(request.model ?? '').trim();
      return model ? `model:${model.slice(0, 60)}` : 'default';
    }
    const system = (request.messages ?? [])
      .filter((message) => message?.role === 'system')
      .map((message) => textOf(message.content))
      .join('\n')
      .trim();
    if (!system) return 'default';
    const head = system.slice(0, 240).replace(/\s+/g, ' ');
    return `sys-${createHash('sha1').update(head).digest('hex').slice(0, 8)}`;
  }

  /** 找到或建起这条会话键对应的 agent。 */
  async ensureAgent(key = 'fixed', tools = this.config.tools, sectionText = '') {
    const id = await this.sessionIdFor(key);
    const agentOptions = this.agentOptions();
    const setup = async (agentCtx, agent) => {
      // 调用方的「系统提示 / 角色设定」放进会话的系统提示段，
      // 不要拼进用户消息——那会让对话记录里出现一大坨提示词。
      if (sectionText) {
        try {
          agentCtx.systemPrompt?.section({
            name: 'bridge:context',
            order: 900,
            text: sectionText,
            interpolate: false,
          });
        } catch (error) {
          this.logger?.warn?.(`注入提示段失败：${error?.message ?? error}`);
        }
      }
      await this.setupAgent(agentCtx, agent, tools);
    };

    // 插件重载时，上一个 agent 可能还没拆干净；给它一点时间再重试 resume。
    let resumeError;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      const live = this.ctx.agents.get(id);
      if (live) return live;
      try {
        const handle = await this.ctx.agents.resume({
          resumeSessionId: id,
          agentOptions,
          setup,
        });
        this.handles.set(id, handle);
        this.logger?.info?.(`接上已有会话 ${id}`);
        return handle.agent;
      } catch (error) {
        resumeError = error;
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }

    try {
      const handle = await this.ctx.agents.create({
        sessionId: id,
        agentOptions,
        meta: {
          cwd: this.config.cwd,
          ...(tools ? { agentPreset: this.config.agentPreset ?? 'standard' } : {}),
        },
        setup,
      });
      this.handles.set(id, handle);
      this.logger?.info?.(`新建会话 ${id}（${agentOptions.provider}/${agentOptions.model}）`);
      return handle.agent;
    } catch (error) {
      // 旧会话可能已经坏了（早期版本写进去的消息没有 id），换一个新会话继续，
      // 不然这个 id 会一直卡住。
      if (/already exists/i.test(String(error?.message ?? '')) && !this.recovered) {
        this.recovered = true;
        this.sessionIds.set(key, `session-starlit-${randomUUID()}`);
        await this.persistSessionId();
        this.logger?.warn?.(`旧会话不可用，给 ${key} 换了新会话 ${this.sessionIds.get(key)}`);
        return this.ensureAgent(key, tools);
      }
      throw new BridgeError(
        `既接不上已有会话也建不了新的 ${id}：${error?.message ?? error}` +
          (resumeError ? `（resume: ${resumeError?.message ?? resumeError}）` : ''),
        500,
      );
    }
  }

  /**
   * 处理一次请求：默认直接走 DSH 的模型通道（快、无工具副作用、完全保留星伴的角色设定）；
   * agent 模式会真的在 DSH 里开一个会话跑一轮，代价是模型可能自己调工具。
   * @param {{ messages: any[] }} request
   * @returns {Promise<{ text: string, sessionId: string }>}
   */
  reply(request) {
    // 请求自己可以指定走哪条路：model=chat 走模型通道，model=agent:<键> 指定会话键。
    // 用了 agent:<键> 就是明确要一个能干活的会话，工具按打开处理。
    const requested = String(request?.model ?? '');
    const forced = requested === 'chat' ? 'chat' : requested.startsWith('agent:') ? 'agent' : '';
    const mode = forced || this.config.mode;
    if (mode !== 'agent') return this.runChat(request);
    const explicit = requested.startsWith('agent:');
    const key = explicit ? (requested.slice(6) || 'default') : this.sessionKeyFor(request);
    const tools = explicit ? true : this.config.tools;
    const persona = !explicit && this.config.persona === 'starlit';
    const run = this.queue.then(() => this.runTurn({ ...request, key, tools, persona }));
    this.queue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  /**
   * 把星伴的 messages 原样交给 DSH 的模型通道。
   * @param {{ messages: any[] }} request
   */
  async runChat({ messages }) {
    const selection = this.model();
    const system = (messages ?? [])
      .filter((message) => message?.role === 'system')
      .map((message) => textOf(message.content))
      .join('\n\n')
      .trim();
    const turns = (messages ?? [])
      .filter((message) => message?.role === 'user' || message?.role === 'assistant')
      .map((message) => ({ role: message.role, text: textOf(message.content).trim() }))
      .filter((message) => message.text);
    if (!turns.some((message) => message.role === 'user')) {
      throw new BridgeError('请求里没有用户消息', 400);
    }

    // DSH 的模型通道只接受真实落盘的 assistant 消息；这里把历史压成一段
    // 「之前聊过什么」的转写，最后一条用户消息单独发。够用，也不依赖内部类型。
    const last = turns.at(-1);
    const earlier = turns.slice(0, -1);
    const converted = [];
    if (system) converted.push({ role: 'system', content: [{ type: 'text', text: system }] });
    const preamble = earlier.length
      ? '以下是之前的对话（你=助手，我=用户），接着聊：\n' +
        earlier
          .map((turn) => `${turn.role === 'user' ? '我' : '你'}：${turn.text}`)
          .join('\n') +
        '\n\n——以上是之前的对话——\n\n现在我说：'
      : '';
    converted.push({
      role: 'user',
      content: [{ type: 'text', text: preamble + last.text }],
    });
    let answer = '';
    // 模型偶尔会空手而归，重试一次对聊天界面更友好。
    for (let attempt = 0; attempt < 2 && !answer; attempt += 1) {
      const parts = [];
      for await (const chunk of this.ctx.llm.stream({
        provider: selection.provider,
        model: selection.model,
        messages: converted,
      })) {
        if (chunk?.type === 'text-delta') parts.push(chunk.text);
      }
      answer = parts.join('').trim();
    }
    if (!answer) throw new BridgeError('DSH 的模型这次没有返回文字', 502);
    return { text: answer, sessionId: 'chat' };
  }

  /** @param {{ messages: any[] }} request */
  async runTurn({ messages, key = 'fixed', tools = this.config.tools, persona = this.config.persona === 'starlit' }) {
    const system = (messages ?? [])
      .filter((message) => message?.role === 'system')
      .map((message) => textOf(message.content))
      .join('\n\n')
      .trim();
    const history = (messages ?? []).filter(
      (message) => message?.role === 'user' || message?.role === 'assistant',
    );
    let lastUser = '';
    for (let index = history.length - 1; index >= 0; index -= 1) {
      if (history[index].role === 'user') {
        lastUser = textOf(history[index].content).trim();
        break;
      }
    }
    if (!lastUser) throw new BridgeError('请求里没有用户消息', 400);

    const sectionText = system
      ? persona
        ? `${PERSONA_HEAD}\n${system}\n${PERSONA_TAIL}`
        : system
      : '';
    const agent = await this.ensureAgent(key, tools, sectionText);
    const before = agent.session.deriveMessages().length;
    const beforeSeq = Number(agent.session.seq ?? 0);

    // 用户消息就是用户原话，提示词一律走系统提示段。
    const text = lastUser;

    /** @type {unknown} */
    let lastError;
    let offError = () => {};
    try {
      offError = agent.ctx?.on?.('agent/error', (payload) => {
        lastError = payload?.error ?? payload;
      }) ?? (() => {});
    } catch {
      /* 拿不到 agent 作用域就退回会话日志里的错误 */
    }

    agent.followup({
      id: randomUUID(),
      role: 'user',
      content: [{ type: 'text', text }],
      source: { kind: 'user' },
    });

    const timeoutMs = this.config.timeoutMs;
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => {
        try {
          agent.cancel({ kind: 'user' });
        } catch {
          /* agent 可能已经停了 */
        }
        reject(new BridgeError(`DSH 在 ${Math.round(timeoutMs / 1000)} 秒内没有回答`, 504));
      }, timeoutMs);
    });

    try {
      await Promise.race([agent.whenIdle(), timeout]);
    } finally {
      clearTimeout(timer);
      offError?.();
    }

    const produced = agent.session.deriveMessages().slice(before);
    let replyText = '';
    for (let index = produced.length - 1; index >= 0; index -= 1) {
      const candidate = assistantText(produced[index]);
      if (candidate) {
        replyText = candidate;
        break;
      }
    }
    if (!replyText) {
      const notes = [];
      const recorded = turnFailure(agent, beforeSeq);
      if (recorded) notes.push(recorded);
      if (lastError) notes.push(`根因：${describeError(lastError, this.config.debug)}`);
      throw new BridgeError(`DSH 没有回答：${notes.join('；') || '这一轮没有产生文字回复'}`, 502);
    }
    return { text: replyText, sessionId: agent.id };
  }


  /** 直接用插件自己的 ctx.llm 打一次模型，用来把「适配器坏了」和「agent 坏了」分开。 */
  async probeLlm(text = 'ping') {
    const selection = this.model();
    const parts = [];
    for await (const chunk of this.ctx.llm.stream({
      provider: selection.provider,
      model: selection.model,
      messages: [{ role: 'user', content: [{ type: 'text', text }] }],
    })) {
      if (chunk?.type === 'text-delta') parts.push(chunk.text);
    }
    return parts.join('');
  }
  /** 用一个全新的会话跑一轮，用来定位「同样的请求为什么 agent 里失败」。 */
  async probeAgent({ cwd = this.config.cwd, text = 'ping' } = {}) {
    const id = 'session-probe-' + randomUUID();
    const handle = await this.ctx.agents.create({
      sessionId: id,
      agentOptions: this.agentOptions(),
      meta: { cwd },
      setup: (agentCtx, agent) => this.setupAgent(agentCtx, agent),
    });
    try {
      let lastError;
      const off = handle.agent.ctx?.on?.('agent/error', (payload) => { lastError = payload?.error; }) ?? (() => {});
      handle.agent.followup({
        id: randomUUID(),
        role: 'user',
        content: [{ type: 'text', text }],
        source: { kind: 'user' },
      });
      await handle.agent.whenIdle();
      off?.();
      const messages = handle.agent.session.deriveMessages();
      let reply = '';
      for (let index = messages.length - 1; index >= 0; index -= 1) {
        const candidate = assistantText(messages[index]);
        if (candidate) { reply = candidate; break; }
      }
      return { reply, cwd, sessionId: id, error: lastError ? describeError(lastError, true) : undefined };
    } finally {
      await handle.dispose().catch(() => {});
    }
  }
  /**
   * 删掉一条会话：停掉 live agent、删掉磁盘上的会话目录、忘掉键。
   * @param {string} key
   */
  async removeSession(key) {
    const id = this.sessionIds.get(key);
    if (!id) return { removed: false, reason: 'unknown-key' };

    const handle = this.handles.get(id);
    if (handle) {
      try {
        await handle.dispose();
      } catch {
        /* 已经拆掉了 */
      }
      this.handles.delete(id);
    } else {
      try {
        this.ctx.agents.get(id)?.cancel?.({ kind: 'user' });
      } catch {
        /* 没有 live agent 也无所谓 */
      }
    }

    let removedPath = '';
    try {
      const persistence = this.ctx.get?.('sessionPersistence');
      const snapshots = await persistence?.list?.();
      const hit = Array.isArray(snapshots)
        ? snapshots.find((snapshot) => snapshot?.header?.id === id)
        : undefined;
      const path = hit?.location?.path;
      if (path) {
        await rm(dirname(path), { recursive: true, force: true });
        removedPath = dirname(path);
      }
    } catch (error) {
      this.logger?.warn?.(`删除会话文件失败：${error?.message ?? error}`);
    }

    // 同一个会话可能被多个键引用（比如旧版的 fixed），一并清掉。
    for (const [otherKey, otherId] of [...this.sessionIds]) {
      if (otherId === id) this.sessionIds.delete(otherKey);
    }
    await this.persistSessionId();
    this.logger?.info?.(`删除会话 ${key} → ${id}${removedPath ? '（文件已删）' : ''}`);
    return { removed: true, id, path: removedPath };
  }
  /** 插件卸载时把本插件创建的 agent 交还出去（会话本身仍留在 DSH 里）。 */
  async stop() {
    for (const handle of this.handles.values()) {
      try {
        await handle?.dispose?.();
      } catch {
        /* 已经在别的路径上被拆掉了 */
      }
    }
    this.handles.clear();
  }
}
