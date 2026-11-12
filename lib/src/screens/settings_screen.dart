import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../update.dart';
import 'connect_screen.dart';
import '../api.dart';
import 'profile_dialog.dart';
import 'version_screen.dart';

/// 设置页：服务器、版本（点进去才有更新弹窗）、更新源、换一台 DSH。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.server,
    required this.token,
    required this.api,
  });

  final String server;
  final String token;
  final ChatApi api;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _source = UpdateService.defaultSource;

  @override
  void initState() {
    super.initState();
    UpdateService.source().then((value) {
      if (mounted) setState(() => _source = value);
    });
  }

  Future<void> _editSource() async {
    final controller = TextEditingController(text: _source);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: const Text('更新源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://github.com/J1nxi-youmi/dsh-chat',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await UpdateService.setSource(value);
    if (!mounted) return;
    setState(() => _source = value);
  }

  Future<void> _switchServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server');
    await prefs.remove('token');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ConnectScreen(
          initialServer: widget.server,
          initialToken: widget.token,
        ),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: StarryBackground(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            ListTile(
              leading: const Icon(Icons.dns_rounded, color: AppTheme.muted),
              title: const Text('服务器'),
              subtitle: Text(widget.server, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.person_rounded, color: AppTheme.muted),
              title: const Text('我的资料'),
              subtitle: const Text('会同步到你的 DSH，所有设备保持一致'),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => ProfileDialog(api: widget.api),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded, color: AppTheme.muted),
              title: const Text('版本'),
              subtitle: Text(UpdateService.displayVersion),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VersionScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, color: AppTheme.muted),
              title: const Text('更新源'),
              subtitle: Text(_source, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: _editSource,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.swap_horiz_rounded, color: AppTheme.muted),
              title: const Text('换一台 DSH'),
              subtitle: const Text('清掉当前地址和令牌，回到连接页'),
              onTap: _switchServer,
            ),
          ],
        ),
      ),
    );
  }
}
