import 'package:flutter/material.dart';

import 'package:dsh_chat/src/core/profile.dart';
import 'package:dsh_chat/src/core/theme.dart';
import 'settings_widgets.dart';

class MobileSettingsView extends StatelessWidget {
  const MobileSettingsView({
    super.key,
    required this.server,
    required this.source,
    required this.displayVersion,
    required this.onOpenProfile,
    required this.onEditSource,
    required this.onOpenVersion,
    required this.onSwitchServer,
    required this.onOpenAppearance,
  });

  final String server;
  final String source;
  final String displayVersion;
  final VoidCallback onOpenProfile;
  final VoidCallback onEditSource;
  final VoidCallback onOpenVersion;
  final VoidCallback onSwitchServer;
  final VoidCallback onOpenAppearance;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            AnimatedBuilder(
              animation: AppProfile.instance,
              builder: (context, _) => SettingsCard(
                children: [
                  InkWell(
                    onTap: onOpenProfile,
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
                ],
              ),
            ),
            const SettingsSectionLabel('连接与应用'),
            SettingsCard(
              children: [
                SettingsRow(
                  icon: Icons.dns_rounded,
                  title: '服务器',
                  subtitle: server,
                ),
                const SettingsRowDivider(),
                SettingsRow(
                  icon: Icons.link_rounded,
                  title: '更新源',
                  subtitle: source,
                  onTap: onEditSource,
                ),
                const SettingsRowDivider(),
                SettingsRow(
                  icon: Icons.info_outline_rounded,
                  title: '版本与更新',
                  subtitle: displayVersion,
                  onTap: onOpenVersion,
                ),
              ],
            ),
            const SettingsSectionLabel('其他'),
            SettingsCard(
              children: [
                SettingsRow(
                  icon: Icons.palette_outlined,
                  title: '界面外观',
                  subtitle: '跟随系统 · 浅色',
                  onTap: onOpenAppearance,
                ),
                const SettingsRowDivider(),
                SettingsRow(
                  icon: Icons.swap_horiz_rounded,
                  title: '换一台 DSH',
                  subtitle: '清掉当前地址和令牌，回到连接页',
                  onTap: onSwitchServer,
                  danger: true,
                ),
              ],
            ),
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
}
