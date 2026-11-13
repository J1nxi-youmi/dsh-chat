import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 聊天列表的底部锚点状态机。
///
/// 列表是 reverse 的，index 0 是 1px 底部锚点。这里统一处理：
/// - 发送后立即 jump 到底部
/// - 列表重建后补一次 jump
/// - 是否贴底 / 底部未读数
///
/// ChatScreen 不再自己散落 Timer、postFrame 和 atBottom 判断。
class ChatScrollController {
  ChatScrollController({required this.contentCount, required this.onChanged});

  final int Function() contentCount;
  final void Function() onChanged;

  final itemScroll = ItemScrollController();
  final itemPositions = ItemPositionsListener.create();

  bool _atBottom = true;
  int _unread = 0;
  Timer? _settleTimer;

  bool get atBottom => _atBottom;
  int get unreadBelow => _unread;

  void attach() {
    itemPositions.itemPositions.addListener(_onPositionsChanged);
  }

  void dispose() {
    itemPositions.itemPositions.removeListener(_onPositionsChanged);
    _settleTimer?.cancel();
  }

  void reset() {
    _atBottom = true;
    _unread = 0;
  }

  void addUnread(int count) {
    if (count <= 0) return;
    _unread += count;
    onChanged();
  }

  void scrollToBottom({bool settle = false}) {
    _jumpNow();
    SchedulerBinding.instance.addPostFrameCallback((_) => _jumpNow());
    if (!settle) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 350), () {
      if (_atBottom) _jumpNow();
    });
  }

  void _jumpNow() {
    if (!itemScroll.isAttached) return;
    if (contentCount() == 0) return;
    if (_unread != 0 || !_atBottom) {
      _unread = 0;
      _atBottom = true;
      onChanged();
    }
    itemScroll.jumpTo(index: 0, alignment: 0);
  }

  void _onPositionsChanged() {
    final count = contentCount();
    final atBottom =
        count == 0 ||
        itemPositions.itemPositions.value.any(
          (position) => position.index == 0,
        );
    if (atBottom == _atBottom) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (atBottom == _atBottom) return;
      _atBottom = atBottom;
      if (atBottom) _unread = 0;
      onChanged();
    });
  }
}
