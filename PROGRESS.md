# 进度存档（2026-11-11 05:40）

## 方向

**目标从「陪伴产品」改成「QQ 替代品」**：能发、能收到、换设备还在。
星伴那套（角色卡/情绪/主动消息）资料留在工作区 `docs/starlit-*`，暂时封存。

## 现在能用了

- Android APK / Windows 包：CI 每次提交自动出，下载地址见 README
- 文字、图片、文件、语音、链接；多端 SSE 实时同步
- **桌面端三栏**：图标栏 + 会话列表（搜索 / 预览 / 时间）+ 聊天区；聊天区顶部有在线状态，
  消息之间有日期/时间分隔；列表会跟着新消息自动刷新
- **Enter 发送、Shift + Enter 换行**（Windows/macOS/Linux）
- **语音是按住说话**：按住开始录，松开发送，上滑取消；手机和桌面都是这一套
- **可靠投递**：每条消息带 `seq`；发送带 `clientMessageId`（幂等）；断网时先上屏标「发送中」，
  失败标红可点重发，重连自动按顺序补发；断线重连按 seq 增量补拉
- **通知 + 保活**：Android 原生前台服务把进程钉住，消息弹系统通知（点击打开 App）；
  Windows 走 `local_notifier` 系统通知
- 顺手修的 bug：Flutter 端之前**从没调用过 `startEvents()`**，SSE 其实没启动；现在提到 App 级

## 还没做

- 通知栏直接回复（RemoteInput）、Windows 托盘常驻、点通知直达具体会话
- 历史分页 + 搜索、未读红点、已读位置多端同步
- 附件上限可配（默认 12MB→64MB）、一次性签名下载链接
- 设备级 token（一设备一个、可单独吊销）
- 真机验证：锁屏 1 小时消息不丢、通知点击行为、Android 14/15 前台服务限制

## 代码地图

```
lib/
  main.dart                      入口；初始化通知服务、按上次连接进会话列表
  src/
    api.dart                     HTTP + SSE；seq 增量拉取；连接状态 ValueNotifier
    session.dart                 全局连接 + 通知中枢（SSE 挂在这里）
    notify.dart                  Android 原生通道 / Windows local_notifier
    app_state.dart               当前打开的会话 id（决定要不要弹通知）
    models.dart                  Message(seq) / Outgoing(未 ack 队列)
    screens/chat_screen.dart     聊天页：乐观发送、失败重发、断线横幅、增量补拉
tool/
  patch_android.sh               CI 里补权限/compileSdk/前台服务，并拷 tool/android/*.kt
  android/MainActivity.kt        方法通道 + 通知权限申请
  android/ChatService.kt         前台服务（remoteMessaging）
  android/Notifications.kt       通知渠道与消息通知
  patch_windows.ps1              CI 里给 just_audio_windows 加 MSVC 兼容宏
```

## 测试

```bash
node test/reliability.mjs      # 服务端协议 19 项
node test/e2e/web-e2e.mjs      # 网页端 8 项（断网重发不重复）
flutter analyze                # 静态检查
```

App 端没有自动化测试，改动后靠 CI 编译 + 真机点。

## 看日志

```
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs/build.log
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs/analyze.log
https://raw.githubusercontent.com/J1nxi-youmi/dsh-chat/ci-logs-win/windows.log
```
