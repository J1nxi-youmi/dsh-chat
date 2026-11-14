/**
 * 插件自己的版本检查。
 *
 * 跑法：node test/update.test.mjs
 */
import assert from 'node:assert/strict';
import {
  compareVersions,
  createUpdateChecker,
  parsePluginTag,
  pickPluginRelease,
} from '../lib/update.js';

// 1) tag 解析：只认 plugin-v<数字>.<数字>.<数字>
{
  const parsed = parsePluginTag('plugin-v0.2.7');
  assert.equal(parsed.version, '0.2.7');
  assert.equal(parsed.major, 0);
  assert.equal(parsed.minor, 2);
  assert.equal(parsed.patch, 7);
  assert.equal(parsePluginTag('v1.2.3'), null, 'App 的 tag 不是插件版本');
  assert.equal(parsePluginTag('latest-build'), null);
  assert.equal(parsePluginTag('plugin-v0.2'), null, '少一段不算');
  assert.equal(parsePluginTag(undefined), null);
  console.log('✓ tag 解析');
}

// 2) 版本比较
{
  assert.equal(compareVersions('0.2.7', '0.2.6'), 1);
  assert.equal(compareVersions('0.2.6', '0.2.7'), -1);
  assert.equal(compareVersions('0.2.6', '0.2.6'), 0);
  assert.equal(compareVersions('0.10.0', '0.9.9'), 1, '按数字比，不按字符串');
  assert.equal(compareVersions('1.0.0', '0.99.99'), 1);
  console.log('✓ 版本比较');
}

// 3) 从 release 列表里挑：跳过草稿和 App 的 tag，挑最高的新版本
{
  const releases = [
    { tag_name: 'plugin-v0.2.5', draft: false, html_url: 'https://x/0.2.5' },
    { tag_name: 'plugin-v0.2.7', draft: false, html_url: 'https://x/0.2.7' },
    { tag_name: 'plugin-v0.3.0', draft: true, html_url: 'https://x/0.3.0' },
    { tag_name: 'latest-build', draft: false },
    { tag_name: 'v1.4.8', draft: false },
  ];
  const hit = pickPluginRelease(releases, '0.2.6');
  assert.equal(hit.latest, '0.2.7');
  assert.equal(hit.url, 'https://x/0.2.7');

  // 已经是最新：不该提示
  assert.equal(pickPluginRelease(releases, '0.2.7'), null);
  assert.equal(pickPluginRelease([], '0.2.6'), null);
  assert.equal(pickPluginRelease(null, '0.2.6'), null);
  console.log('✓ 挑版本');
}

// 4) 检查器：带缓存、失败不抛
{
  let calls = 0;
  const releases = [{ tag_name: 'plugin-v0.9.9', draft: false, html_url: 'https://x/0.9.9' }];
  const check = createUpdateChecker({
    current: '0.2.6',
    fetchImpl: async () => {
      calls += 1;
      return { ok: true, json: async () => releases };
    },
  });

  const first = await check();
  assert.equal(first.latest, '0.9.9');
  await check();
  assert.equal(calls, 1, '缓存期内不重复请求');
  await check({ force: true });
  assert.equal(calls, 2, 'force 会重新查');
  console.log('✓ 缓存');
}

{
  const check = createUpdateChecker({
    current: '0.2.6',
    fetchImpl: async () => ({ ok: false, json: async () => ({}) }),
  });
  assert.equal(await check(), null, '接口不通就是没有新版');
  console.log('✓ 接口失败不报错');
}

{
  const check = createUpdateChecker({
    current: '0.2.6',
    fetchImpl: async () => {
      throw new Error('网络炸了');
    },
  });
  assert.equal(await check(), null, '抛错也要吞掉');
  console.log('✓ 网络异常不抛');
}

console.log('\n全部通过（6 项）');
