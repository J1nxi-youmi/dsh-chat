import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'message_bubble.dart';

/// 一条待发送附件：本地预览（bytes）+ 后台上传出来的 attachment。
class PendingAttachment {
  PendingAttachment({
    required this.name,
    required this.bytes,
    required this.isImage,
    required this.isVoice,
  });

  final String name;
  final Uint8List? bytes;
  final bool isImage;
  final bool isVoice;
  Attachment? attachment;

  bool get ready => attachment != null;
}

class PendingAttachmentTile extends StatelessWidget {
  const PendingAttachmentTile({
    super.key,
    required this.item,
    required this.onRemove,
  });

  final PendingAttachment item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (item.isImage) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: item.bytes == null
                ? null
                : () => showDialog<void>(
                    context: context,
                    barrierColor: Colors.black87,
                    builder: (_) =>
                        ImageViewerDialog(bytes: item.bytes, title: '待发送图片'),
                  ),
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppTheme.panelAlt,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: AppTheme.line),
                image: item.bytes == null
                    ? null
                    : DecorationImage(
                        image: Image.memory(
                          item.bytes!,
                          fit: BoxFit.cover,
                        ).image,
                        fit: BoxFit.cover,
                      ),
              ),
              child: !item.ready
                  ? Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          Positioned(
            right: -5,
            top: -5,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppTheme.error,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final size = item.ready
        ? item.attachment!.sizeText
        : '${((item.bytes?.length ?? 0) / 1024).round().clamp(1, 9999)} KB';
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(8, 8, 7, 8),
      decoration: BoxDecoration(
        color: AppTheme.panelAlt,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              item.isVoice
                  ? Icons.mic_none_rounded
                  : Icons.insert_drive_file_outlined,
              size: 17,
              color: AppTheme.accent,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.isVoice ? '语音' : item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  item.ready ? size : '上传中… · $size',
                  style: const TextStyle(fontSize: 8, color: AppTheme.muted),
                ),
                if (!item.ready)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: const LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: AppTheme.line,
                        color: AppTheme.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(
              Icons.close_rounded,
              size: 15,
              color: AppTheme.muted,
            ),
          ),
        ],
      ),
    );
  }
}
