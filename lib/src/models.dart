/// 服务端的数据结构。字段跟 `/api/*` 一一对应。
class Attachment {
  Attachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.mime,
    required this.size,
    required this.duration,
    required this.url,
  });

  final String id;
  final String kind; // image | voice | file
  final String name;
  final String mime;
  final int size;
  final double duration;
  final String url;

  bool get isImage => kind == 'image';
  bool get isVoice => kind == 'voice';

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'file',
        name: json['name']?.toString() ?? '文件',
        mime: json['mime']?.toString() ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        url: json['url']?.toString() ?? '',
      );

  String get sizeText {
    if (size >= 1024 * 1024) return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(size / 1024).round().clamp(1, 9999)} KB';
  }
}

class Message {
  Message({
    required this.id,
    required this.role,
    required this.text,
    required this.attachments,
    required this.at,
  });

  final String id;
  final String role; // user | assistant
  final String text;
  final List<Attachment> attachments;
  final DateTime at;

  bool get isMine => role == 'user';

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id']?.toString() ?? '',
        role: json['role']?.toString() ?? 'assistant',
        text: json['text']?.toString() ?? '',
        attachments: ((json['attachments'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Attachment.fromJson)
            .toList(),
        at: DateTime.tryParse(json['at']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
      );
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.preview,
    required this.messages,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String preview;
  final List<Message> messages;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '新对话',
        updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '')?.toLocal() ??
            DateTime.now(),
        preview: json['preview']?.toString() ?? '',
        messages: ((json['messages'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Message.fromJson)
            .toList(),
      );
}

class SendResult {
  SendResult({required this.user, required this.replies});
  final Message user;
  final List<Message> replies;
}
