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
      body: StarryBackground(
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
                  'Dshchat for Windows · v0.3.0',
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
                          'Dshchat',
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
          OutlinedButton.icon(
            onPressed: _switchServer,
            icon: const Icon(Icons.swap_horiz_rounded, size: 17),
            label: const Text('换一台 DSH'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.error,
              side: const BorderSide(color: AppTheme.line),
            ),
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
                ListTile(
                  leading: UserAvatar(
                    name: AppProfile.instance.displayName,
                    size: 42,
                    image: AppProfile.instance.avatarImage,
                  ),
                  title: Text(AppProfile.instance.displayName),
                  subtitle: const Text('编辑昵称与头像 · 云端同步'),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.muted,
                  ),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => ProfileDialog(api: widget.api),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            _settingsCard([
              ListTile(
                leading: const Icon(Icons.dns_rounded, color: AppTheme.accent),
                title: const Text('服务器'),
                subtitle: Text(
                  widget.server,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.info_outline_rounded,
                  color: AppTheme.accent,
                ),
                title: const Text('版本'),
                subtitle: Text(UpdateService.displayVersion),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.muted,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VersionScreen()),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _settingsCard([
              ListTile(
                leading: const Icon(Icons.link_rounded, color: AppTheme.accent),
                title: const Text('更新源'),
                subtitle: Text(
                  _source,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.muted,
                ),
                onTap: _editSource,
              ),
            ]),
            const SizedBox(height: 12),
            _settingsCard([
              ListTile(
                leading: const Icon(
                  Icons.swap_horiz_rounded,
                  color: AppTheme.error,
                ),
                title: const Text('换一台 DSH'),
                subtitle: const Text('清掉当前地址和令牌，回到连接页'),
                onTap: _switchServer,
              ),
            ]),
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
