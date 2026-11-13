import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:dsh_chat/src/chat/chat_file_actions.dart';
import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/core/profile.dart';
import 'package:dsh_chat/src/core/theme.dart';

final _linkPattern = RegExp('https?://[^\\s<>\'"]+');

enum _MessageAction {
  copy,
  reply,
  share,
  delete,
  copyFile,
  saveAs,
  save,
  open,
  openFolder,
}

/// 一条消息：文字（链接可点）、图片、语音、文件。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mediaUrl,
    this.status,
    this.onRetry,
    this.highlighted = false,
    this.onReply,
    this.onShare,
    this.onDelete,
  });

  final Message message;
  final String Function(String) mediaUrl;

  /// 还没被 ack 的消息：sending / failed。
  final String? status;

  /// failed 时点一下重发。
  final VoidCallback? onRetry;

  /// 从搜索结果跳转过来时短暂高亮。
  final bool highlighted;

  final VoidCallback? onReply;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    final avatar = _Avatar(mine: mine);
    // 文件、图片、语音使用对称圆角卡片；纯文字才有朝向头像的小角。
    final hasCard = message.attachments.isNotEmpty;
    final radius = hasCard
        ? BorderRadius.circular(14)
        : mine
        ? const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(5),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (details) =>
          _showActions(context, details.globalPosition),
      onSecondaryTapDown: (details) =>
          _showActions(context, details.globalPosition),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) avatar,
          Flexible(
            child: Container(
              margin: EdgeInsets.only(
                bottom: 10,
                left: mine ? 0 : 6,
                right: mine ? 6 : 0,
              ),
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
              constraints: const BoxConstraints(maxWidth: 640),
              decoration: BoxDecoration(
                color: mine ? AppTheme.me : AppTheme.bubble,
                border: Border.all(
                  color: highlighted
                      ? AppTheme.accent
                      : mine
                      ? AppTheme.meBorder
                      : AppTheme.bubbleBorder,
                  width: highlighted ? 1.5 : 1,
                ),
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: highlighted
                        ? AppTheme.accent.withValues(alpha: 0.18)
                        : const Color(0xFF25322E).withValues(alpha: 0.035),
                    blurRadius: highlighted ? 14 : 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final attachment in message.attachments) ...[
                    AttachmentView(
                      attachment: attachment,
                      mediaUrl: mediaUrl,
                      sentAt: message.at,
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (message.text.isNotEmpty) _text(context),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat('HH:mm').format(message.at),
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.muted,
                        ),
                      ),
                      if (status != null) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: status == 'failed' ? onRetry : null,
                          child: Text(
                            status == 'failed' ? '发送失败，点这里重发' : '发送中…',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: status == 'failed'
                                  ? AppTheme.error
                                  : AppTheme.muted,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (mine) avatar,
        ],
      ),
    );
  }

  /// 长按/右键消息：桌面弹浮动菜单，手机弹底部面板。
  Future<void> _showActions(BuildContext context, Offset position) async {
    final text = message.text.trim();
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    Attachment? file;
    for (final attachment in message.attachments) {
      if (!attachment.isImage && !attachment.isVoice) {
        file = attachment;
        break;
      }
    }
    final entries = file != null
        ? <_MessageAction>[
            if (desktop) _MessageAction.copyFile,
            _MessageAction.saveAs,
            _MessageAction.save,
            _MessageAction.open,
            if (desktop) _MessageAction.openFolder,
            if (onDelete != null) _MessageAction.delete,
          ]
        : <_MessageAction>[
            if (text.isNotEmpty) _MessageAction.copy,
            if (onReply != null) _MessageAction.reply,
            if (onShare != null) _MessageAction.share,
            if (onDelete != null) _MessageAction.delete,
          ];
    if (entries.isEmpty) return;

    final action = desktop
        ? await _showDesktopMenu(context, position, entries)
        : await _showMobileMenu(context, entries);
    if (action == null || !context.mounted) return;

    switch (action) {
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制')));
        break;
      case _MessageAction.reply:
        onReply?.call();
        break;
      case _MessageAction.share:
        onShare?.call();
        break;
      case _MessageAction.delete:
        onDelete?.call();
        break;
      case _MessageAction.copyFile:
      case _MessageAction.saveAs:
      case _MessageAction.save:
      case _MessageAction.open:
      case _MessageAction.openFolder:
        await _runFileAction(context, file!, action);
        break;
    }
  }

  Future<void> _runFileAction(
    BuildContext context,
    Attachment file,
    _MessageAction action,
  ) async {
    final url = mediaUrl(file.url);
    try {
      final result = switch (action) {
        _MessageAction.copyFile => await ChatFileActions.copy(url, file),
        _MessageAction.saveAs => await ChatFileActions.saveAs(url, file),
        _MessageAction.save => await ChatFileActions.save(url, file),
        _MessageAction.open => await ChatFileActions.open(url, file),
        _MessageAction.openFolder => await ChatFileActions.openFolder(
          url,
          file,
        ),
        _ => '不支持的操作',
      };
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
    }
  }

  Future<_MessageAction?> _showDesktopMenu(
    BuildContext context,
    Offset globalPosition,
    List<_MessageAction> entries,
  ) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return Future.value();
    final local = overlay.globalToLocal(globalPosition);
    final position = RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    );
    return showMenu<_MessageAction>(
      context: context,
      position: position,
      color: AppTheme.panel,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.line),
      ),
      items: [
        for (final action in entries)
          PopupMenuItem<_MessageAction>(
            value: action,
            height: 40,
            child: _menuRow(action),
          ),
      ],
    );
  }

  Future<_MessageAction?> _showMobileMenu(
    BuildContext context,
    List<_MessageAction> entries,
  ) {
    return showModalBottomSheet<_MessageAction>(
      context: context,
      backgroundColor: AppTheme.panel,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in entries)
              ListTile(
                leading: Icon(
                  _actionIcon(action),
                  color: action == _MessageAction.delete
                      ? AppTheme.error
                      : AppTheme.accent,
                  size: 20,
                ),
                title: Text(
                  _actionLabel(action),
                  style: TextStyle(
                    fontSize: 13,
                    color: action == _MessageAction.delete
                        ? AppTheme.error
                        : AppTheme.text,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop(action),
              ),
          ],
        ),
      ),
    );
  }

  Widget _menuRow(_MessageAction action) {
    final color = action == _MessageAction.delete
        ? AppTheme.error
        : AppTheme.text;
    return Row(
      children: [
        Icon(_actionIcon(action), size: 16, color: color),
        const SizedBox(width: 10),
        Text(
          _actionLabel(action),
          style: TextStyle(fontSize: 12, color: color),
        ),
      ],
    );
  }

  IconData _actionIcon(_MessageAction action) {
    return switch (action) {
      _MessageAction.copy => Icons.content_copy_rounded,
      _MessageAction.reply => Icons.reply_rounded,
      _MessageAction.share => Icons.share_rounded,
      _MessageAction.delete => Icons.delete_outline_rounded,
      _MessageAction.copyFile => Icons.content_copy_rounded,
      _MessageAction.saveAs => Icons.save_as_outlined,
      _MessageAction.save => Icons.download_rounded,
      _MessageAction.open => Icons.open_in_new_rounded,
      _MessageAction.openFolder => Icons.folder_open_rounded,
    };
  }

  String _actionLabel(_MessageAction action) {
    return switch (action) {
      _MessageAction.copy => '复制文字',
      _MessageAction.reply => '引用回复',
      _MessageAction.share => '分享到群',
      _MessageAction.delete => '删除本地显示',
      _MessageAction.copyFile => '复制',
      _MessageAction.saveAs => '另存为',
      _MessageAction.save => '保存',
      _MessageAction.open => '打开',
      _MessageAction.openFolder => '打开文件夹',
    };
  }

  Widget _text(BuildContext context) {
    final quote = RegExp(r'^> ([^\n]+)\n\n').firstMatch(message.text);
    if (quote == null) return _richText(message.text);
    final rest = message.text.substring(quote.end);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.accent, width: 2)),
          ),
          child: Text(
            quote.group(1)!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppTheme.muted),
          ),
        ),
        if (rest.isNotEmpty) const SizedBox(height: 6),
        if (rest.isNotEmpty) _richText(rest),
      ],
    );
  }

  Widget _richText(String text) {
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in _linkPattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      final link = match.group(0)!;
      spans.add(
        TextSpan(
          text: link,
          style: const TextStyle(
            color: AppTheme.accent,
            decoration: TextDecoration.underline,
            decorationColor: AppTheme.accent2,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => launchUrl(
              Uri.parse(link),
              mode: LaunchMode.externalApplication,
            ),
        ),
      );
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index)));
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: AppTheme.text,
          fontSize: 15,
          height: 1.45,
        ),
        children: spans,
      ),
    );
  }
}

/// 附件：图片直接显示，语音带播放键，文件是卡片。
class AttachmentView extends StatelessWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    required this.mediaUrl,
    this.sentAt,
  });

  final Attachment attachment;
  final String Function(String) mediaUrl;
  final DateTime? sentAt;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage) {
      return GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          barrierColor: Colors.black87,
          builder: (_) =>
              ImageViewerDialog(url: mediaUrl(attachment.url), time: sentAt),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            mediaUrl(attachment.url),
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            },
            errorBuilder: (_, __, ___) => const SizedBox(
              height: 80,
              child: Center(
                child: Text(
                  '图片加载失败',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (attachment.isVoice) {
      return _VoiceTile(
        url: mediaUrl(attachment.url),
        seconds: attachment.duration,
      );
    }
    return InkWell(
      onTap: () => launchUrl(
        Uri.parse(mediaUrl(attachment.url)),
        mode: LaunchMode.externalApplication,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.insert_drive_file_outlined,
            size: 20,
            color: AppTheme.accent,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
                Text(
                  attachment.sizeText,
                  style: const TextStyle(fontSize: 11, color: AppTheme.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 图片全屏预览：顶部返回/关闭，底部时间和保存。
class ImageViewerDialog extends StatefulWidget {
  const ImageViewerDialog({
    super.key,
    this.url,
    this.bytes,
    this.time,
    this.title = '图片预览',
  }) : assert(url != null || bytes != null);

  final String? url;
  final Uint8List? bytes;
  final DateTime? time;
  final String title;

  @override
  State<ImageViewerDialog> createState() => ImageViewerDialogState();
}

class ImageViewerDialogState extends State<ImageViewerDialog> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      Uint8List data;
      var ext = 'png';
      if (widget.bytes != null) {
        data = widget.bytes!;
      } else {
        final response = await http.get(Uri.parse(widget.url!));
        if (response.statusCode != 200) {
          throw 'HTTP ${response.statusCode}';
        }
        data = response.bodyBytes;
        final mime = response.headers['content-type']?.split(';').first.trim();
        ext = switch (mime) {
          'image/jpeg' => 'jpg',
          'image/gif' => 'gif',
          'image/webp' => 'webp',
          _ => 'png',
        };
      }
      Directory? dir;
      if (Platform.isAndroid || Platform.isIOS) {
        dir = await getApplicationDocumentsDirectory();
      } else {
        dir = await getDownloadsDirectory();
      }
      dir ??= await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/qingyu-${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await file.writeAsBytes(data, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('图片已保存到 ${file.path}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = widget.time;
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: Center(
              child: widget.bytes != null
                  ? Image.memory(widget.bytes!, fit: BoxFit.contain)
                  : Image.network(
                      widget.url!,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                          ? child
                          : const Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            ),
                      errorBuilder: (_, __, ___) => const Center(
                        child: Text(
                          '图片加载失败',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(
                    children: [
                      if (time != null)
                        Text(
                          DateFormat('MM月dd日 HH:mm').format(time),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white70,
                                ),
                              )
                            : const Icon(
                                Icons.download_rounded,
                                size: 17,
                                color: Colors.white,
                              ),
                        label: Text(
                          _saving ? '保存中…' : '保存图片',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceTile extends StatefulWidget {
  const _VoiceTile({required this.url, required this.seconds});

  final String url;
  final double seconds;

  @override
  State<_VoiceTile> createState() => _VoiceTileState();
}

class _VoiceTileState extends State<_VoiceTile> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state.playing);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    try {
      if (_player.duration == null ||
          _player.processingState == ProcessingState.idle) {
        await _player.setUrl(widget.url);
      }
      await _player.play();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('语音播放失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.seconds > 0
        ? '${widget.seconds.toStringAsFixed(0)}″'
        : '';
    return InkWell(
      onTap: _toggle,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _playing
                ? Icons.pause_circle_filled_rounded
                : Icons.play_circle_fill_rounded,
            size: 30,
            color: AppTheme.accent,
          ),
          const SizedBox(width: 8),
          _Waveform(playing: _playing),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }
}

/// 语音条上的静态波形，播放时颜色加深。
class _Waveform extends StatelessWidget {
  const _Waveform({required this.playing});

  final bool playing;

  static const _heights = [
    5.0,
    9.0,
    14.0,
    8.0,
    17.0,
    21.0,
    11.0,
    16.0,
    7.0,
    13.0,
    20.0,
    15.0,
  ];

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.accent.withValues(alpha: playing ? 0.95 : 0.45);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final height in _heights)
          Container(
            width: 2,
            height: height,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}

/// 「正在输入…」占位。
class TypingRow extends StatelessWidget {
  const TypingRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.bubble,
          border: Border.all(color: AppTheme.bubbleBorder),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text(
              '正在输入…',
              style: TextStyle(fontSize: 13, color: AppTheme.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 消息旁的小头像：对方是会话形象，自己用「我的资料」里的头像。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.mine});

  final bool mine;

  @override
  Widget build(BuildContext context) {
    final face = mine
        ? UserAvatar(
            name: AppProfile.instance.displayName,
            size: 30,
            image: AppProfile.instance.avatarImage,
          )
        : const AvatarBadge(name: '', size: 30);

    return Padding(padding: const EdgeInsets.only(top: 2), child: face);
  }
}
