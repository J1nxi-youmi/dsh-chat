import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  StreamSubscription<String>? _events;
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();

  /// 实时消息流（新回复、DSH 主动推来的）。
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  HttpClient get _http {
    return _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(minutes: 2);
  }

  Map<String, String> get _headers => {
        'authorization': 'Bearer $token',
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final request = await _http.openUrl(method, _uri(path));
    _headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 120));
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == 401) {
      throw ApiError('令牌不对，或者这台 DSH 换了令牌', 401);
    }
    dynamic data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      throw ApiError('服务返回的不是 JSON：${text.length > 120 ? text.substring(0, 120) : text}');
    }
    if (response.statusCode >= 400 || (data is Map && data['ok'] == false)) {
      final message = data is Map ? (data['error']?.toString() ?? '请求失败') : '请求失败';
      throw ApiError(message, response.statusCode);
    }
    return data;
  }

  Future<List<Conversation>> conversations() async {
    final data = await _send('GET', '/api/conversations');
    final list = (data['conversations'] as List?) ?? const [];
    return list.map((item) => Conversation.fromJson(item as Map<String, dynamic>)).toList();
  }

  Future<Conversation> createConversation() async {
    final data = await _send('POST', '/api/conversations', const {});
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<Conversation> conversation(String id) async {
    final data = await _send('GET', '/api/conversations/$id');
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<void> deleteConversation(String id) => _send('DELETE', '/api/conversations/$id');

  /// 发一条消息，返回服务端落下的（用户消息 + 可能的多条回复）。
  Future<SendResult> sendMessage(
    String conversationId, {
    required String text,
    List<String> attachmentIds = const [],
  }) async {
    final data = await _send('POST', '/api/conversations/$conversationId/messages', {
      'text': text,
      'attachments': attachmentIds.map((id) => {'id': id}).toList(),
    });
    final replies = (data['replies'] as List?) ?? [data['reply']];
    return SendResult(
      user: Message.fromJson(data['user'] as Map<String, dynamic>),
      replies: replies
          .whereType<Map<String, dynamic>>()
          .map(Message.fromJson)
          .toList(),
    );
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

  /// 连 SSE，断了自己重连。
  void startEvents() {
    _events?.cancel();
    _events = _listen().listen(_eventsController.add);
  }

  Stream<Map<String, dynamic>> _listen() async* {
    while (true) {
      try {
        final request = await _http.getUrl(_uri('/api/events?t=${Uri.encodeComponent(token)}'));
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        final response = await request.close();
        if (response.statusCode != 200) {
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
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
      } catch (_) {
        // 网络抖一下就等会儿重连
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void dispose() {
    _events?.cancel();
    _client?.close(force: true);
    _eventsController.close();
  }
}
