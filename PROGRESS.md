# 进度存档（2026-11-11 03:40）

## 现在到哪了

- 原生 App（Flutter）源码已推上 GitHub：**https://github.com/J1nxi-youmi/dsh-chat**
- 两个 CI 任务：`build-apk`（Android）、`build-windows`（Windows 桌面）
- **都还没编过**，正在逐个修编译错误；Dart 部分已经能过，只剩 Android 打包配置

## 已经修掉的错误

| # | 错误 | 处理 |
|---|---|---|
| 1 | Dart raw 字符串里写 `\"`，把字符串截断了 | 改成普通字符串转义 |
| 2 | `record` 平台包签名冲突（5.x 太旧） | 升到 7.x |
| 3 | SSE 订阅类型写错（`StreamSubscription<String>`） | 改成 `Map<String, dynamic>` |
| 4 | 主工程 `compileSdk 34`，`file_picker` 要 36 | 补丁改成 36 |

## 卡在哪（下一步就从这继续）

**当前错误**：`Execution failed for task ':file_picker:checkReleaseAarMetadata'`

原因：`file_picker` 8.x 这个插件模块自己是按 compileSdk 34 编的，而它依赖的
`flutter_plugin_android_lifecycle` 要求 36。**只改主工程没用**。

试过但**不行**的做法（已回滚）：在根 `android/build.gradle.kts` 里加
`subprojects { afterEvaluate { ... compileSdkVersion(36) } }` —— 报
`Cannot run Project.afterEvaluate(Action) when the project is already evaluated`。

**推荐下一步**：

1. 把 `pubspec.yaml` 里的 `file_picker` 升到 `^13.3.3`（2026-11 最新，要求 Flutter ≥3.38，
   CI 是 3.47.9，满足）；它的 `android_file_picker` 自己就用新 compileSdk。
   注意 13.x 的 API 可能和 8.x 有差异，`lib/src/screens/chat_screen.dart` 里的
   `FilePicker.platform.pickFiles(allowMultiple: true, withData: true)` 要跟着改。
2. 或者换掉 `file_picker`，用官方 `file_selector`（`openFiles()` 返回 `XFile`）。
3. 改完推上去，看 `ci-logs` 分支上的 `build.log`（第一行是 commit sha，确认是不是最新那次）。

## 怎么看 CI 日志

CI 每次跑完会把 `build.log` / `analyze.log` 强制推到一个叫 **`ci-logs`** 的分支：

```
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs/build.log
```

第一行是 commit sha，第二行是时间——对不上就是旧日志。

## 后端那套（不依赖这个仓库）

后端是「DSH + 两个插件 + 可选中转」，代码在工作区 `Y:\deep\workshop\`，不在 GitHub 上：

| 东西 | 路径 | 作用 |
|---|---|---|
| 星伴桥插件 | `dsh-plugin-starlit-bridge/` | 在 DSH 上开 OpenAI 兼容端点，把对话跑成 DSH 的一轮 |
| 聊天服务插件 | `dsh-plugin-chat/` | 在 DSH 上起网页聊天端 + `/api/*`，App 连的就是它 |
| 中转 | `dsh-chat/relay/relay.mjs` | 两端都往外连，跨网不用公网 IP |
| 主机适配器 | `dsh-chat/relay/host.mjs` | 连中转，把 call 转成本机 HTTP |

App 连后端就两样：**地址 + 令牌**（直连），或者 **中转地址 + 房间 + 密钥**。

## App 现在的功能

- 会话列表 / 新建 / 长按删除（删了会连 DSH 会话一起删）
- 对话页：文字、图片（点开大图）、文件（点开系统程序）、语音（录/放）
- 链接可点、消息走 SSE 实时到、断线重连
- 深空底色 + 星点背景 + 渐变气泡（照星伴的调子）

## 已知待办

- [ ] 修 Android 构建（上面的 file_picker）
- [ ] 修 Windows 构建（`just_audio_windows` 和 `just_audio` 版本要对上，可能也要升）
- [ ] 附件走中转（现在中转模式下图片/语音下不来）
- [ ] 语音转文字在 App 端只发语音条，模型听到的是后端 ASR 的结果
