import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../profile.dart';
import '../theme.dart';

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
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.line),
      ),
      title: const Text('我的资料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: GestureDetector(
              onTap: _pick,
              child: AvatarBadge(
                name: _name.text,
                size: 88,
                image: AppProfile.instance.avatarImage,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text(
              '点头像换一张图片',
              style: TextStyle(fontSize: 11, color: AppTheme.muted),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '我的昵称',
            style: TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '昵称和头像会同步到你的 DSH，所有设备自动保持一致。',
            style: TextStyle(fontSize: 11, color: AppTheme.muted),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _reset, child: const Text('恢复默认头像')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存资料')),
      ],
    );
  }
}
