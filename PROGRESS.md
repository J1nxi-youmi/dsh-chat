# 进度存档（2026-11-11 04:20）

## 现在到哪了

**两条 CI 都绿了**（Flutter 3.47.9 / Dart 3.13.7，GitHub Actions）：

| 任务 | 结果 | 产物 |
|---|---|---|
| `build-apk` | ✅ | `app-release.apk`（约 54 MB，含全部 ABI） |
| `build-windows` | ✅ | `dsh_chat.exe` + 依赖 DLL（Release 目录打包约 12 MB） |

免登录下载（main 每次提交自动覆盖同一个 release）：

- Android：<https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat.apk>
- Windows：<https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat-windows.zip>

## 修掉的两个拦路虎

| # | 现象 | 原因 | 修法 |
|---|---|---|---|
| 1 | `Execution failed for task ':file_picker:checkReleaseAarMetadata'`：`:file_picker is currently compiled against android-34`，而 `flutter_plugin_android_lifecycle` 要 36 | `file_picker` 8.x 的 Android 模块**硬编码** `compileSdkVersion 34`；只抬主工程没用，`afterEvaluate` 那种补丁又会崩 | 升到 **file_picker 13.3.3**：它拆成联邦插件，`android_file_picker` 用 `flutter.compileSdkVersion` 编译，不再写死版本。API 也跟着变：`FilePicker.pickFiles()` 变成静态方法、直接返回 `List<PlatformFile>`，没有 `withData`，字节要自己 `readAsBytes()` |
| 2 | Windows：`error C2338: static assertion failed: 'error STL1011: The /await compiler option, <experimental/coroutine> ... deprecated by Microsoft and will be REMOVED SOON'`，目标 `just_audio_windows_plugin.vcxproj` | `just_audio_windows` 0.2.3 的 C++/WinRT 还在用 `/await` + `<experimental/coroutine>`；`windows-latest` 上的 VS 18 / MSVC 14.51 把这条路直接判成**错误** | 新增 `tool/patch_windows.ps1`：在 `flutter create` 生成的 `windows/CMakeLists.txt` 里加 `add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)`（目录级宏，会继承到插件子目录） |

顺手做的：

- `just_audio` 0.9.42 → **0.10.6**，和 `just_audio_windows` 0.2.3 的方法通道协议对上。
- 删掉模板生成的 `test/widget_test.dart`（它测的是模板的 `MyApp`），`flutter analyze` 从 20 个假错误变成 **0 issue**。
- Windows CI 也把构建输出推到 **`ci-logs-win`** 分支（Actions 原始日志要登录才能看）。
- APK / Windows 包自动上传到 `latest-build` release，手机点链接就能装。
- 仓库里删掉误提交的 `analyze.log` / `build.log`（CI 日志只留在 `ci-logs` / `ci-logs-win` 分支）。

## 怎么看 CI 日志

CI 每次跑完会把日志强制推到分支，第一行是 commit sha，第二行是时间——对不上就是旧日志。

```
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs/build.log      # Android 构建
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs/analyze.log    # flutter analyze
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs-win/windows.log # Windows 构建（MSVC/CMake 报错都在这）
```

## 本地怎么验证（这台机器已经装好 Flutter）

```
Y:\deep\workshop\tools\flutter\flutter\bin\flutter.bat
```

```powershell
$env:PATH = "Y:\deep\workshop\tools\git\cmd;Y:\deep\workshop\tools\flutter\flutter\bin;" + $env:PATH
cd Y:\deep\workshop\dsh-chat-app
flutter pub get
flutter analyze          # 应该 No issues found
```

没有 Visual Studio / Android SDK，所以**只是不能在本机出包**，出包还是交给 CI。

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
- Android + Windows 同一套代码

## 已知待办

- [ ] 附件走中转（现在中转模式下图片/语音下不来）
- [ ] App 里把「中转房间」做成扫码配对
- [ ] 语音转文字在 App 端只发语音条，模型听到的是后端 ASR 的结果
- [ ] Windows 上还没实机点过（CI 只证明能编过）
- [ ] iOS 还没做（要 macOS + Xcode）
