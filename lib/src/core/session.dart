import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'app_state.dart';
import 'notify.dart';

/// 全局唯一的聊天连接。
///
/// 谁创建了 [ChatApi]（启动时读配置、或者在连接页换了服务器），就交给 [attach]：
/// 它负责挂上 SSE、把新消息变成系统通知。这样通知不依赖某个页面是否打开。
class Session {
  static ChatApi? api;

  static void attach(ChatApi next) {
    if (identical(api, next)) return;
    api?.dispose();
    api = next;
    next.startEvents();
    unawaited(next.refreshLimits());
    unawaited(next.refreshProfile());
    next.events.listen(_onEvent);
  }

  static void _onEvent(Map<String, dynamic> event) {
    // 另一台设备改了资料/表情包：重新拉取，界面靠 AppProfile 通知刷新。
    if (event['type'] == 'profile') {
      final current = api;
      if (current != null) unawaited(current.refreshProfile());
      return;
    }
    if (event['type'] != 'message') return;
    final raw = event['message'];
    if (raw is! Map<String, dynamic>) return;
    // 只提醒「她说的」，自己发的不用提醒。
    if (raw['role'] != 'assistant') return;
    final conversationId = event['conversationId']?.toString() ?? '';
    final resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // 正在看这个会话、App 也在前台，就不打扰。
    if (resumed && activeConversationId.value == conversationId) return;
    final text = (raw['text']?.toString() ?? '').trim();
    if (text.isEmpty) return;
    final body = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    Notifier.show(title: '新消息', body: body);
  }

  static void dispose() {
    api?.dispose();
    api = null;
  }
}
