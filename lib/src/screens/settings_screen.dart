import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../update.dart';
import 'connect_screen.dart';
import '../api.dart';
import '../profile.dart';
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
          builder: (context, constraints) =>
              constraints.maxWidth >= 760 ? _wideBody() : _narrowBody(),
        ),
      ),
    );
  }

  Widget _wideBody() {
    return Row(
      children: [
        Container(
          width: 218,
          decoration: const BoxDecoration(
            color: AppTheme.panelAlt,
            border: Border(right: BorderSide(color: AppTheme.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DSHCHAT',
                      style: TextStyle(
                        fontSize: 8,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.muted,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '设置',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.text,
                      ),
                    ),
                  ],
                ),
              ),
              _navItem(Icons.dns_rounded, '服务器与连接', 0),
              _navItem(Icons.person_rounded, '我的资料', 1),
              _navItem(Icons.info_outline_rounded, '版本与更新', 2),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Divider(height: 1, color: AppTheme.line),
              ),
              _navItem(
                Icons.swap_horiz_rounded,
                '换一台 DSH',
                -1,
                danger: true,
                onTap: _switchServer,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 14),
                child: Text(
                  '青屿 for Windows · v0.3.0',
                  style: TextStyle(fontSize: 8, color: AppTheme.muted),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: AppTheme.panel,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(30, 26, 30, 24),
              children: _sectionWidgets(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _navItem(
    IconData icon,
    String label,
    int index, {
    bool danger = false,
    VoidCallback? onTap,
  }) {
    final active = index >= 0 && _section == index;
    final color = active
        ? AppTheme.accent
        : danger
        ? AppTheme.error
        : AppTheme.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: active
            ? AppTheme.accent.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap ?? () => setState(() => _section = index),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _sectionWidgets() {
    switch (_section) {
      case 1:
        return [
          _sectionTitle('我的资料', '昵称和头像会同步到你的 DSH'),
          const SizedBox(height: 20),
          _profileCard(),
        ];
      case 2:
        return [
          _sectionTitle('版本与更新', '只在这里检查更新'),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.panelAlt,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppTheme.accent,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Icon(
                        Icons.chat_bubble_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '青屿',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '当前 ${UpdateService.displayVersion}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VersionScreen()),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('查看版本与更新'),
                ),
              ],
            ),
          ),
        ];
      default:
        return [
          _sectionTitle('服务器与连接', '管理当前 DSH 服务与应用更新源'),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: widget.api.connected,
            builder: (context, connected, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: connected
                    ? const Color(0xFF3DAE7E).withValues(alpha: 0.08)
                    : AppTheme.panelAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: connected
                      ? const Color(0xFF3DAE7E).withValues(alpha: 0.25)
                      : AppTheme.line,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    connected
                        ? Icons.check_circle_rounded
                        : Icons.cloud_off_rounded,
                    size: 20,
                    color: connected ? const Color(0xFF3DAE7E) : AppTheme.muted,
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connected ? '已连接到 DSH' : '连接中…',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        connected ? '消息同步与实时事件均正常' : '正在等待服务器响应',
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppTheme.muted,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    connected ? '● 在线' : '…',
                    style: TextStyle(
                      fontSize: 9,
                      color: connected
                          ? const Color(0xFF3DAE7E)
                          : AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          _infoField('服务器地址', widget.server, Icons.dns_rounded),
          const SizedBox(height: 14),
          _infoField('访问令牌', '••••••••••••••••••••', Icons.shield_rounded),
          const SizedBox(height: 14),
          _infoField('更新源', _source, Icons.link_rounded, onTap: _editSource),
          const SizedBox(height: 22),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 17),
                label: Text(_testing ? '测试中…' : '测试连接'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  side: const BorderSide(color: AppTheme.line),
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _switchServer,
                icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                label: const Text('换一台 DSH'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.error,
                  side: const BorderSide(color: AppTheme.line),
                ),
              ),
            ],
          ),
        ];
    }
  }

  Widget _sectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w700,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 10, color: AppTheme.muted),
        ),
      ],
    );
  }

  Widget _infoField(
    String label,
    String value,
    IconData icon, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppTheme.text,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.panelAlt,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppTheme.line),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: AppTheme.muted),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppTheme.text),
                  ),
                ),
                if (onTap != null)
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: AppTheme.muted,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileCard() {
    return AnimatedBuilder(
      animation: AppProfile.instance,
      builder: (context, _) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppTheme.panelAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.line),
        ),
        child: Column(
          children: [
            UserAvatar(
              name: AppProfile.instance.displayName,
              image: AppProfile.instance.avatarImage,
              size: 88,
            ),
            const SizedBox(height: 14),
            Text(
              AppProfile.instance.displayName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            const Text(
              '头像与昵称会同步到其他设备',
              style: TextStyle(fontSize: 10, color: AppTheme.muted),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ProfileDialog(api: widget.api),
              ),
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: const Text('编辑资料'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _narrowBody() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            AnimatedBuilder(
              animation: AppProfile.instance,
              builder: (context, _) => _settingsCard([
                InkWell(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => ProfileDialog(api: widget.api),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        UserAvatar(
                          name: AppProfile.instance.displayName,
                          size: 44,
                          image: AppProfile.instance.avatarImage,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppProfile.instance.displayName,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                '编辑昵称与头像 · 云端同步',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: AppTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: AppTheme.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ]),
            ),
            _sectionLabel('连接与应用'),
            _settingsCard([
              _settingRow(
                icon: Icons.dns_rounded,
                title: '服务器',
                subtitle: widget.server,
              ),
              _rowDivider(),
              _settingRow(
                icon: Icons.link_rounded,
                title: '更新源',
                subtitle: _source,
                onTap: _editSource,
              ),
              _rowDivider(),
              _settingRow(
                icon: Icons.info_outline_rounded,
                title: '版本与更新',
                subtitle: UpdateService.displayVersion,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VersionScreen()),
                ),
              ),
            ]),
            _sectionLabel('其他'),
            _settingsCard([
              _settingRow(
                icon: Icons.palette_outlined,
                title: '界面外观',
                subtitle: '跟随系统 · 浅色',
                onTap: _showAppearance,
              ),
              _rowDivider(),
              _settingRow(
                icon: Icons.swap_horiz_rounded,
                title: '换一台 DSH',
                subtitle: '清掉当前地址和令牌，回到连接页',
                onTap: _switchServer,
                danger: true,
              ),
            ]),
            const SizedBox(height: 20),
            const Center(
              child: Text(
                '青屿 · 连接你的每一台设备',
                style: TextStyle(fontSize: 8, color: AppTheme.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 7),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: AppTheme.muted,
        ),
      ),
    );
  }

  Widget _rowDivider() {
    return const Divider(height: 1, indent: 56, color: AppTheme.line);
  }

  Widget _settingRow({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    bool danger = false,
  }) {
    final color = danger ? AppTheme.error : AppTheme.accent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 8.5,
                      height: 1.35,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 15,
                  color: AppTheme.muted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}
