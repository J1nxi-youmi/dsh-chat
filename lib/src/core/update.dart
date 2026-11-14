import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
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

  /// 构建号只藏在 release 正文的 HTML 注释里，不显示给用户。
  int get buildNumber {
    final match = RegExp(r'<!--[^>]*\bbuild:(\d+)[^>]*-->').firstMatch(body);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// 正文里的版本号，例如「最新版本：v1.2.2」。
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
  // CI 把构建号拆成版本号：构建 #122 -> 1.2.2，显示 v1.2.2。
  // 本地构建没注入时用当前基线。
  static const appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.2.2',
  );
  static const appBuild = int.fromEnvironment('APP_BUILD', defaultValue: 0);

  static String get displayVersion => 'v$appVersion';

  static Future<String> source() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('update.source') ?? defaultSource;
  }

  static Future<void> setSource(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update.source', value.trim());
  }

  /// 隧道代理地址：连接页存的服务器地址（手机那台 DSH 下载 GitHub 是通的）。
  static Future<String?> _proxyBase() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server');
    final token = prefs.getString('token');
    if (server == null || server.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return '$server/api/proxy?t=${Uri.encodeComponent(token)}';
  }

  /// 打开一个 GitHub 资源：先直连，超时/失败自动走隧道代理。
  static Future<http.StreamedResponse> _openStream(
    String url, {
    Duration? timeout,
  }) async {
    final client = http.Client();
    try {
      final resp = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(timeout ?? const Duration(seconds: 30));
      if (resp.statusCode == 200) return resp;
    } catch (_) {
      // 直连不通（国内常见），走隧道代理兜底。
    }
    final proxy = await _proxyBase();
    if (proxy == null) throw '连不上 GitHub（也没有可用的隧道代理）';
    final resp = await client
        .send(
          http.Request(
            'GET',
            Uri.parse('$proxy&url=${Uri.encodeComponent(url)}'),
          ),
        )
        .timeout(timeout ?? const Duration(seconds: 60));
    if (resp.statusCode != 200) throw '隧道代理下载失败（HTTP ${resp.statusCode}）';
    return resp;
  }

  /// GET 一个文本资源（JSON API），带隧道兜底。
  static Future<String?> _readString(
    String url, {
    Map<String, String>? headers,
  }) async {
    final resp = await _openStream(url);
    final body = await http.Response.fromStream(resp);
    if (body.statusCode != 200) return null;
    return body.body;
  }

  /// 只认「App 的 Release」。
  ///
  /// 插件（`plugin/`）也会发 Release，tag 是 `plugin-v0.2.6` 这种，正文是插件说明、
  /// 附件是 tgz——绝不能把它当成 App 的新版本，否则版本页会显示「最新版本 plugin-v0.2.6」。
  static bool looksLikeApp(Map<String, dynamic> json) {
    if (json['draft'] == true || json['prerelease'] == true) return false;
    final tag = (json['tag_name'] ?? '').toString();
    if (tag.startsWith('plugin-')) return false;
    final body = (json['body'] ?? '').toString();
    // CI 写的 App 版本正文里有 `<!-- build:148 构建 #148 -->`。
    if (RegExp(r'<!--[^>]*\bbuild:\d+').hasMatch(body)) return true;
    // 更老的 release 没这个注释，就看有没有 App 的安装包。
    final assets = (json['assets'] as List?) ?? const [];
    return assets.whereType<Map<String, dynamic>>().any((item) {
      final name = (item['name'] ?? '').toString().toLowerCase();
      return name.endsWith('.apk') ||
          name.endsWith('setup.exe') ||
          name.endsWith('windows.zip');
    });
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
    const headers = {
      'accept': 'application/vnd.github+json',
      'user-agent': 'dsh-chat',
    };

    // 先翻列表挑 App 的那一条：/releases/latest 现在可能指向插件的 Release。
    Map<String, dynamic>? picked;
    final listRaw = await _readString(
      'https://api.github.com/repos/$owner/$repo/releases?per_page=30',
      headers: headers,
    );
    if (listRaw != null) {
      final list = jsonDecode(listRaw);
      if (list is List) {
        for (final item in list.whereType<Map<String, dynamic>>()) {
          if (looksLikeApp(item)) {
            picked = item;
            break;
          }
        }
      }
    }
    // 列表接口抽风就退回 latest（顺带也过一遍同样的判断）。
    if (picked == null) {
      final data = await _readString(
        'https://api.github.com/repos/$owner/$repo/releases/latest',
        headers: headers,
      );
      if (data == null) throw '查询更新失败';
      final one = jsonDecode(data);
      if (one is Map<String, dynamic> && looksLikeApp(one)) picked = one;
    }
    if (picked == null) throw '没有找到 App 的 Release（仓库里可能只有插件版本）';

    final json = picked;
    final assets = (json['assets'] as List?) ?? const [];
    String? findAsset(String suffix) {
      for (final item in assets.whereType<Map<String, dynamic>>()) {
        final name = (item['name'] ?? '').toString().toLowerCase();
        if (name.endsWith(suffix)) {
          return item['browser_download_url']?.toString();
        }
      }
      return null;
    }

    return UpdateInfo(
      tag: (json['tag_name'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      publishedAt:
          DateTime.tryParse(
            (json['published_at'] ?? '').toString(),
          )?.toLocal() ??
          DateTime.now(),
      apkUrl: findAsset('.apk'),
      setupUrl: findAsset('setup.exe'),
      zipUrl: findAsset('windows.zip'),
      pageUrl: json['html_url']?.toString(),
    );
  }

  /// Windows 下载安装包并启动；Android 下载 APK 后调起系统安装器；两者都带进度回调。
  static Future<String> install(
    UpdateInfo info, {
    void Function(double)? onProgress,
  }) async {
    final url = info.downloadUrl;
    if (url == null) throw '这个 release 里没有可下载的文件';
    final isExe = Platform.isWindows && url.toLowerCase().endsWith('.exe');
    final isApk = Platform.isAndroid && url.toLowerCase().endsWith('.apk');
    if (!isExe && !isApk) {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw '打不开下载地址';
      return '已在浏览器打开下载页';
    }
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/${isExe ? 'dsh-chat-setup.exe' : 'dsh-chat.apk'}',
    );
    final response = await _openStream(
      url,
      timeout: const Duration(seconds: 60),
    );
    final total = response.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0 && onProgress != null) onProgress(received / total);
    }
    await sink.close();
    if (isExe) {
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      return '安装包已下载，安装程序已启动';
    }
    // Android：交给系统安装器（第一次会问「允许安装未知应用」）。
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      throw '打不开安装包：${result.message}';
    }
    return '下载完成，请在弹出的页面点「安装」';
  }
}
