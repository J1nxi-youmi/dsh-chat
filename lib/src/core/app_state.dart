import 'package:flutter/foundation.dart';

/// 当前正在看的会话 id。用来决定「这条新消息要不要弹通知」：
/// 正在看这个会话就不弹，切到别的会话或 App 在后台就弹。
final ValueNotifier<String?> activeConversationId = ValueNotifier<String?>(null);

/// 点通知要跳过去的会话 id。外壳监听到就打开它，打开后置空。
final ValueNotifier<String?> pendingConversationToOpen = ValueNotifier<String?>(null);
