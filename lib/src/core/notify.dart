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

  static Future<void> setup() async {
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

  static Future<void> show({required String title, required String body}) async {
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
        await _channel.invokeMethod('notify', {'title': title, 'body': body});
      } catch (_) {
        /* 用户可能没给通知权限 */
      }
    }
  }
}
