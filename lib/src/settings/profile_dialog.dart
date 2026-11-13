import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:dsh_chat/src/core/api.dart';
import 'package:dsh_chat/src/core/profile.dart';
import 'package:dsh_chat/src/core/theme.dart';

/// 「我的资料」：点头像换图、改昵称，只保存在这台设备上。
/// 桌面端从左上角头像打开；手机端在设置页打开。
class ProfileDialog extends StatefulWidget {
  const ProfileDialog({super.key, required this.api});

  final ChatApi api;

  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  late final TextEditingController _name = TextEditingController(
    text: AppProfile.instance.displayName,
  );
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onNameChanged);
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result.isEmpty ? null : result.first.path;
    if (path == null) return;
    await AppProfile.instance.setAvatarFromFile(path);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _reset() async {
    await AppProfile.instance.resetAvatar();
    if (!mounted) return;
    setState(() {});
  }

  /// 保存：本地生效 + 推到云端（头像传成附件拿 url），其它设备自动同步。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await AppProfile.instance.save(nickname: _name.text);
      final nickname = AppProfile.instance.displayName;
      var avatarUrl = '';
      final path = AppProfile.instance.avatarPath;
      if (path != null && File(path).existsSync()) {
        final bytes = await File(path).readAsBytes();
        final att = await widget.api.upload(
          name: 'avatar.png',
          mime: 'image/png',
          bytes: bytes,
          kind: 'file',
        );
        avatarUrl = att.url;
      }
      await widget.api.saveProfile(nickname: nickname, avatarUrl: avatarUrl);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存，其它设备连上后会自动同步')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已存到本机，云端同步失败：$error')));
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = AppProfile.instance.avatarImage;
    final display = _name.text.trim();
    final initial = display.isEmpty ? '我' : display.substring(0, 1);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        width: 430,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        decoration: BoxDecoration(
          color: AppTheme.panel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppTheme.line),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF25322E).withValues(alpha: 0.12),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PROFILE',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: AppTheme.accent,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '我的资料',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 19,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GestureDetector(
                      onTap: _pick,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(26),
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: image != null
                              ? Image(image: image, fit: BoxFit.cover)
                              : Container(
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFFF2B193),
                                        Color(0xFFCE756B),
                                      ],
                                    ),
                                  ),
                                  child: Text(
                                    initial,
                                    style: const TextStyle(
                                      fontSize: 27,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: GestureDetector(
                        onTap: _pick,
                        child: Container(
                          width: 27,
                          height: 27,
                          decoration: BoxDecoration(
                            color: AppTheme.accent,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppTheme.panel,
                              width: 2.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.camera_alt_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              const Center(
                child: Text(
                  '点击头像更换图片',
                  style: TextStyle(fontSize: 9, color: AppTheme.muted),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Text(
                    '我的昵称',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_name.text.characters.length} / 20',
                    style: const TextStyle(fontSize: 8, color: AppTheme.muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _name,
                maxLength: 20,
                style: const TextStyle(fontSize: 12, color: AppTheme.text),
                decoration: InputDecoration(
                  hintText: '填一个昵称',
                  counterText: '',
                  isDense: true,
                  fillColor: AppTheme.panelAlt,
                  filled: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  suffixIcon: display.isEmpty
                      ? null
                      : const Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: AppTheme.accent,
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.sync_rounded, size: 14, color: AppTheme.accent),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '昵称和头像会同步到你的 DSH，其它设备连接后自动保持一致。',
                        style: TextStyle(
                          fontSize: 8.5,
                          height: 1.5,
                          color: AppTheme.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : _reset,
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.muted,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('恢复默认头像', style: TextStyle(fontSize: 9)),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.text,
                      side: const BorderSide(color: AppTheme.line),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 10)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('保存资料', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
