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

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'mime': mime,
        'size': size,
        'duration': duration,
        'url': url,
      };

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
    this.seq = 0,
  });

  final String id;
  final String role; // user | assistant
  final String text;
  final List<Attachment> attachments;
  final DateTime at;

  /// 服务端给每条消息分配的单调序号，用来做断线增量同步。
  final int seq;

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
        seq: (json['seq'] as num?)?.toInt() ?? 0,
      );
}

/// 还没被服务端 ack 的消息。断线/重启后按顺序重发。
class Outgoing {
  Outgoing({
    required this.clientMessageId,
    required this.text,
    required this.attachments,
    required this.at,
    this.status = 'sending',
  });

  final String clientMessageId;
  final String text;
  final List<Attachment> attachments;
  final DateTime at;

  /// sending | failed
  String status;

  factory Outgoing.fromJson(Map<String, dynamic> json) => Outgoing(
        clientMessageId: json['clientMessageId']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
        attachments: ((json['attachments'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Attachment.fromJson)
            .toList(),
        at: DateTime.tryParse(json['at']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
        // 重启后一律按「待重发」处理。
        status: 'failed',
      );

  Map<String, dynamic> toJson() => {
        'clientMessageId': clientMessageId,
        'text': text,
        'attachments': attachments.map((item) => item.toJson()).toList(),
        'at': at.toUtc().toIso8601String(),
      };

  Message asMessage() => Message(
        id: clientMessageId,
        role: 'user',
        text: text,
        attachments: attachments,
        at: at,
      );
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.preview,
    required this.messages,
    this.lastRole = '',
    this.lastSeq = 0,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String preview;
  final List<Message> messages;

  /// 最后一条是谁说的：列表里给「我：」前缀用。
  final String lastRole;

  /// 服务端最后一条消息的 seq：断线重连时当游标。
  final int lastSeq;

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
        lastRole: json['lastRole']?.toString() ?? '',
        lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
      );
}

class SendResult {
  SendResult({required this.user, required this.replies});
  final Message user;
  final List<Message> replies;
}
