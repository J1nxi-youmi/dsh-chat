import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../profile.dart';
import '../theme.dart';

/// 表情包面板：最近 / 我的表情包 / 表情 三个标签，支持搜索、管理和添加。
class StickerPanel extends StatefulWidget {
  const StickerPanel({
    super.key,
    required this.mediaUrl,
    required this.onEmoji,
    required this.onSendSticker,
    required this.onDelete,
    required this.onAdd,
    required this.onClose,
  });

  final String Function(String) mediaUrl;
  final ValueChanged<String> onEmoji;
  final ValueChanged<Attachment> onSendSticker;
  final Future<void> Function(Attachment) onDelete;
  final VoidCallback onAdd;
  final VoidCallback onClose;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  static const _emojis = [
    '🙂',
    '😄',
    '😊',
    '🥰',
    '😌',
    '😴',
    '🤔',
    '😅',
    '😂',
    '🤗',
    '😎',
    '💛',
    '❤️',
    '✨',
    '🌙',
    '☀️',
    '🌿',
    '🍵',
    '🎵',
    '📷',
    '🎁',
    '🐱',
    '🐶',
    '🌸',
    '🍰',
    '🚀',
    '💪',
    '👏',
    '👍',
    '🙌',
    '🤝',
    '🌊',
  ];

  final _search = TextEditingController();
  int _tab = 0;
  bool _managing = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 没有表情包时直接显示系统表情，避免一打开是空白页。
    _tab = AppProfile.instance.stickers.isEmpty ? 2 : 0;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppProfile.instance,
      builder: (context, _) {
        final all = AppProfile.instance.stickers;
        final stickers = _filtered(all);
        return Container(
          color: AppTheme.panel,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _tabChip(0, '最近', all.length),
                            const SizedBox(width: 6),
                            _tabChip(1, '我的表情包', all.length),
                            const SizedBox(width: 6),
                            _tabChip(2, '表情', null),
                          ],
                        ),
                      ),
                    ),
                    if (_tab != 2 && all.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(() => _managing = !_managing),
                        style: TextButton.styleFrom(
                          foregroundColor: _managing
                              ? AppTheme.accent
                              : AppTheme.muted,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: Text(
                          _managing ? '完成' : '管理',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    IconButton(
                      tooltip: '添加表情包',
                      onPressed: widget.onAdd,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.add_rounded,
                        size: 19,
                        color: AppTheme.muted,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: widget.onClose,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: AppTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_tab != 2)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: SizedBox(
                    height: 34,
                    child: TextField(
                      controller: _search,
                      onChanged: (value) => setState(() => _query = value),
                      style: const TextStyle(fontSize: 11),
                      decoration: const InputDecoration(
                        hintText: '搜索表情',
                        isDense: true,
                        filled: true,
                        fillColor: AppTheme.panelAlt,
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: AppTheme.muted,
                        ),
                        prefixIconConstraints: BoxConstraints(
                          minWidth: 38,
                          minHeight: 0,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          borderSide: BorderSide(color: AppTheme.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          borderSide: BorderSide(color: AppTheme.line),
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              if (_managing && _tab != 2 && stickers.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '点右上角 × 删除，删除后会同步到另一台设备。',
                      style: TextStyle(fontSize: 8, color: AppTheme.muted),
                    ),
                  ),
                ),
              Expanded(
                child: _tab == 2 ? _emojiGrid() : _stickerGrid(stickers),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Attachment> _filtered(List<Attachment> all) {
    final query = _query.trim().toLowerCase();
    final list = query.isEmpty
        ? (List<Attachment>.of(all))
        : all.where((item) => item.name.toLowerCase().contains(query)).toList();
    if (_tab == 0) return list.reversed.toList();
    return list;
  }

  Widget _tabChip(int index, String label, int? count) {
    final active = _tab == index;
    return Material(
      color: active
          ? AppTheme.accent.withValues(alpha: 0.1)
          : AppTheme.panelAlt,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() {
          if (_tab != index) _managing = false;
          _tab = index;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(
            count == null ? label : '$label ($count)',
            style: TextStyle(
              fontSize: 10,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? AppTheme.accent : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _emojiGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: _emojis.length,
      itemBuilder: (context, index) {
        final emoji = _emojis[index];
        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: () => widget.onEmoji(emoji),
            child: Center(
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
          ),
        );
      },
    );
  }

  Widget _stickerGrid(List<Attachment> stickers) {
    if (stickers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.emoji_emotions_outlined,
              size: 32,
              color: AppTheme.muted,
            ),
            const SizedBox(height: 10),
            Text(
              _query.trim().isEmpty ? '还没有表情包，点右上角 + 添加' : '没有找到相关表情',
              style: const TextStyle(fontSize: 10, color: AppTheme.muted),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 6 : 5;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: stickers.length,
          itemBuilder: (context, index) {
            final sticker = stickers[index];
            return _StickerTile(
              sticker: sticker,
              mediaUrl: widget.mediaUrl,
              managing: _managing,
              onTap: _managing ? null : () => widget.onSendSticker(sticker),
              onDelete: () => unawaited(widget.onDelete(sticker)),
            );
          },
        );
      },
    );
  }
}

class _StickerTile extends StatelessWidget {
  const _StickerTile({
    required this.sticker,
    required this.mediaUrl,
    required this.managing,
    required this.onTap,
    required this.onDelete,
  });

  final Attachment sticker;
  final String Function(String) mediaUrl;
  final bool managing;
  final VoidCallback? onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Material(
            color: AppTheme.panelAlt,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.network(
                    mediaUrl(sticker.url),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      size: 22,
                      color: AppTheme.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (managing)
          Positioned(
            right: 1,
            top: 1,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: AppTheme.error,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
