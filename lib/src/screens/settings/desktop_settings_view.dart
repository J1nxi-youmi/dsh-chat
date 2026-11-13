import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../profile.dart';
import '../../theme.dart';
import 'settings_widgets.dart';

class DesktopSettingsView extends StatelessWidget {
  const DesktopSettingsView({
    super.key,
    required this.server,
    required this.source,
    required this.section,
    required this.testing,
    required this.connected,
    required this.displayVersion,
    required this.onSectionChanged,
    required this.onEditSource,
    required this.onTestConnection,
    required this.onSwitchServer,
    required this.onOpenProfile,
    required this.onOpenVersion,
  });

  final String server;
  final String source;
  final int section;
  final bool testing;
  final ValueListenable<bool> connected;
  final String displayVersion;
  final ValueChanged<int> onSectionChanged;
  final VoidCallback onEditSource;
  final VoidCallback onTestConnection;
  final VoidCallback onSwitchServer;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenVersion;

  @override
  Widget build(BuildContext context) {
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
              SettingsNavItem(
                icon: Icons.dns_rounded,
                label: '服务器与连接',
                active: section == 0,
                onTap: () => onSectionChanged(0),
              ),
              SettingsNavItem(
                icon: Icons.person_rounded,
                label: '我的资料',
                active: section == 1,
                onTap: () => onSectionChanged(1),
              ),
              SettingsNavItem(
                icon: Icons.info_outline_rounded,
                label: '版本与更新',
                active: section == 2,
                onTap: () => onSectionChanged(2),
              ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Divider(height: 1, color: AppTheme.line),
              ),
              SettingsNavItem(
                icon: Icons.swap_horiz_rounded,
                label: '换一台 DSH',
                active: false,
                danger: true,
                onTap: onSwitchServer,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                child: Text(
                  '青屿 for Windows · $displayVersion',
                  style: const TextStyle(fontSize: 8, color: AppTheme.muted),
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
              children: _sectionWidgets(context),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _sectionWidgets(BuildContext context) {
    switch (section) {
      case 1:
        return [
          const SettingsSectionTitle(
            title: '我的资料',
            subtitle: '昵称和头像会同步到你的 DSH',
          ),
          const SizedBox(height: 20),
          _profileCard(context),
        ];
      case 2:
        return [
          const SettingsSectionTitle(title: '版本与更新', subtitle: '只在这里检查更新'),
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
                          '当前 $displayVersion',
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
                  onPressed: onOpenVersion,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('查看版本与更新'),
                ),
              ],
            ),
          ),
        ];
      default:
        return [
          const SettingsSectionTitle(
            title: '服务器与连接',
            subtitle: '管理当前 DSH 服务与应用更新源',
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: connected,
            builder: (context, isConnected, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: isConnected
                    ? const Color(0xFF3DAE7E).withValues(alpha: 0.08)
                    : AppTheme.panelAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isConnected
                      ? const Color(0xFF3DAE7E).withValues(alpha: 0.25)
                      : AppTheme.line,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isConnected
                        ? Icons.check_circle_rounded
                        : Icons.cloud_off_rounded,
                    size: 20,
                    color: isConnected
                        ? const Color(0xFF3DAE7E)
                        : AppTheme.muted,
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConnected ? '已连接到 DSH' : '连接中…',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isConnected ? '消息同步与实时事件均正常' : '正在等待服务器响应',
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppTheme.muted,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    isConnected ? '● 在线' : '…',
                    style: TextStyle(
                      fontSize: 9,
                      color: isConnected
                          ? const Color(0xFF3DAE7E)
                          : AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          SettingsInfoField(
            label: '服务器地址',
            value: server,
            icon: Icons.dns_rounded,
          ),
          const SizedBox(height: 14),
          const SettingsInfoField(
            label: '访问令牌',
            value: '••••••••••••••••••••',
            icon: Icons.shield_rounded,
          ),
          const SizedBox(height: 14),
          SettingsInfoField(
            label: '更新源',
            value: source,
            icon: Icons.link_rounded,
            onTap: onEditSource,
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: testing ? null : onTestConnection,
                icon: testing
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 17),
                label: Text(testing ? '测试中…' : '测试连接'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  side: const BorderSide(color: AppTheme.line),
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: onSwitchServer,
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

  Widget _profileCard(BuildContext context) {
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
              onPressed: onOpenProfile,
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: const Text('编辑资料'),
            ),
          ],
        ),
      ),
    );
  }
}
