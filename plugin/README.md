# dsh-plugin-chat（DSH 插件）

装进 DSH 的聊天后端：起一个网页聊天端 + `/api/*`，**青屿**（手机/桌面 App）填「地址 + 令牌」就能连。
**自带跑 DSH 会话的 OpenAI 兼容桥**（只监听本机回环，端口可在配置里改），所以不用再单独装
`dsh-plugin-starlit-bridge`；星伴原来连内置桥端口的用法也不受影响。

## 主要能力

- **可靠投递**：消息带 `seq`，发送带 `clientMessageId` 幂等；断线用 `?since=` 增量补拉，SSE 实时推送
- **我的资料云同步**：`GET/POST /api/profile` 存昵称 + 头像 + 自定义表情包，所有设备连上自动一致；资料变化会广播 `profile` 事件让另一端即时刷新
- **语音转文字**：`POST /api/transcribe` 接受 `{id}` / `{url}` / `{file}`，用 `config.json` 的 `asrCommand` 转写；未配置返回 503，失败返回 502，App 端不会显示假结果
- **GitHub 下载代理**：`GET /api/proxy?t=<token>&url=<github 链接>`（只放行 GitHub 系域名），App 内更新直连超时自动走这条隧道兜底
- **上传上限可调**：默认 96MB，`config.json` 的 `maxUploadBytes` 或网页设置页改；`/healthz` 会把上限告诉 App
- **网页设置页**：左下角 ⚙，系统提示词 / 抓链接 / 气泡 / 上传上限，改完即时生效

## 装到 DSH

1. 把这个目录放到 DSH 的插件目录里（或用 DSH 的插件管理工具从本地目录安装）；
2. 在 profile 的 `cordis.patch.yml` 里按 `cordis.patch.yml` 的示例加一段配置；
3. 在 plugin/ 里跑一次 pnpm install（装 @deepseek-ai/schemastery，设置页要用）；
4. 重启 DSH，日志里会出现：
   `内置桥已启动`、`聊天服务已启动：http://0.0.0.0:8792`
   和 `内置桥已启动：…（会话 …）`。

> 如果之前装过 `dsh-plugin-starlit-bridge`，装好这个之后就可以把它停用/卸载。

## 设置页

网页聊天端（`http://<机器>:8792`）**左下角 ⚙** 就是设置页：系统提示词、是否抓取链接、
是否拆气泡、单文件上限，保存后立即生效并写回 `config.json`。

会话绑定（`sessionId`）不在网页设置页里，改 profile 的 `cordis.patch.yml` 后重启插件生效。

## 文件上限

默认 96MB。三种改法：

1. 网页端左下角 ⚙ → 「单文件上限（MB）」，保存立即生效（写入插件目录的 `config.json`）；
2. 手动改插件目录的 `config.json`（单位是字节）：

   ```json
   { "maxUploadBytes": 209715200 }
   ```

   改完重载插件生效；
3. **App 端自己也有一道 96MB 的检查**：服务端放大以后，App 仍会拦；
   要让 App 也放开，需要改客户端并重新出包。

`/healthz` 会返回 `maxUploadBytes`，客户端可以据此显示真实上限。

## 配置

| 字段 | 默认 | 说明 |
|---|---|---|
| `host` | `0.0.0.0` | 监听地址；只给本机用填 `localhost` |
| `port` | `8792` | 聊天服务端口，App 连这个 |
| `token` | 空 | 访问令牌，App 里要填同一个；留空会自动生成并打印 |
| `baseUrl` | 空 | **留空 = 用内置桥**；填了就转发给任意 OpenAI 兼容后端 |
| `sessionKey` | `fixed` | 怎么分会话：`fixed` 全部共用一条 / `auto` 按角色设定 / `model` 按 model 字段 |
| `sessionId` | 空 | 想写进**已有会话**就填它的 id；留空会自动建一条并一直复用 |
| `mode` | `chat` | `chat` 只走模型通道；`agent` 会真的开 DSH 会话、能调工具 |
| `persona` | `dsh` | `agent` 模式下是否注入星伴人设（用 `starlit` 开） |
| `tools` | `false` | `agent` 模式下是否放开工具，公网暴露时别开 |
| `relayUrl` / `relayRoom` / `relayKey` | 空 | 填了就连中转，跨网不用公网 IP |

## App 怎么连

聊天页填：

```
服务器地址: http://<这台机器的 IP>:8792     （同 Wi-Fi）
            https://<隧道或中转地址>        （跨网）
令牌:      <上面配置的 token>
```

## 自己测

```bash
node test/reliability.mjs   # 协议层 19 项：ack / 幂等 / 失败重试 / since
```

`data/` 是运行时目录（会话、附件、桥的会话映射），不用提交。

## 和 App 的关系

App 源码在仓库根目录（Flutter，Android + Windows），这个 `plugin/` 是它的后端。
两边协议：消息带 `seq`、发送带 `clientMessageId`（幂等）、断线用 `?since=` 增量补。
