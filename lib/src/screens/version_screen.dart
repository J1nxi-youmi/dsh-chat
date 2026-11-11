import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../update.dart';

/// 版本详情页：只有打开这一页才会去查更新，发现新版本才弹窗。
class VersionScreen extends StatefulWidget {
  const VersionScreen({super.key});

  @override
  State<VersionScreen> createState() => _VersionScreenState();
}

class _VersionScreenState extends State<VersionScreen> {
  late Future<UpdateInfo> _future = UpdateService.fetchLatest();
  bool _prompted = false;

  void _reload() {
    setState(() {
      _prompted = false;
      _future = UpdateService.fetchLatest();
    });
  }

  void _maybePrompt(UpdateInfo info) {
    if (_prompted) return;
    if (info.buildNumber <= UpdateService.appBuild) return;
    _prompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.panel,
          title: Text('发现新版本 ${info.versionLabel}'),
          content: Text(
            '当前 ${UpdateService.displayVersion}，最新 ${info.versionLabel}。\n\n'
            '${info.body.split('\n').take(8).join('\n')}',
            style: const TextStyle(height: 1.5, fontSize: 13),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('稍后')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('去更新')),
          ],
        ),
      );
      if (go == true) await _download(info);
    });
  }

  Future<void> _download(UpdateInfo info) async {
    try {
      final message = await UpdateService.install(info);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('版本'),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: StarryBackground(
        child: FutureBuilder<UpdateInfo>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${snapshot.error}', textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTheme.error)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _reload, child: const Text('重试')),
                    ],
                  ),
                ),
              );
            }
            final info = snapshot.data!;
            _maybePrompt(info);
            final hasNew = info.buildNumber > UpdateService.appBuild;
            return ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const Text('当前版本', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  UpdateService.displayVersion,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 18),
                const Text('最新版本', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  info.versionLabel,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: hasNew ? AppTheme.gold : AppTheme.text,
                  ),
                ),
                if (hasNew) ...[
                  const SizedBox(height: 6),
                  const Text('有新版本可以更新', style: TextStyle(fontSize: 12, color: AppTheme.gold)),
                ],
                const SizedBox(height: 18),
                const Text('更新说明', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                const SizedBox(height: 6),
                SelectableText(
                  info.body.trim().isEmpty ? '（这个 release 没有写说明）' : info.body.trim(),
                  style: const TextStyle(fontSize: 13, height: 1.6),
                ),
                const SizedBox(height: 22),
                if (hasNew)
                  FilledButton(
                    onPressed: () => _download(info),
                    child: Text('下载并安装 ${info.versionLabel}'),
                  ),
                const SizedBox(height: 8),
                if (info.pageUrl != null)
                  OutlinedButton(
                    onPressed: () => launchUrl(Uri.parse(info.pageUrl!),
                        mode: LaunchMode.externalApplication),
                    child: const Text('打开 Release 页'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
