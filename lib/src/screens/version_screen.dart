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
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('去更新'),
            ),
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
    final inAppDownload =
        (info.setupUrl ?? '').toLowerCase().endsWith('.exe') ||
        (Platform.isAndroid &&
            (info.apkUrl ?? '').toLowerCase().endsWith('.apk'));
    if (!inAppDownload) {
      try {
        final message = await UpdateService.install(info);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
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
                value == 0
                    ? '连接下载地址…'
                    : '已下载 ${(value * 100).toStringAsFixed(0)}%',
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
      final message = await UpdateService.install(
        info,
        onProgress: (value) {
          progress.value = value;
        },
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
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
                  onPressed: () => launchUrl(
                    Uri.parse(info.pageUrl!),
                    mode: LaunchMode.externalApplication,
                  ),
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
        backgroundColor: AppTheme.panel,
        surfaceTintColor: Colors.transparent,
        title: const Text('版本与更新'),
        actions: [
          IconButton(
            tooltip: '检查更新',
            onPressed: _reload,
            icon: const Icon(
              Icons.refresh_rounded,
              size: 20,
              color: AppTheme.muted,
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppTheme.line),
        ),
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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: AppTheme.panel,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.line),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.cloud_off_rounded,
                          size: 32,
                          color: AppTheme.muted,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${snapshot.error}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.error,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _reload,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            final info = snapshot.data!;
            _maybePrompt(info);
            final hasNew = info.buildNumber > UpdateService.appBuild;
            final notes = info.body.trim().isEmpty
                ? '这个版本没有写更新说明。'
                : _pretty(info.body).trim();
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(17),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFF1F6F3), AppTheme.panelAlt],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.line),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              gradient: AppTheme.accentGradient,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: const Icon(
                              Icons.chat_bubble_rounded,
                              size: 24,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 13),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '青屿',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  '让每一次对话随时继续',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: AppTheme.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (hasNew)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: const Text(
                                'NEW',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.accent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _versionBox(
                            '当前版本',
                            UpdateService.displayVersion,
                            accent: false,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _versionBox(
                            '最新版本',
                            info.versionLabel,
                            accent: hasNew,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      decoration: BoxDecoration(
                        color: AppTheme.panel,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '更新说明',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              if (!hasNew)
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 13,
                                      color: AppTheme.accent,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '已是最新',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: AppTheme.accent.withValues(
                                          alpha: 0.9,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SelectableText(
                            notes,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.7,
                              color: AppTheme.text,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (hasNew) ...[
                      FilledButton.icon(
                        onPressed: () => _download(info),
                        icon: const Icon(Icons.download_rounded, size: 17),
                        label: Text('下载并安装 ${info.versionLabel}'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                        ),
                      ),
                      const SizedBox(height: 9),
                    ],
                    if (info.pageUrl != null)
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse(info.pageUrl!),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.open_in_new_rounded, size: 15),
                        label: const Text('打开 Release 页面'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(42),
                          foregroundColor: AppTheme.muted,
                          side: const BorderSide(color: AppTheme.line),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _versionBox(String label, String value, {required bool accent}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: AppTheme.muted),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: accent ? AppTheme.accent : AppTheme.text,
            ),
          ),
        ],
      ),
    );
  }
}
