/**
 * 插件自己的版本检查。
 *
 * 插件在 GitHub 上发的是 `plugin-v<版本>` 的 Release（都是预发布），这里拉一份 release
 * 列表，挑出比当前版本新的最高版本。网络不通、限流、超时都当「没有新版本」：
 * 不抛错、不挡服务，最多在日志里留一行。
 */

const DEFAULT_REPO = 'J1nxi-youmi/dsh-chat';
const DEFAULT_INTERVAL_MS = 6 * 60 * 60 * 1000;

/** `plugin-v0.2.7` → `{ version: '0.2.7', major: 0, minor: 2, patch: 7 }`；别的 tag 返回 null。 */
export function parsePluginTag(tag) {
  const match = /^plugin-v(\d+)\.(\d+)\.(\d+)$/.exec(String(tag ?? '').trim());
  if (!match) return null;
  const major = Number(match[1]);
  const minor = Number(match[2]);
  const patch = Number(match[3]);
  return { version: `${major}.${minor}.${patch}`, major, minor, patch };
}

/** 语义化比较：a 比 b 新返回 1，一样返回 0，旧返回 -1。 */
export function compareVersions(a, b) {
  const parse = (value) =>
    String(value ?? '0')
      .split('.')
      .map((part) => Number.parseInt(part, 10) || 0);
  const left = parse(a);
  const right = parse(b);
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const l = left[index] ?? 0;
    const r = right[index] ?? 0;
    if (l > r) return 1;
    if (l < r) return -1;
  }
  return 0;
}

/**
 * 从 release 列表里挑一条比 current 新的插件版本。
 * 草稿跳过；预发布不跳过——插件的 Release 本来就都标成 Pre-release。
 *
 * @param {unknown} releases GitHub `/releases` 的返回
 * @param {string} current 当前插件版本，如 `0.2.6`
 */
export function pickPluginRelease(releases, current) {
  let best = null;
  for (const release of Array.isArray(releases) ? releases : []) {
    if (!release || release.draft) continue;
    const parsed = parsePluginTag(release.tag_name);
    if (!parsed) continue;
    if (compareVersions(parsed.version, current) <= 0) continue;
    if (!best || compareVersions(parsed.version, best.version) > 0) {
      best = { version: parsed.version, release };
    }
  }
  if (!best) return null;
  return {
    latest: best.version,
    tag: String(best.release.tag_name ?? ''),
    url: String(best.release.html_url ?? ''),
    notes: String(best.release.body ?? '').slice(0, 800),
    publishedAt: String(best.release.published_at ?? ''),
  };
}

/**
 * 建一个带缓存的检查器：同一个进程里默认 6 小时才打一次 GitHub。
 * 返回的函数永远不会 reject。
 */
export function createUpdateChecker({
  repo = DEFAULT_REPO,
  current,
  intervalMs = DEFAULT_INTERVAL_MS,
  fetchImpl = globalThis.fetch,
  logger,
} = {}) {
  let checkedAt = 0;
  let checked = false;
  let cached = null;

  return async function check({ force = false } = {}) {
    const now = Date.now();
    if (!force && checked && now - checkedAt < intervalMs) return cached;
    checked = true;
    checkedAt = now;
    try {
      const response = await fetchImpl(`https://api.github.com/repos/${repo}/releases?per_page=30`, {
        headers: { accept: 'application/vnd.github+json', 'user-agent': 'dsh-plugin-chat' },
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) return cached;
      cached = pickPluginRelease(await response.json(), current);
    } catch (error) {
      logger?.warn?.(`检查插件更新失败：${error?.message ?? error}`);
    }
    return cached;
  };
}
