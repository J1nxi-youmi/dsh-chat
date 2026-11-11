import 'dart:io';

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
            '${_pretty(info.body).split('\n').take(6).join('\n')}',
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

  /// 把 release 正文里最扎眼的 markdown 标记去掉，读起来像正文。
  String _pretty(String body) {
    var text = body;
    // 「下载 / 校验 / CHANGELOG 链接」是给 GitHub 页面看的，App 里不需要。
    final cut = text.indexOf(RegExp(r'\n#{1,6}\s*(下载|校验)'));
    if (cut > 0) text = text.substring(0, cut);
    text = text.replaceAll(RegExp(r'^.*每个版本的改动见.*$', multiLine: true), '');
    text = text.replaceAll(RegExp(r'```[a-zA-Z]*'), '');
    text = text.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    text = text.replaceAll('**', '');
    text = text.replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '· ');
    return text.trim();
  }

  Future<void> _download(UpdateInfo info) async {
    final isWindowsInstaller =
        Platform.isWindows && (info.setupUrl ?? '').toLowerCase().endsWith('.exe');
    if (!isWindowsInstaller) {
      try {
        final message = await UpdateService.install(info);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      }
      return;
    }

    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: Text('正在下载 ${info.versionLabel}'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value == 0 ? null : value),
              const SizedBox(height: 10),
              Text(
                value == 0 ? '连接下载地址…' : '已下载 ${(value * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12, color: AppTheme.muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已取消，可点「打开 Release 页」手动下载')),
                );
              }
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    try {
      final message = await UpdateService.install(info, onProgress: (value) {
        progress.value = value;
      });
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('下载失败：$error'),
          action: info.pageUrl == null
              ? null
              : SnackBarAction(
                  label: '打开下载页',
                  onPressed: () => launchUrl(Uri.parse(info.pageUrl!),
                      mode: LaunchMode.externalApplication),
                ),
        ),
      );
    } finally {
      progress.dispose();
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
                  info.body.trim().isEmpty ? '（这个 release 没有写说明）' : _pretty(info.body),
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
