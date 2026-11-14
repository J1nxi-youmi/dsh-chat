/**
 * 桥的排队行为：按会话各排各的。
 *
 * - 不同会话键同时发，应该并行跑（以前是一条全局链，第二个得等第一个跑完）；
 * - 同一个会话键连发两条，仍然一条一条来，顺序不能乱。
 *
 * 直接跑：node test/session-queue.test.mjs
 */
import assert from 'node:assert/strict';
import { StarlitBridge } from '../lib/bridge/bridge.js';

/** 造一座桥，把真正跑会话的那一步换成可控的假回合。 */
function makeBridge({ delayMs = 60 } = {}) {
  const bridge = new StarlitBridge({
    ctx: {},
    config: { sessionKey: 'auto', mode: 'agent', timeoutMs: 5_000, tools: false, persona: 'dsh' },
    logger: {},
  });
  /** @type {{ key: string, at: number }[]} */
  const started = [];
  /** @type {{ key: string, at: number }[]} */
  const finished = [];
  const active = new Set();
  let peak = 0;
  bridge.runTurn = async ({ key }) => {
    started.push({ key, at: Date.now() });
    active.add(key);
    peak = Math.max(peak, active.size);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    active.delete(key);
    finished.push({ key, at: Date.now() });
    return { text: `done:${key}`, sessionId: key };
  };
  return { bridge, started, finished, get peak() { return peak; } };
}

/** 用 model=agent:<键> 指定落到哪条会话。 */
const ask = (bridge, key) => bridge.reply({ model: `agent:${key}`, messages: [{ role: 'user', content: 'ping' }] });

// 1) 不同会话：并行，互不等待。
{
  const t = makeBridge({ delayMs: 80 });
  const began = Date.now();
  const both = await Promise.all([ask(t.bridge, 'alpha'), ask(t.bridge, 'beta')]);
  const elapsed = Date.now() - began;

  assert.deepEqual(both.map((r) => r.text).sort(), ['done:alpha', 'done:beta']);
  assert.equal(t.peak, 2, '两条会话应该同时在跑');
  assert.ok(elapsed < 160, `两条会话并行应该 ~80ms，实际 ${elapsed}ms（像是一条全局链）`);
  assert.deepEqual(t.started.map((s) => s.key).sort(), ['alpha', 'beta']);
  console.log(`✓ 不同会话并行：peak=${t.peak}，用时 ${elapsed}ms`);
}

// 2) 同一会话：串行，不重叠、不乱序。
{
  const t = makeBridge({ delayMs: 50 });
  const order = [];
  const both = await Promise.all([
    ask(t.bridge, 'same').then(() => order.push('first')),
    ask(t.bridge, 'same').then(() => order.push('second')),
  ]);
  assert.equal(t.peak, 1, '同一条会话不能同时跑两轮');
  assert.deepEqual(order, ['first', 'second']);
  assert.ok(t.finished[1].at - t.started[1].at >= 45, '第二条应该等第一条跑完才开始');
  assert.equal(both.length, 2);
  console.log(`✓ 同一会话串行：peak=${t.peak}，顺序 ${order.join(' → ')}`);
}

// 3) 跑完的会话要把队列清掉，别一直堆在 Map 里。
{
  const t = makeBridge({ delayMs: 5 });
  await Promise.all([ask(t.bridge, 'gamma')]);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(t.bridge.queues.size, 0, '跑完的会话键应该从队列表里删掉');
  console.log('✓ 队列表会回收：queues.size=0');
}

console.log('\n全部通过（3 项）');
