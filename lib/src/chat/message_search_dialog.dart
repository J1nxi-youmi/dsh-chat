import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/core/theme.dart';

/// 当前会话内的本地消息搜索：只过滤已经加载到界面的消息。
class MessageSearchDialog extends StatefulWidget {
  const MessageSearchDialog({
    super.key,
    required this.messages,
    required this.assistantName,
  });

  final List<Message> messages;
  final String assistantName;

  @override
  State<MessageSearchDialog> createState() => _MessageSearchDialogState();
}

class _MessageSearchDialogState extends State<MessageSearchDialog> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Message> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return widget.messages.where((message) {
      if (message.text.toLowerCase().contains(query)) return true;
      return message.attachments.any(
        (item) => item.name.toLowerCase().contains(query),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final results = _filtered;
    return Dialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppTheme.line),
      ),
      child: SizedBox(
        width: 500,
        height: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '搜索聊天',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 19,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  hintText: '输入关键词，搜索文字或文件名',
                  isDense: true,
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppTheme.muted,
                  ),
                  prefixIconConstraints: BoxConstraints(
                    minWidth: 42,
                    minHeight: 0,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _query.trim().isEmpty
                  ? const Center(
                      child: Text(
                        '输入关键词开始搜索',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted),
                      ),
                    )
                  : results.isEmpty
                  ? const Center(
                      child: Text(
                        '没有找到相关消息',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      itemCount: results.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppTheme.line),
                      itemBuilder: (context, index) {
                        final message = results[index];
                        final preview = message.text.trim().isEmpty
                            ? message.attachments
                                  .map((item) => item.name)
                                  .join(' · ')
                            : message.text.replaceAll('\n', ' ');
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            message.isMine
                                ? Icons.person_outline_rounded
                                : Icons.auto_awesome_rounded,
                            size: 18,
                            color: AppTheme.accent,
                          ),
                          title: Text(
                            message.isMine
                                ? '我'
                                : widget.assistantName.trim().isEmpty
                                ? '青屿'
                                : widget.assistantName.trim(),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.muted,
                            ),
                          ),
                          trailing: Text(
                            DateFormat('MM/dd HH:mm').format(message.at),
                            style: const TextStyle(
                              fontSize: 8,
                              color: AppTheme.muted,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(message),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
