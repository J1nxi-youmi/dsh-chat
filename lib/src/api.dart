import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'profile.dart';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// 连不上的时候抛这个，界面上直接显示 message。
class ApiError implements Exception {
  ApiError(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// 一台 DSH 上的聊天服务客户端。
///
/// 协议就三样：`/api/*` 的 JSON 接口、`/api/events` 的 SSE、`/media/*` 的附件。
class ChatApi {
  ChatApi({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;

  HttpClient? _client;
  StreamSubscription<Map<String, dynamic>>? _events;
  bool _eventsStarted = false;
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();

  /// 服务端允许的单文件上限（字节），从 /healthz 读；读不到就用 96MB。
  int maxUploadBytes = 96 * 1024 * 1024;

  /// SSE 是否在线：断线横幅和「重连后补发」都靠它。
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  /// 实时消息流（新回复、DSH 主动推来的）。
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  HttpClient get _http {
    return _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(minutes: 2);
  }

  Map<String, String> get _headers => {'authorization': 'Bearer $token'};

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final request = await _http.openUrl(method, _uri(path));
    _headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(
      const Duration(seconds: 120),
    );
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == 401) {
      throw ApiError('令牌不对，或者这台 DSH 换了令牌', 401);
    }
    dynamic data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      final lower = text.toLowerCase();
      // Cloudflare 的 1033 = 隧道没开 / 主机名没接上，不是服务端坏了。
      if (lower.contains('error code: 1033') || lower.contains('cloudflare')) {
        throw ApiError(
          '隧道没开，或者地址已经过期（Cloudflare 1033）。'
          '重新启动隧道会拿到新地址，记得回来改这里。',
        );
      }
      throw ApiError(
        '服务返回的不是 JSON：${text.length > 120 ? text.substring(0, 120) : text}',
      );
    }
    if (response.statusCode >= 400 || (data is Map && data['ok'] == false)) {
      final message = data is Map
          ? (data['error']?.toString() ?? '请求失败')
          : '请求失败';
      throw ApiError(message, response.statusCode);
    }
    return data;
  }

  Future<List<Conversation>> conversations() async {
    final data = await _send('GET', '/api/conversations');
    final list = (data['conversations'] as List?) ?? const [];
    return list
        .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<Conversation> createConversation() async {
    final data = await _send('POST', '/api/conversations', const {});
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<Conversation> conversation(String id) async {
    final data = await _send('GET', '/api/conversations/$id');
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<void> deleteConversation(String id) =>
      _send('DELETE', '/api/conversations/$id');

  /// 发一条消息，返回服务端落下的（用户消息 + 可能的多条回复）。
  ///
  /// [clientMessageId] 是幂等键：断线重发同一条时，服务端只会入库一次，
  /// 上次生成失败的话会复用这条用户消息重新跑一轮。
  Future<SendResult> sendMessage(
    String conversationId, {
    required String text,
    List<String> attachmentIds = const [],
    String? clientMessageId,
  }) async {
    final data = await _send(
      'POST',
      '/api/conversations/$conversationId/messages',
      {
        'text': text,
        'attachments': attachmentIds.map((id) => {'id': id}).toList(),
        if (clientMessageId != null) 'clientMessageId': clientMessageId,
      },
    );
    final replies = (data['replies'] as List?) ?? [data['reply']];
    return SendResult(
      user: Message.fromJson(data['user'] as Map<String, dynamic>),
      replies: replies
          .whereType<Map<String, dynamic>>()
          .map(Message.fromJson)
          .toList(),
    );
  }

  /// 增量拉取：只要 seq 大于 [since] 的消息（断线重连用）。
  Future<List<Message>> messagesSince(
    String conversationId,
    int since, {
    int limit = 200,
  }) async {
    final data = await _send(
      'GET',
      '/api/conversations/$conversationId/messages?since=$since&limit=$limit',
    );
    final list = (data['messages'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(Message.fromJson)
        .toList();
  }

  /// 上传附件；voice 的话带上时长（秒）。
  Future<Attachment> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    String kind = 'file',
    double duration = 0,
    String? textPreview,
  }) async {
    final data = await _send('POST', '/api/upload', {
      'name': name,
      'mime': mime,
      'data': base64Encode(bytes),
      'kind': kind,
      'duration': duration,
      if (textPreview != null) 'textPreview': textPreview,
    });
    return Attachment.fromJson(data['attachment'] as Map<String, dynamic>);
  }

  /// 附件的完整地址（带令牌，直接给 Image / 播放器用）。
  String mediaUrl(String path) {
    final url = path.startsWith('http') ? path : '$baseUrl$path';
    if (url.contains('t=')) return url;
    return '$url${url.contains('?') ? '&' : '?'}t=$token';
  }

  /// 问一下服务端允许多大的文件（/healthz 里的 maxUploadBytes）。
  Future<void> refreshLimits() async {
    try {
      final data = await _send('GET', '/healthz');
      final limit = data is Map
          ? (data['maxUploadBytes'] as num?)?.toInt()
          : null;
      if (limit != null && limit > 0) maxUploadBytes = limit;
    } catch (_) {
      /* 拿不到就按默认 96MB */
    }
  }

  /// 拉「我的资料」（昵称 + 头像），连上服务器后自动同步。
  Future<void> refreshProfile() async {
    try {
      final data = await _send('GET', '/api/profile');
      final profile = data is Map ? data['profile'] : null;
      if (profile is! Map) return;
      final url = (profile['avatarUrl'] ?? '').toString();
      final rawStickers = profile['stickers'];
      final stickers = rawStickers is List
          ? rawStickers
                .whereType<Map<String, dynamic>>()
                .map(Attachment.fromJson)
                .toList()
          : null;
      await AppProfile.instance.applyRemote(
        nickname: (profile['nickname'] ?? '').toString(),
        avatarUrl: url.isEmpty ? '' : mediaUrl(url),
        stickers: stickers,
      );
    } catch (_) {
      /* 老版本插件没有这个接口，忽略 */
    }
  }

  /// 把本机资料推到云端，其它设备连上后自动同步。
  Future<void> saveProfile({
    required String nickname,
    required String avatarUrl,
  }) async {
    await _send('POST', '/api/profile', {
      'nickname': nickname,
      'avatarUrl': avatarUrl,
    });
  }

  /// 只保存自定义表情包，昵称/头像由服务端保留原值。
  Future<void> saveStickers(List<Attachment> stickers) async {
    await _send('POST', '/api/profile', {
      'stickers': stickers.map((item) => item.toJson()).toList(),
    });
  }

  /// 量一次 /healthz 的往返延迟（毫秒）；失败返回 null。
  Future<int?> measureLatency() async {
    try {
      final sw = Stopwatch()..start();
      await _send('GET', '/healthz');
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  /// 连 SSE，断了自己重连。重复调用无副作用。
  void startEvents() {
    if (_eventsStarted) return;
    _eventsStarted = true;
    _events?.cancel();
    _events = _listen().listen(_eventsController.add);
  }

  Stream<Map<String, dynamic>> _listen() async* {
    while (true) {
      try {
        final request = await _http.getUrl(
          _uri('/api/events?t=${Uri.encodeComponent(token)}'),
        );
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        final response = await request.close();
        if (response.statusCode != 200) {
          connected.value = false;
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        connected.value = true;
        var buffer = '';
        await for (final chunk in response.transform(utf8.decoder)) {
          buffer += chunk;
          var index = buffer.indexOf('\n\n');
          while (index >= 0) {
            final block = buffer.substring(0, index);
            buffer = buffer.substring(index + 2);
            for (final line in block.split('\n')) {
              if (!line.startsWith('data: ')) continue;
              final payload = line.substring(6);
              if (payload.trim().isEmpty) continue;
              try {
                final decoded = jsonDecode(payload);
                if (decoded is Map<String, dynamic>) yield decoded;
              } catch (_) {
                // 不是 JSON 就跳过
              }
            }
            index = buffer.indexOf('\n\n');
          }
        }
        // 流正常结束 = 服务端断开
        connected.value = false;
      } catch (_) {
        // 网络抖一下就等会儿重连
        connected.value = false;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void dispose() {
    _events?.cancel();
    connected.value = false;
    _client?.close(force: true);
    _eventsController.close();
  }
}
