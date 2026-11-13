import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/core/theme.dart';
import 'message_bubble.dart';

/// 聊天消息列表：反向布局，index 0 是底部锚点。
/// ChatScreen 只负责数据流，列表布局和日期分隔都在这里。
class ChatMessageList extends StatelessWidget {
  const ChatMessageList({
    super.key,
    required this.messages,
    required this.outbox,
    required this.sending,
    required this.highlightedMessageId,
    required this.mediaUrl,
    required this.itemScrollController,
    required this.itemPositionsListener,
    required this.isDesktop,
    required this.onRetry,
    required this.onReply,
    required this.onShare,
    required this.onDelete,
  });

  final List<Message> messages;
  final List<Outgoing> outbox;
  final bool sending;
  final String? highlightedMessageId;
  final String Function(String) mediaUrl;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final bool isDesktop;
  final ValueChanged<Outgoing> onRetry;
  final ValueChanged<Message> onReply;
  final ValueChanged<Message> onShare;
  final ValueChanged<Message> onDelete;

  int get _contentCount => messages.length + outbox.length + (sending ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final contentCount = _contentCount;
    final list = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isDesktop ? 780 : double.infinity,
        ),
        child: ScrollablePositionedList.builder(
          reverse: true,
          itemScrollController: itemScrollController,
          itemPositionsListener: itemPositionsListener,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
          itemCount: contentCount > 0 ? contentCount + 1 : 0,
          itemBuilder: (context, index) {
            if (index == 0) return const SizedBox(height: 1);
            final contentIndex = contentCount - index;
            if (contentIndex < messages.length) {
              final message = messages[contentIndex];
              final bubble = MessageBubble(
                message: message,
                mediaUrl: mediaUrl,
                highlighted: highlightedMessageId == message.id,
                onReply: () => onReply(message),
                onShare: () => onShare(message),
                onDelete: () => onDelete(message),
              );
              return _needsDivider(contentIndex)
                  ? Column(children: [_timeDivider(message.at), bubble])
                  : bubble;
            }
            final outboxIndex = contentIndex - messages.length;
            if (outboxIndex < outbox.length) {
              final item = outbox[outboxIndex];
              return MessageBubble(
                message: item.asMessage(),
                mediaUrl: mediaUrl,
                status: item.status,
                onRetry: item.status == 'failed' ? () => onRetry(item) : null,
              );
            }
            return const TypingRow();
          },
        ),
      ),
    );
    // 桌面端允许鼠标左键拖选气泡内文字，Ctrl+C 直接复制。
    return isDesktop ? SelectionArea(child: list) : list;
  }

  bool _needsDivider(int index) {
    if (index == 0) return true;
    final previous = messages[index - 1].at;
    final current = messages[index].at;
    if (previous.year != current.year ||
        previous.month != current.month ||
        previous.day != current.day) {
      return true;
    }
    return current.difference(previous).inMinutes >= 5;
  }

  Widget _timeDivider(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final String label;
    if (day == today) {
      label = '今天';
    } else if (day == today.subtract(const Duration(days: 1))) {
      label = '昨天';
    } else if (time.year == now.year) {
      label = '${time.month}月${time.day}日';
    } else {
      label = '${time.year}年${time.month}月${time.day}日';
    }
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.panelAlt.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$label $hhmm',
            style: const TextStyle(fontSize: 11, color: AppTheme.muted),
          ),
        ),
      ),
    );
  }
}
