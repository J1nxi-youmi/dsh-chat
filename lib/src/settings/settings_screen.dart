import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_chat/src/core/api.dart';
import 'package:dsh_chat/src/core/theme.dart';
import 'package:dsh_chat/src/core/update.dart';
import '../shell/connect_screen.dart';
import 'desktop_settings_view.dart';
import 'mobile_settings_view.dart';
import 'profile_dialog.dart';
import 'version_screen.dart';

/// 设置页只负责状态和业务动作；桌面分栏/手机分组各自在独立视图里。
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
  int _section = 0;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    UpdateService.source().then((value) {
      if (mounted) setState(() => _source = value);
    });
  }

  Future<void> _showAppearance() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => const SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '界面外观',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.light_mode_rounded, color: AppTheme.accent),
              title: Text('浅色'),
              subtitle: Text('青屿当前使用的暖白主题'),
              trailing: Icon(Icons.check_rounded, color: AppTheme.accent),
            ),
            ListTile(
              enabled: false,
              leading: Icon(Icons.dark_mode_outlined),
              title: Text('深色'),
              subtitle: Text('主题系统适配中，暂不可用'),
            ),
            SizedBox(height: 10),
          ],
        ),
      ),
    );
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
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

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await widget.api.conversations();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连接正常，可以正常收发消息')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('连接失败：$error')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
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

  void _openProfile() {
    showDialog<void>(
      context: context,
      builder: (_) => ProfileDialog(api: widget.api),
    );
  }

  void _openVersion() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const VersionScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.panel,
        surfaceTintColor: Colors.transparent,
        title: const Text('设置'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppTheme.line),
        ),
      ),
      body: QingyuBackground(
        child: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 760
              ? DesktopSettingsView(
                  server: widget.server,
                  source: _source,
                  section: _section,
                  testing: _testing,
                  connected: widget.api.connected,
                  displayVersion: UpdateService.displayVersion,
                  onSectionChanged: (value) => setState(() => _section = value),
                  onEditSource: _editSource,
                  onTestConnection: _testConnection,
                  onSwitchServer: _switchServer,
                  onOpenProfile: _openProfile,
                  onOpenVersion: _openVersion,
                )
              : MobileSettingsView(
                  server: widget.server,
                  source: _source,
                  displayVersion: UpdateService.displayVersion,
                  onOpenProfile: _openProfile,
                  onEditSource: _editSource,
                  onOpenVersion: _openVersion,
                  onSwitchServer: _switchServer,
                  onOpenAppearance: _showAppearance,
                ),
        ),
      ),
    );
  }
}
