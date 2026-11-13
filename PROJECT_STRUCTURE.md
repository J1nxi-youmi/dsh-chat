# 代码分类

`lib/src/` 按职责分域，不再把所有文件堆在 `screens/` 和 `widgets/`。

```text
lib/
  main.dart                 # 启动、窗口、Session 装配
  src/
    core/                   # 无页面依赖的基础层
      api.dart              # HTTP / SSE / 上传
      models.dart           # Message / Conversation / Outgoing
      session.dart          # 会话与连接状态
      profile.dart          # 资料、头像、表情包
      update.dart           # Release / 版本 / 下载
      notify.dart           # 本地通知
      theme.dart            # 主题与头像
      image_utils.dart      # 图片处理
      app_state.dart
    chat/                   # 聊天域
      chat_screen.dart      # 消息流、发送、上传、录音的编排
      controllers/          # 可复用状态机
        chat_scroll_controller.dart
      services/             # 纯副作用能力
        chat_file_actions.dart
      widgets/              # 聊天专用展示组件
        chat_message_list.dart
        pending_attachment_tile.dart
        message_bubble.dart
        message_search_dialog.dart
        sticker_panel.dart
    settings/               # 设置/资料/版本
      settings_screen.dart
      desktop_settings_view.dart
      mobile_settings_view.dart
      settings_widgets.dart
      profile_dialog.dart
      version_screen.dart
    shell/                  # 外壳与导航
      desktop_home.dart
      conversations_screen.dart
      connect_screen.dart
```

## 依赖方向

- `core` 不依赖 `chat`、`settings`、`shell` 的页面。
- `chat` 依赖 `core`，不依赖 `settings`/`shell`。
- `settings` 可以依赖 `core` 和 `shell/connect_screen.dart`（换服务器）。
- `shell` 负责组合 `chat` 和 `settings`。
- `main.dart` 只做启动和顶层装配。
- 域内再按角色分：`widgets/` 只放 UI，`controllers/` 放状态机，`services/` 放下载/文件等副作用，`chat_screen.dart` 只做编排。

## 继续拆分的边界

`chat/chat_screen.dart` 还承担发送队列、附件上传、录音、输入器和表情入口。
下一步按 `ChatComposer`、`AttachmentUploader`、`OutgoingQueue` 继续拆，优先保持双端同步和 SSE 逻辑不动。

新增文件先判断归属域，再判断角色（UI / 状态 / 服务）；不要把聊天专用组件放回通用 `widgets/`，也不要把文件下载逻辑塞回 `MessageBubble`。
