import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// 一条最新 release 的信息。
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.publishedAt,
    this.apkUrl,
    this.setupUrl,
    this.zipUrl,
    this.pageUrl,
  });

  final String tag;
  final String name;
  final String body;
  final DateTime publishedAt;
  final String? apkUrl;
  final String? setupUrl;
  final String? zipUrl;
  final String? pageUrl;

  /// release 正文里写着「构建 #123」，用它和本机构建号比。
  int get buildNumber {
    final match = RegExp(r'构建\s*#(\d+)').firstMatch(body);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// 正文里的版本号，例如「最新版本：v0.2.0」。
  String get versionLabel {
    final match = RegExp(r'最新版本[:：]\s*(v[\w.\-]+)').firstMatch(body);
    return match?.group(1) ?? tag;
  }

  String? get downloadUrl {
    if (Platform.isAndroid) return apkUrl ?? pageUrl;
    if (Platform.isWindows) return setupUrl ?? zipUrl ?? pageUrl;
    return pageUrl;
  }
}

/// 查更新、下载、拉起安装。
class UpdateService {
  static const defaultSource = 'https://github.com/J1nxi-youmi/dsh-chat';
  // CI 每次注入 0.2.<构建号>，本地构建没注入时退化成 0.2.0。
  static const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.3.0');
  static const appBuild = int.fromEnvironment('APP_BUILD', defaultValue: 0);

  /// 界面只显示版本号，构建号只在内部比较用。
  static String get displayVersion => 'v$appVersion';

  static Future<String> source() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('update.source') ?? defaultSource;
  }

  static Future<void> setSource(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update.source', value.trim());
  }

  /// 拉最新 release（GitHub API）。更新源只接受 github.com/<owner>/<repo>。
  static Future<UpdateInfo> fetchLatest() async {
    final src = await source();
    final match = RegExp(r'github\.com/([^/\s]+)/([^/\s#?]+)').firstMatch(src);
    if (match == null) {
      throw '更新源要填 GitHub 仓库地址，例如 $defaultSource';
    }
    final owner = match.group(1)!;
    final repo = match.group(2)!.replaceAll(RegExp(r'\.git$'), '');
    final api = Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');
    final response = await http.get(api, headers: {
      'accept': 'application/vnd.github+json',
      'user-agent': 'dsh-chat',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw '查询更新失败（HTTP ${response.statusCode}）';
    }
    final data = response.body;
    final json = const JsonDecoder().convert(data) as Map<String, dynamic>;
    final assets = (json['assets'] as List?) ?? const [];
    String? findAsset(String suffix) {
      for (final item in assets.whereType<Map<String, dynamic>>()) {
        final name = (item['name'] ?? '').toString().toLowerCase();
        if (name.endsWith(suffix)) return item['browser_download_url']?.toString();
      }
      return null;
    }

    return UpdateInfo(
      tag: (json['tag_name'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      publishedAt: DateTime.tryParse((json['published_at'] ?? '').toString())?.toLocal() ??
          DateTime.now(),
      apkUrl: findAsset('.apk'),
      setupUrl: findAsset('setup.exe'),
      zipUrl: findAsset('windows.zip'),
      pageUrl: json['html_url']?.toString(),
    );
  }

  /// Windows：带进度下载安装包并启动；Android：交给浏览器下载 APK。
  static Future<String> install(UpdateInfo info, {void Function(double)? onProgress}) async {
    final url = info.downloadUrl;
    if (url == null) throw '这个 release 里没有可下载的文件';
    if (Platform.isWindows && url.toLowerCase().endsWith('.exe')) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/dsh-chat-setup.exe');
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await client.send(request).timeout(const Duration(seconds: 60));
        if (response.statusCode != 200) throw '下载失败（HTTP ${response.statusCode}）';
        final total = response.contentLength ?? 0;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0 && onProgress != null) onProgress(received / total);
        }
        await sink.close();
      } finally {
        client.close();
      }
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      return '安装包已下载，安装程序已启动';
    }
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) throw '打不开下载地址';
    return '已在浏览器打开下载页';
  }
}
