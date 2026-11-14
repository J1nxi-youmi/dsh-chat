# 插件 CHANGELOG

`dsh-plugin-chat` 的改动记在这里。插件有自己的版本号（`plugin/package.json` 的 `version`），
和 App 的构建号互不影响：改 `plugin/**` 只会触发 `.github/workflows/plugin.yml`，
出一个 `plugin-v<版本>` 的 Release，不会重新构建 App，也不会动 App 的版本号。

## v0.2.7（2026-11-14）

- **自己检查有没有新版**：启动时列一次 GitHub 的 `plugin-v*` Release，比自己 `package.json` 的 version 新就在日志里提一行；`GET /api/plugin-update` 也能问，`/healthz` 多了 `pluginVersion`
- 检查带 6 小时缓存，网络不通 / 限流 / 超时一律当「没有新版」，不抛错、不挡服务
- 新增 `plugin/test/update.test.mjs`（`pnpm test:update`）

## v0.2.6（2026-11-14）

- 插件改成**独立发版**：`.github/workflows/plugin.yml` 只在 `plugin/**` 变动时跑，打 `plugin-v<版本>` 的 Release；App 的 `build.yml` 忽略 `plugin/**`，改插件不再顶 App 的构建号
- 打包补上 `relay/`：以前 npm 包里没有中转适配器，配了 `relayUrl` 的部署解包后连不上中转
- 包内带上 `CHANGELOG.md`，去掉不存在的 `locale` 目录

## v0.2.5（2026-11-14）

- 同一会话连发两条改成**按顺序排队**：不再并行抢答，回复不交错；不同会话照旧各跑各的。新增 `plugin/test/turns.mjs`（`pnpm test:turns`）把「跨会话并行 / 同会话串行」都钉住
- 落盘改成**攒一攒再写**：不再每来一条消息就把整份 `db.json` 序列化一次，一轮回复拆几个气泡也只写一遍
- 追加消息的 `seq` 改成 O(1) 取号（以前每条都要扫一遍全部消息）
- 用户发来的两个链接改成**同时抓**：最坏等 8 秒，而不是一个接一个等 16 秒

## v0.2.4（2026-11-14）

- 桥的回合改成**按会话各排各的**：同一条会话仍然串行，不同会话并行。以前是一条全局链，新开一条会话要等前一条跑完，看起来像「开了新会话没反应」
- 新增回归测试 `plugin/test/session-queue.test.mjs`（`pnpm test:queue`）：不同会话并行、同一会话串行且不乱序
