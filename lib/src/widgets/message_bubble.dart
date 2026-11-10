import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';

final _linkPattern = RegExp('https?://[^\\s<>\'"]+');

/// 一条消息：文字（链接可点）、图片、语音、文件。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mediaUrl,
    this.status,
    this.onRetry,
  });

  final Message message;
  final String Function(String) mediaUrl;

  /// 还没被 ack 的消息：sending / failed。
  final String? status;

  /// failed 时点一下重发。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: mine ? null : AppTheme.panelAlt.withValues(alpha: 0.92),
          gradient: mine ? AppTheme.accentGradient : null,
          border: mine ? null : Border.all(color: AppTheme.line),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 5),
            bottomRight: Radius.circular(mine ? 5 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final attachment in message.attachments) ...[
              AttachmentView(attachment: attachment, mediaUrl: mediaUrl),
              const SizedBox(height: 6),
            ],
            if (message.text.isNotEmpty) _text(context),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('HH:mm').format(message.at),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.text.withValues(alpha: 0.55),
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
                        color: status == 'failed' ? AppTheme.error : AppTheme.text.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _text(BuildContext context) {
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in _linkPattern.allMatches(message.text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: message.text.substring(index, match.start)));
      }
      final link = match.group(0)!;
      spans.add(TextSpan(
        text: link,
        style: const TextStyle(
          color: Color(0xFF9ECBFF),
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
      ));
      index = match.end;
    }
    if (index < message.text.length) {
      spans.add(TextSpan(text: message.text.substring(index)));
    }
    return Text.rich(TextSpan(
      style: const TextStyle(color: AppTheme.text, fontSize: 15, height: 1.45),
      children: spans,
    ));
  }
}

/// 附件：图片直接显示，语音带播放键，文件是卡片。
class AttachmentView extends StatelessWidget {
  const AttachmentView({super.key, required this.attachment, required this.mediaUrl});

  final Attachment attachment;
  final String Function(String) mediaUrl;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage) {
      return ClipRRect(
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
              child: Text('图片加载失败', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
          ),
        ),
      );
    }
    if (attachment.isVoice) {
      return _VoiceTile(url: mediaUrl(attachment.url), seconds: attachment.duration);
    }
    return InkWell(
      onTap: () => launchUrl(Uri.parse(mediaUrl(attachment.url)),
          mode: LaunchMode.externalApplication),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5)),
                Text(attachment.sizeText,
                    style: const TextStyle(fontSize: 11, color: AppTheme.muted)),
              ],
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
      if (_player.duration == null || _player.processingState == ProcessingState.idle) {
        await _player.setUrl(widget.url);
      }
      await _player.play();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('语音播放失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.seconds > 0 ? '${widget.seconds.toStringAsFixed(0)}″' : '';
    return InkWell(
      onTap: _toggle,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
              size: 30),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
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
          color: AppTheme.panelAlt,
          borderRadius: BorderRadius.circular(16),
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
            Text('正在输入…', style: TextStyle(fontSize: 13, color: AppTheme.muted)),
          ],
        ),
      ),
    );
  }
}
