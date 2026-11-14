import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';

/// 系统通知 + Android 前台服务。
///
/// - Android：走原生 `dsh/chat_service` 通道（通知 + 保活服务在 Kotlin 里）；
/// - Windows：走 local_notifier 的系统 Toast；
/// - 其它平台：静默跳过（网页端本来就有浏览器通知以外的手段）。
class Notifier {
  static const _channel = MethodChannel('dsh/chat_service');
  static bool _ready = false;

  /// 点通知要打开哪条会话：Android 原生活动把 id 送回来。
  static void Function(String conversationId)? onOpenConversation;

  static Future<void> setup() async {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'opened') {
          final id = call.arguments?.toString() ?? '';
          if (id.isNotEmpty) onOpenConversation?.call(id);
        }
        return null;
      });
    }
    if (Platform.isWindows) {
      try {
        await localNotifier.setup(
          appName: 'dsh-chat',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
      } catch (_) {
        /* 没装成功也不影响聊天 */
      }
    }
    if (Platform.isAndroid) {
      // 启动前台服务：App 切后台/锁屏时 SSE 连接还能活着。
      try {
        await _channel.invokeMethod('start');
      } catch (_) {
        /* 老系统或没权限就先算了 */
      }
    }
    _ready = true;
  }

  /// 冷启动时通知带进来的会话 id（只取一次）。
  static Future<String?> initialConversation() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('initialConversation');
    } catch (_) {
      return null;
    }
  }

  static Future<void> show({
    required String title,
    required String body,
    String? conversationId,
  }) async {
    if (!_ready) return;
    if (Platform.isWindows) {
      try {
        final notification = LocalNotification(title: title, body: body);
        await notification.show();
      } catch (_) {
        /* 忽略 */
      }
      return;
    }
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('notify', {
          'title': title,
          'body': body,
          'conversationId': conversationId,
        });
      } catch (_) {
        /* 用户可能没给通知权限 */
      }
    }
  }
}
