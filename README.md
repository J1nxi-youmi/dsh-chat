# dsh-chat-app

连任意一台 DSH 的原生聊天客户端。**Flutter 一套代码，Android + Windows。**

核心：文字、图片、链接、语音、文件，双向收发；后端是任意一台装着 `dsh-plugin-chat` 的 DSH
（手机本机引擎也行，电脑也行）。

## 直接下载

`main` 每次提交 CI 都会自动覆盖这几个文件（免登录）：

| 平台 | 链接 | 说明 |
|---|---|---|
| Android | <https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat.apk> | 传到手机装，允许「安装未知来源」 |
| Windows（安装包） | <https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat-setup.exe> | 双击安装，可改安装位置、自动建桌面快捷方式 |
| Windows（便携） | <https://github.com/J1nxi-youmi/dsh-chat/releases/latest/download/dsh-chat-windows.zip> | 解压后跑 `dsh_chat.exe` |

> 安装包用固定的 keystore 签名（`tool/android/dsh-chat.jks`），所以 Android 以后可以直接覆盖安装；
> 第一次从旧版本（debug 签名）换过来需要先卸载一次。

## 长什么样（桌面端）

- 三栏：图标栏 + 会话列表（搜索 / 预览 / 时间）+ 聊天区
- Enter 发送，Shift + Enter 换行
- 文件直接拖进聊天框；Ctrl+V 粘贴图片或文件
- 语音按住说话，松开发送，上滑取消
- 单文件上限默认 96MB（插件 `config.json` 或网页设置页可改，App 端校验默认也是 96MB）

## 长什么样（手机端）

- 深色主题，会话列表 + 气泡对话
- 图片点开大图，链接点开浏览器，文件点开系统程序
- 语音按住说话、点气泡播放
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

在 DSH 那台机器上**只装一个插件**：本仓库的 [`plugin/`](plugin/README.md)（`dsh-plugin-chat`）。

- 它自带一个 OpenAI 兼容的桥（只监听本机回环，端口可在配置里改），把聊天直接跑成这条 DSH 里的一轮；
  不用再单独装 `dsh-plugin-starlit-bridge`（已经合并进来了）；
- 所有聊天默认写进**同一条会话**（`sessionKey: fixed`）。想写进某条已有会话，
  把它的会话 id 填到插件配置的 `sessionId` 里；留空则自动建一条并一直复用；
- 想接别的大模型也可以：把 `baseUrl` 填成任意 OpenAI 兼容地址即可（留空就用内置桥）。

安装步骤、配置项都在 [plugin/README.md](plugin/README.md)。

然后 App 连 `dsh-plugin-chat` 的地址就行。

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
- 大文件上限 96MB（跟服务端一致，`config.json` 里可调 `maxUploadBytes`）。
