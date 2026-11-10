# dsh-chat-app

连任意一台 DSH 的原生聊天客户端。**Flutter 一套代码，Android + Windows。**

核心：文字、图片、链接、语音、文件，双向收发；后端是任意一台装着 `dsh-plugin-chat` 的 DSH
（手机本机引擎也行，电脑也行）。

## 直接下载

`main` 每次提交 CI 都会自动覆盖这两个文件（免登录）：

| 平台 | 链接 | 说明 |
|---|---|---|
| Android | <https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat.apk> | 传到手机装，允许「安装未知来源」 |
| Windows | <https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat-windows.zip> | 解压后跑 `dsh_chat.exe` |

## 长什么样

- 深色主题，会话列表 + 气泡对话
- 图片点开大图，链接点开浏览器，文件点开系统程序
- 语音按一下录、再按一下发，气泡里点播放
- 断线自动重连（SSE），回复一条条冒出来

## 自己构建（不用装 Android SDK / Visual Studio）

仓库里只有 `lib/`、`pubspec.yaml` 和补丁脚本，平台工程由 CI 现生成：

1. 推到 GitHub 的 `main` 分支；
2. **Actions** 里会自动跑 `build-apk` 和 `build-windows`；
3. 成功后在 **Artifacts** 下 `dsh-chat-apk` / `dsh-chat-windows`，同时覆盖到 `latest-build` release。

第一次构建大约 5–8 分钟，之后有缓存会快很多。

> 本地也能编（装 Flutter + Android SDK / Visual Studio 就行）：
> `flutter create --platforms=android . && flutter build apk`。
> 只跑静态检查的话 `flutter pub get && flutter analyze` 就够。

## 连哪台 DSH

App 第一次打开会要两样东西：

| 字段 | 例子 | 从哪来 |
|---|---|---|
| 服务器地址 | `http://192.168.1.101:8792` | 那台 DSH 上 `dsh-plugin-chat` 的端口 |
| 令牌 | `chatdemo123` | 同一个插件的配置 |

- 同一 WiFi：直接填内网 IP；
- 跨网：填中转给的地址（配了 `relayUrl` 的话），或者固定域名的隧道地址。
- 换机器：列表右上角「换一台 DSH」，重新填即可。

## 后端要做什么

在 DSH 那台机器上装两个插件：

1. `dsh-plugin-starlit-bridge`（或者任意 OpenAI 兼容后端）——负责把对话跑成 DSH 的一轮；
2. `dsh-plugin-chat` —— 起聊天服务和网页端，`baseUrl` 指向第 1 个。

然后手机的 App 连 `dsh-plugin-chat` 的地址就行。

## 目录

```
lib/
  main.dart                    入口、启动时读上次连接
  src/
    api.dart                   HTTP + SSE 客户端，断线重连
    models.dart                会话/消息/附件
    theme.dart                 配色和小组件
    screens/connect_screen.dart      填地址和令牌
    screens/conversations_screen.dart 会话列表
    screens/chat_screen.dart         对话、发消息、录音、选文件
    widgets/message_bubble.dart      气泡：文字/链接/图片/语音/文件
tool/patch_android.sh           CI 里补权限和明文 HTTP
tool/patch_windows.ps1          CI 里给生成的 CMakeLists 加 MSVC 兼容宏
.github/workflows/build.yml     出 APK
.github/workflows/build-windows.yml  出 Windows 包
```

## 已知限制

- iOS 还没做；需要 macOS + Xcode 才能编。
- 语音是「发语音条」，模型听到的是转写文字（后端配了 ASR 才有，没配就只有「语音，约 N 秒」）。
- 附件走 HTTP 直连；如果后端只走中转，图片/语音暂时拿不到。
- 大文件上限 12MB（跟服务端一致）。
