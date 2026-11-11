import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../profile.dart';
import '../theme.dart';

/// 「我的资料」：点头像换图、改昵称，只保存在这台设备上。
/// 桌面端从左上角头像打开；手机端在设置页打开。
class ProfileDialog extends StatefulWidget {
  const ProfileDialog({super.key});

  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  late final TextEditingController _name =
      TextEditingController(text: AppProfile.instance.nickname);
  ImageProvider? _image;

  @override
  void initState() {
    super.initState();
    final path = AppProfile.instance.avatarPath;
    if (path != null && File(path).existsSync()) _image = FileImage(File(path));
  }

  Future<void> _pick() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result.isEmpty ? null : result.first.path;
    if (path == null) return;
    await AppProfile.instance.setAvatarFromFile(path);
    if (!mounted) return;
    setState(() => _image = FileImage(File(AppProfile.instance.avatarPath!)));
  }

  Future<void> _reset() async {
    await AppProfile.instance.resetAvatar();
    if (!mounted) return;
    setState(() => _image = null);
  }

  Future<void> _save() async {
    await AppProfile.instance.save(nickname: _name.text);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      title: const Text('我的资料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: GestureDetector(
              onTap: _pick,
              child: AvatarBadge(name: _name.text, size: 88, image: _image),
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
          const Text('我的昵称', style: TextStyle(fontSize: 12, color: AppTheme.muted)),
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
            '昵称和头像会保存在这台设备上，换设备需要重新设置。',
            style: TextStyle(fontSize: 11, color: AppTheme.muted),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _reset, child: const Text('恢复默认头像')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存资料')),
      ],
    );
  }
}
