import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_chat/src/core/api.dart';
import 'package:dsh_chat/src/core/app_state.dart';
import 'package:dsh_chat/src/core/image_utils.dart';
import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/core/profile.dart';
import 'package:dsh_chat/src/core/theme.dart';
import 'controllers/chat_scroll_controller.dart';
import 'widgets/chat_message_list.dart';
import 'widgets/message_search_dialog.dart';
import 'widgets/pending_attachment_tile.dart';
import 'widgets/sticker_panel.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.api,
    required this.conversationId,
    required this.title,
    this.embedded = false,
    this.onTitleChanged,
  });

  final ChatApi api;
  final String conversationId;
  final String title;

  /// 嵌在桌面端三栏里时不要自己的 AppBar/Scaffold。
  final bool embedded;
  final ValueChanged<String>? onTitleChanged;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  late final ChatScrollController _chatScroll;
  final _recorder = AudioRecorder();

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 长按录音的状态：按下的位置、是否已经上滑取消。
  Offset? _recordPointer;
  bool _recordCancelled = false;
  bool _recordStarting = false;
  bool _recordReleasedBeforeStart = false;
  bool _dragging = false;

  List<Message> _messages = const [];
  String? _highlightedMessageId;
  Message? _replyTo;
  final Set<String> _hiddenMessageIds = {};
  final Map<String, String> _transcripts = {};
  final Set<String> _transcribing = {};

  /// 待发送附件：先显示本地预览，上传在后台跑，点发送时若还没传完就等它。
  final List<PendingAttachment> _pending = [];
  final List<Future<void>> _uploadJobs = [];

  /// 还没被 ack 的消息；断线/重启后按顺序重发。
  final List<Outgoing> _outbox = [];
  int _lastSeq = 0;
  bool _connected = true;
  bool _flushing = false;
  StreamSubscription<Map<String, dynamic>>? _events;
  bool _sending = false;
  bool _recording = false;
  DateTime? _recordStarted;
  Timer? _ticker;
  Duration _recorded = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    activeConversationId.value = widget.conversationId;
    _connected = widget.api.connected.value;
    _chatScroll = ChatScrollController(
      contentCount: () =>
          _messages.length + _outbox.length + (_sending ? 1 : 0),
      onChanged: () {
        if (mounted) setState(() {});
      },
    )..attach();
    widget.api.connected.addListener(_onConnection);
    _input.addListener(_onInputChanged);
    // 全局监听 Ctrl/Cmd+V：文本框自己也会处理文字粘贴，这里只额外抓图片/文件。
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _loadOutbox();
    _load();
    _events = widget.api.events.listen(_onEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    if (activeConversationId.value == widget.conversationId) {
      activeConversationId.value = null;
    }
    widget.api.connected.removeListener(_onConnection);
    _input.removeListener(_onInputChanged);
    _events?.cancel();
    _ticker?.cancel();
    _chatScroll.dispose();
    _recorder.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 桌面端 Ctrl/Cmd+V：剪贴板里有图片/文件就上传；文字照旧由输入框粘贴。
  bool _onGlobalKey(KeyEvent event) {
    if (!_isDesktop || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
    if (!HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    unawaited(_pasteFromClipboard());
    return false;
  }

  bool get _canSend => _input.text.trim().isNotEmpty || _pending.isNotEmpty;

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  void _onConnection() {
    if (!mounted) return;
    setState(() => _connected = widget.api.connected.value);
    if (_connected) {
      // 断线期间可能错过了几条，也可能有没发出去的。
      unawaited(_syncSince());
      unawaited(_flushOutbox());
    }
  }

  Future<void> _load() async {
    try {
      final conversation = await widget.api.conversation(widget.conversationId);
      final prefs = await SharedPreferences.getInstance();
      final hidden = prefs.getStringList(_hiddenKey) ?? const [];
      final transcriptRaw = prefs.getString(_transcriptKey);
      final transcripts = <String, String>{};
      if (transcriptRaw != null) {
        try {
          final decoded = jsonDecode(transcriptRaw);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              transcripts[entry.key.toString()] = entry.value.toString();
            }
          }
        } catch (_) {
          /* 坏缓存忽略 */
        }
      }
      if (!mounted) return;
      setState(() {
        _hiddenMessageIds
          ..clear()
          ..addAll(hidden);
        _transcripts
          ..clear()
          ..addAll(transcripts);
        _messages = conversation.messages
            .where((message) => !_hiddenMessageIds.contains(message.id))
            .toList();
        _lastSeq = conversation.messages.fold(
          0,
          (max, item) => item.seq > max ? item.seq : max,
        );
        _error = null;
        _chatScroll.reset();
      });
      _chatScroll.scrollToBottom();
      unawaited(_syncSince());
      unawaited(_flushOutbox());
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  /// 从服务端补 seq 大于本地游标的消息。
  Future<void> _syncSince() async {
    try {
      final fresh = await widget.api.messagesSince(
        widget.conversationId,
        _lastSeq,
      );
      if (!mounted || fresh.isEmpty) return;
      final before = _messages.length;
      setState(() {
        for (final message in fresh) {
          _merge(message);
        }
      });
      final added = _messages.length - before;
      if (added <= 0) return;
      if (!_chatScroll.atBottom) _chatScroll.addUnread(added);
    } catch (_) {
      /* 下次重连再补 */
    }
  }

  /// 合并一条消息（去重、按 seq 保序、推进游标）。
  void _merge(Message message) {
    if (_hiddenMessageIds.contains(message.id)) return;
    if (_messages.any((item) => item.id == message.id)) return;
    // 自己发的消息经由 SSE 回来时，把本地「发送中」那条移除，避免出现两条。
    final echoed = message.clientMessageId;
    if (echoed != null) {
      final before = _outbox.length;
      _outbox.removeWhere((item) => item.clientMessageId == echoed);
      if (_outbox.length != before) unawaited(_saveOutbox());
    }
    _messages = [..._messages, message]
      ..sort((left, right) => left.seq.compareTo(right.seq));
    if (message.seq > _lastSeq) _lastSeq = message.seq;
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] != 'message') return;
    if (event['conversationId'] != widget.conversationId) return;
    final raw = event['message'];
    if (raw is! Map<String, dynamic>) return;
    final message = Message.fromJson(raw);
    // 事件中间漏了（比如断线重连）就整段补一次，别只追这一条。
    if (message.seq > _lastSeq + 1) {
      unawaited(_syncSince());
      return;
    }
    final before = _messages.length;
    setState(() => _merge(message));
    if (_messages.length <= before) return;
    if (!_chatScroll.atBottom) _chatScroll.addUnread(1);
  }

  Future<void> _pickFiles({bool imagesOnly = false}) async {
    try {
      // file_picker 13.x：pickFiles 直接返回 List<PlatformFile>（多选默认开），
      // 字节要自己 readAsBytes()，没有 withData 参数了。
      final files = await FilePicker.pickFiles(
        type: imagesOnly ? FileType.image : FileType.any,
      );
      for (final file in files) {
        final bytes = await file.readAsBytes();
        unawaited(
          _uploadBytes(
            name: file.name,
            mime: _guessMime(file.name),
            bytes: bytes,
          ),
        );
      }
    } catch (error) {
      _toast(error.toString());
    }
  }

  /// 统一的「拿到字节就上传」入口：选文件、拖文件、粘贴图片都走这里。
  Future<bool> _uploadBytes({
    required String name,
    required String mime,
    required Uint8List bytes,
    String? kind,
  }) async {
    var data = bytes;
    var mimeType = mime;
    final limit = widget.api.maxUploadBytes;
    if (data.length > limit) {
      _toast('$name 超过上限 ${limit ~/ (1024 * 1024)}MB，发不出去');
      return false;
    }
    // BMP 伪装成别的扩展名时，手机端渲染会失败：先统一转 PNG。
    if (mimeType.startsWith('image/')) {
      final fixed = await normalizeImageBytes(data, mimeType);
      if (!identical(fixed, data)) {
        data = fixed;
        mimeType = 'image/png';
      }
    }
    // 先上屏：本地字节直接当预览，上传放后台，不用等隧道一个来回。
    final isImage = mime.startsWith('image/');
    final item = PendingAttachment(
      name: name,
      bytes: data,
      isImage: isImage,
      isVoice: kind == 'voice',
    );
    if (mounted) setState(() => _pending.add(item));
    final job = () async {
      try {
        final attachment = await widget.api.upload(
          name: name,
          mime: mimeType,
          bytes: data,
          kind: kind ?? (isImage ? 'image' : 'file'),
          textPreview: _isText(name)
              ? String.fromCharCodes(data.take(4000))
              : null,
        );
        item.attachment = attachment;
      } catch (error) {
        _toast('$name 上传失败：$error');
        if (mounted) setState(() => _pending.remove(item));
      } finally {
        if (mounted) setState(() {});
      }
    }();
    _uploadJobs.add(job);
    unawaited(job.whenComplete(() => _uploadJobs.remove(job)));
    return true;
  }

  /// 拖进来的文件（桌面端）。拖文件夹的话把里面的文件逐个发出去。
  Future<void> _handleDropped(DropDoneDetails details) async {
    if (!mounted) return;
    setState(() => _dragging = false);
    for (final file in details.files) {
      try {
        final path = file.path;
        if (path.isNotEmpty && Directory(path).existsSync()) {
          await _uploadDirectory(Directory(path));
          continue;
        }
        final bytes = await file.readAsBytes();
        unawaited(
          _uploadBytes(
            name: file.name.isEmpty ? '拖入文件' : file.name,
            mime: file.mimeType ?? _guessMime(file.name),
            bytes: bytes,
          ),
        );
      } on PathAccessException catch (error) {
        _toast('这个路径读不了（${error.path ?? '未知'}），可能没权限');
      } catch (error) {
        _toast('读取拖入的文件失败：$error');
      }
    }
  }

  /// 拖进来的文件夹：递归收集文件，最多 30 个，逐个上传。
  Future<void> _uploadDirectory(Directory directory) async {
    final files = <File>[];
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files.add(entity);
      }
    } catch (error) {
      _toast('读取文件夹失败：$error');
      return;
    }
    if (files.isEmpty) {
      _toast('文件夹是空的');
      return;
    }
    if (files.length > 30) {
      _toast('文件夹里文件太多（${files.length} 个），一次最多 30 个');
      return;
    }
    for (final file in files) {
      try {
        final name = file.uri.pathSegments.last;
        unawaited(
          _uploadBytes(
            name: name,
            mime: _guessMime(name),
            bytes: await file.readAsBytes(),
          ),
        );
      } catch (error) {
        _toast('跳过 ${file.path}：$error');
      }
    }
  }

  /// Ctrl+V：先看剪贴板里有没有图片，再看有没有复制的文件。
  Future<void> _pasteFromClipboard() async {
    try {
      final image = await Pasteboard.image;
      if (image != null && image.isNotEmpty) {
        await _uploadBytes(
          name: '粘贴的图片-${DateTime.now().millisecondsSinceEpoch}.png',
          mime: 'image/png',
          bytes: image,
        );
        return;
      }
      final files = await Pasteboard.files();
      for (final path in files) {
        final file = File(path);
        if (!await file.exists()) continue;
        unawaited(
          _uploadBytes(
            name: file.uri.pathSegments.isEmpty
                ? '粘贴的文件'
                : file.uri.pathSegments.last,
            mime: _guessMime(path),
            bytes: await file.readAsBytes(),
          ),
        );
      }
      // 没图没文件就不吭声：剪贴板里的文字由输入框自己粘贴，不用打扰。
    } catch (error) {
      _toast('读取剪贴板失败：$error');
    }
  }

  // ---------------------------------------------------------------- 长按说话

  Future<void> _startRecording() async {
    if (_recording || _recordStarting) return;
    _recordStarting = true;
    _recordReleasedBeforeStart = false;
    if (!await _recorder.hasPermission()) {
      _recordStarting = false;
      _toast('没有麦克风权限');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (error) {
      _recordStarting = false;
      _toast('录音启动失败：$error');
      return;
    }
    _recordStarting = false;
    if (!mounted) return;
    setState(() {
      _recording = true;
      _recordStarted = DateTime.now();
      _recorded = Duration.zero;
      _recordCancelled = false;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _recordStarted == null) return;
      setState(() => _recorded = DateTime.now().difference(_recordStarted!));
    });
    // 手快：按下还没启动好就松开了，直接当取消。
    if (_recordReleasedBeforeStart) {
      _recordReleasedBeforeStart = false;
      await _finishRecording(send: false);
    }
  }

  /// [send] 为 false 表示上滑取消了，录到的内容直接丢掉。
  Future<void> _finishRecording({required bool send}) async {
    if (!_recording) return;
    final path = await _recorder.stop();
    _ticker?.cancel();
    final duration = _recorded.inMilliseconds / 1000;
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recorded = Duration.zero;
      _recordCancelled = false;
    });
    if (!send) {
      _toast('已取消');
      return;
    }
    if (path == null || duration < 1.0) {
      _toast('太短了，按住多说一会儿');
      return;
    }
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final attachment = await widget.api.upload(
        name: '语音-${DateTime.now().millisecondsSinceEpoch}.wav',
        mime: 'audio/wav',
        bytes: bytes,
        kind: 'voice',
        duration: duration,
      );
      setState(
        () => _pending.add(
          PendingAttachment(
            name: attachment.name,
            bytes: bytes,
            isImage: false,
            isVoice: true,
          )..attachment = attachment,
        ),
      );
      await _send();
    } catch (error) {
      _toast(error.toString());
    }
  }

  void _onMicPointerDown(PointerDownEvent event) {
    _recordPointer = event.position;
    _startRecording();
  }

  void _onMicPointerMove(PointerMoveEvent event) {
    final origin = _recordPointer;
    if (origin == null || !_recording) return;
    final dy = event.position.dy - origin.dy;
    final cancelled = dy < -60;
    if (cancelled != _recordCancelled) {
      setState(() => _recordCancelled = cancelled);
    }
  }

  void _onMicPointerUp(PointerUpEvent event) {
    if (_recordPointer == null) return;
    _recordPointer = null;
    if (_recordStarting) {
      _recordReleasedBeforeStart = true;
      return;
    }
    _finishRecording(send: !_recordCancelled);
  }

  void _onMicPointerCancel(PointerCancelEvent event) {
    if (_recordPointer == null) return;
    _recordPointer = null;
    if (_recordStarting) {
      _recordReleasedBeforeStart = true;
      return;
    }
    _finishRecording(send: false);
  }

  Future<void> _send() async {
    var text = _input.text.trim();
    final reply = _replyTo;
    if (reply != null) {
      final body = reply.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      final quote = body.isEmpty
          ? '${reply.attachments.length} 个附件'
          : (body.length > 80 ? '${body.substring(0, 80)}…' : body);
      final author = reply.isMine ? '我' : widget.title;
      text = '> $author：$quote\n\n$text';
    }
    if (text.isEmpty && _pending.isEmpty) return;
    // 还有没传完的附件就把它们等完，最多再等 30 秒。
    if (_uploadJobs.isNotEmpty) {
      _toast('正在上传附件…');
      await Future.wait(
        _uploadJobs,
      ).timeout(const Duration(seconds: 30), onTimeout: () => []);
    }
    final readyAttachments = _pending
        .map((item) => item.attachment)
        .whereType<Attachment>()
        .toList();
    final item = Outgoing(
      clientMessageId: _newClientId(),
      text: text,
      attachments: readyAttachments,
      at: DateTime.now(),
    );
    _input.clear();
    setState(() {
      _replyTo = null;
      _pending.clear();
      _outbox.add(item);
    });
    // 本地消息先出现，此时立刻贴底；接口返回后再校一次。
    _chatScroll.scrollToBottom();
    await _saveOutbox();
    await _deliver(item);
    if (mounted) {
      setState(() {});
      _chatScroll.scrollToBottom(settle: true);
    }
  }

  // ---------------------------------------------------------------- 未 ack 队列

  String get _outboxKey => 'chat.outbox.${widget.conversationId}';
  String get _hiddenKey => 'chat.hidden.${widget.conversationId}';
  String get _transcriptKey => 'chat.transcript.${widget.conversationId}';

  String _newClientId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final random = DateTime.now().hashCode.toRadixString(16).padLeft(8, '0');
    return '$now-$random';
  }

  Future<void> _loadOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).whereType<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _outbox
          ..clear()
          ..addAll(list.map(Outgoing.fromJson));
      });
    } catch (_) {
      /* 坏数据就当没有 */
    }
  }

  Future<void> _saveOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    if (_outbox.isEmpty) {
      await prefs.remove(_outboxKey);
      return;
    }
    await prefs.setString(
      _outboxKey,
      jsonEncode(_outbox.map((item) => item.toJson()).toList()),
    );
  }

  /// 发一条队列里的消息：成功就移出队列并并入会话，失败标红等重试。
  Future<bool> _deliver(Outgoing item) async {
    setState(() => _sending = true);
    try {
      final result = await widget.api.sendMessage(
        widget.conversationId,
        text: item.text,
        attachmentIds: item.attachments
            .map((attachment) => attachment.id)
            .toList(),
        clientMessageId: item.clientMessageId,
      );
      _outbox.removeWhere(
        (entry) => entry.clientMessageId == item.clientMessageId,
      );
      await _saveOutbox();
      if (!mounted) return true;
      setState(() {
        _merge(result.user);
        for (final reply in result.replies) {
          _merge(reply);
        }
      });
      return true;
    } catch (error) {
      item.status = 'failed';
      await _saveOutbox();
      if (mounted) setState(() {});
      _toast(error.toString());
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 按顺序重发队列；失败就停，等下次重连。
  Future<void> _flushOutbox() async {
    if (_flushing || _outbox.isEmpty) return;
    _flushing = true;
    try {
      for (final item in [..._outbox]) {
        if (!_outbox.any(
          (entry) => entry.clientMessageId == item.clientMessageId,
        )) {
          continue;
        }
        item.status = 'sending';
        if (mounted) setState(() {});
        final ok = await _deliver(item);
        if (!ok) break;
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _retry(Outgoing item) async {
    item.status = 'sending';
    if (mounted) setState(() {});
    _chatScroll.scrollToBottom();
    await _deliver(item);
    if (mounted) {
      setState(() {});
      _chatScroll.scrollToBottom(settle: true);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _guessMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.json')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  bool _isText(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.json') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.log');
  }

  @override
  Widget build(BuildContext context) {
    final inner = Column(
      children: [
        if (!_connected) _connectionBanner(),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _messageList()),
              if (_chatScroll.unreadBelow > 0)
                Positioned(right: 20, bottom: 12, child: _newMessagesButton()),
            ],
          ),
        ),
        _composer(),
      ],
    );
    // 桌面 embedded：背景由最外层（desktop_home）统一绘制，这里保持透明，
    // 避免两层星空叠出黑竖条；手机端自己画星空。
    final body = _isDesktop ? inner : QingyuBackground(child: inner);
    // 桌面端：整块聊天区都能接住拖进来的文件。
    final content = _isDesktop
        ? DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _handleDropped,
            child: Stack(children: [body, if (_dragging) _dropOverlay()]),
          )
        : body;
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.panel,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 4,
        title: Row(
          children: [
            AvatarBadge(name: widget.title, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    '在呢，随时聊',
                    style: TextStyle(fontSize: 10, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索聊天',
            onPressed: openMessageSearch,
            icon: const Icon(
              Icons.search_rounded,
              size: 20,
              color: AppTheme.muted,
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
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
      body: content,
    );
  }

  Widget _dropOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.10),
            border: Border.all(
              color: AppTheme.accent.withValues(alpha: 0.7),
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: const Text(
            '松开，把文件发给她',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.text,
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: const BoxDecoration(
        color: Color(0xFFFFF6E8),
        border: Border(bottom: BorderSide(color: Color(0xFFF0DAB8))),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFB8873F),
            ),
          ),
          SizedBox(width: 8),
          Text(
            '连接中断，正在重连…',
            style: TextStyle(fontSize: 11, color: Color(0xFF9B722E)),
          ),
        ],
      ),
    );
  }

  /// 打开当前会话的消息搜索；点结果后关闭弹窗并跳到对应消息。
  Future<void> openMessageSearch() async {
    final target = await showDialog<Message>(
      context: context,
      builder: (_) =>
          MessageSearchDialog(messages: _messages, assistantName: widget.title),
    );
    if (target == null || !mounted) return;
    await _jumpToMessage(target);
  }

  Future<void> _jumpToMessage(Message target) async {
    final index = _messages.indexWhere((item) => item.id == target.id);
    if (index < 0) return;
    final contentCount = _messages.length + _outbox.length + (_sending ? 1 : 0);
    setState(() => _highlightedMessageId = target.id);
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !_chatScroll.itemScroll.isAttached) return;
    await _chatScroll.itemScroll.scrollTo(
      index: contentCount - index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.5,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && _highlightedMessageId == target.id) {
      setState(() => _highlightedMessageId = null);
    }
  }

  Widget _newMessagesButton() {
    return Material(
      color: AppTheme.panel,
      elevation: 3,
      shadowColor: const Color(0xFF25322E).withValues(alpha: 0.2),
      shape: const StadiumBorder(side: BorderSide(color: AppTheme.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => _chatScroll.scrollToBottom(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: AppTheme.accent,
              ),
              const SizedBox(width: 3),
              Text(
                '${_chatScroll.unreadBelow} 条新消息',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startReply(Message message) {
    setState(() => _replyTo = message);
    _inputFocus.requestFocus();
  }

  Future<void> _hideMessage(Message message) async {
    if (_hiddenMessageIds.contains(message.id)) return;
    setState(() {
      _hiddenMessageIds.add(message.id);
      _messages = _messages.where((item) => item.id != message.id).toList();
      if (_replyTo?.id == message.id) _replyTo = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, _hiddenMessageIds.toList());
  }

  Future<void> _transcribeVoice(Message message) async {
    Attachment? voice;
    for (final attachment in message.attachments) {
      if (attachment.isVoice) {
        voice = attachment;
        break;
      }
    }
    if (voice == null) {
      _toast('这条消息没有语音附件');
      return;
    }
    if (_transcribing.contains(message.id)) return;
    setState(() => _transcribing.add(message.id));
    try {
      final text = await widget.api.transcribe(voice.id);
      if (!mounted) return;
      if (text.trim().isEmpty) {
        _toast('语音转写没有返回内容');
        return;
      }
      setState(() => _transcripts[message.id] = text.trim());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_transcriptKey, jsonEncode(_transcripts));
    } catch (error) {
      if (mounted) _toast('转写失败：$error');
    } finally {
      if (mounted) setState(() => _transcribing.remove(message.id));
    }
  }

  Widget _messageList() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: AppTheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return ChatMessageList(
      messages: _messages,
      outbox: _outbox,
      sending: _sending,
      highlightedMessageId: _highlightedMessageId,
      mediaUrl: widget.api.mediaUrl,
      itemScrollController: _chatScroll.itemScroll,
      itemPositionsListener: _chatScroll.itemPositions,
      isDesktop: _isDesktop,
      onRetry: _retry,
      onReply: _startReply,
      onDelete: _hideMessage,
      onTranscribe: _transcribeVoice,
      transcripts: _transcripts,
      transcribing: _transcribing,
    );
  }

  /// 待发送附件：贴在输入框里，点右下角「发送」才真的发出去。
  Widget _pendingStrip() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in _pending)
            PendingAttachmentTile(
              item: item,
              onRemove: () => setState(() => _pending.remove(item)),
            ),
        ],
      ),
    );
  }

  Widget _replyBanner() {
    final reply = _replyTo!;
    final body = reply.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final preview = body.isEmpty
        ? '${reply.attachments.length} 个附件'
        : (body.length > 60 ? '${body.substring(0, 60)}…' : body);
    final author = reply.isMine ? '我' : widget.title;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      decoration: BoxDecoration(
        color: AppTheme.panelAlt,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, size: 15, color: AppTheme.accent),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '回复 $author：$preview',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: AppTheme.muted),
            ),
          ),
          IconButton(
            tooltip: '取消引用',
            onPressed: () => setState(() => _replyTo = null),
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close_rounded,
              size: 15,
              color: AppTheme.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_recording) _recordingHint(),
            // 青屿：暖白输入卡，桌面端限宽居中。
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 750),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: AppTheme.panel,
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(color: AppTheme.line),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF25322E).withValues(alpha: 0.05),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      if (_replyTo != null) _replyBanner(),
                      if (_pending.isNotEmpty) _pendingStrip(),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: Focus(
                          onKeyEvent: _onComposerKey,
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocus,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.newline,
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.5,
                              color: AppTheme.text,
                            ),
                            decoration: InputDecoration(
                              hintText: _recording ? '录音中…' : '',
                              isDense: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 8,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 34,
                        child: Row(
                          children: [
                            PopupMenuButton<String>(
                              tooltip: '图片 / 文件',
                              padding: EdgeInsets.zero,
                              splashRadius: 18,
                              icon: const Icon(
                                Icons.add_rounded,
                                size: 20,
                                color: AppTheme.muted,
                              ),
                              iconSize: 20,
                              onSelected: (value) {
                                if (value == 'image') {
                                  _pickFiles(imagesOnly: true);
                                }
                                if (value == 'file') {
                                  _pickFiles();
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'image',
                                  height: 40,
                                  child: SizedBox(
                                    width: 140,
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.image_rounded,
                                          size: 17,
                                          color: AppTheme.muted,
                                        ),
                                        SizedBox(width: 10),
                                        Text('图片'),
                                      ],
                                    ),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'file',
                                  height: 40,
                                  child: SizedBox(
                                    width: 140,
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.insert_drive_file_rounded,
                                          size: 17,
                                          color: AppTheme.muted,
                                        ),
                                        SizedBox(width: 10),
                                        Text('文件'),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            _micButton(),
                            _emojiButton(),
                            const Spacer(),
                            _sendButton(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isDesktop)
              const Padding(
                padding: EdgeInsets.only(top: 7),
                child: Text(
                  '支持粘贴图片、拖入文件与按住说话',
                  style: TextStyle(fontSize: 9, color: AppTheme.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 按住说话：按下开始，松开发送，上滑取消。
  Widget _micButton() {
    return Listener(
      onPointerDown: _onMicPointerDown,
      onPointerMove: _onMicPointerMove,
      onPointerUp: _onMicPointerUp,
      onPointerCancel: _onMicPointerCancel,
      child: Tooltip(
        message: '按住说话（上滑取消）',
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _recording
                ? AppTheme.error.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
          child: Icon(
            _recording ? Icons.mic : Icons.mic_none_rounded,
            size: 18,
            color: _recording ? AppTheme.error : AppTheme.muted,
          ),
        ),
      ),
    );
  }

  /// 在光标位置插入表情，不打断正在输入的文字。
  void _insertEmoji(String emoji) {
    final value = _input.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final next = value.text.replaceRange(start, end, emoji);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _inputFocus.requestFocus();
  }

  Future<void> _addStickers() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      _toast('正在添加表情包…');
      final next = [...AppProfile.instance.stickers];
      for (final file in files) {
        var bytes = await file.readAsBytes();
        var mime = _guessMime(file.name);
        if (mime.startsWith('image/')) {
          final fixed = await normalizeImageBytes(bytes, mime);
          if (!identical(fixed, bytes)) {
            bytes = fixed;
            mime = 'image/png';
          }
        }
        final attachment = await widget.api.upload(
          name: file.name,
          mime: mime,
          bytes: bytes,
          kind: 'image',
        );
        if (!next.any((item) => item.id == attachment.id)) {
          next.add(attachment);
        }
      }
      if (next.length == AppProfile.instance.stickers.length) {
        _toast('没有新的表情包');
        return;
      }
      // 先确保云端成功，另一端才能自动收到；再落本机并通知界面。
      await widget.api.saveStickers(next);
      await AppProfile.instance.saveStickers(next);
      if (mounted) _toast('已添加表情包，另一台设备会自动同步');
    } catch (error) {
      _toast('添加表情失败：$error');
    }
  }

  Future<void> _sendSticker(Attachment sticker) async {
    final item = Outgoing(
      clientMessageId: _newClientId(),
      text: '',
      attachments: [sticker],
      at: DateTime.now(),
    );
    if (mounted) setState(() => _outbox.add(item));
    _chatScroll.scrollToBottom();
    await _saveOutbox();
    await _deliver(item);
    if (mounted) {
      setState(() {});
      _chatScroll.scrollToBottom(settle: true);
    }
  }

  Future<void> _showEmojiPicker() async {
    final size = MediaQuery.sizeOf(context);
    final panelWidth = _isDesktop
        ? (size.width - 48).clamp(360.0, 560.0).toDouble()
        : (size.width - 24).clamp(300.0, 460.0).toDouble();
    final panelHeight = _isDesktop
        ? (size.height - 80).clamp(360.0, 500.0).toDouble()
        : (size.height * 0.65).clamp(380.0, 520.0).toDouble();

    if (_isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: AppTheme.panel,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppTheme.line),
          ),
          child: SizedBox(
            width: panelWidth,
            height: panelHeight,
            child: StickerPanel(
              mediaUrl: widget.api.mediaUrl,
              onEmoji: (value) {
                Navigator.of(dialogContext).pop();
                _insertEmoji(value);
              },
              onSendSticker: (sticker) {
                Navigator.of(dialogContext).pop();
                unawaited(_sendSticker(sticker));
              },
              onDelete: _deleteSticker,
              onAdd: _addStickers,
              onClose: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppTheme.panel,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: panelHeight,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: StickerPanel(
                  mediaUrl: widget.api.mediaUrl,
                  onEmoji: (value) {
                    Navigator.of(sheetContext).pop();
                    _insertEmoji(value);
                  },
                  onSendSticker: (sticker) {
                    Navigator.of(sheetContext).pop();
                    unawaited(_sendSticker(sticker));
                  },
                  onDelete: _deleteSticker,
                  onAdd: _addStickers,
                  onClose: () => Navigator.of(sheetContext).pop(),
                ),
              ),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _deleteSticker(Attachment sticker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: const Text('删除表情包'),
        content: Text('从云端移除「${sticker.name}」？另一台设备也会同步删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final next = AppProfile.instance.stickers
        .where((item) => item.id != sticker.id)
        .toList();
    try {
      await widget.api.saveStickers(next);
      await AppProfile.instance.saveStickers(next);
      if (mounted) _toast('表情包已删除，另一端会自动同步');
    } catch (error) {
      if (mounted) _toast('删除失败：$error');
    }
  }

  Widget _emojiButton() {
    return Tooltip(
      message: '表情',
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: _showEmojiPicker,
        child: const SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            Icons.emoji_emotions_outlined,
            size: 19,
            color: AppTheme.muted,
          ),
        ),
      ),
    );
  }

  Widget _sendButton() {
    final enabled = _canSend && !_sending;
    return Tooltip(
      message: '发送',
      child: Material(
        color: enabled ? AppTheme.accent : AppTheme.panelAlt,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? _send : null,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 18,
              color: enabled ? Colors.white : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _recordingHint() {
    final seconds = _recorded.inMilliseconds / 1000;
    final color = _recordCancelled ? AppTheme.muted : AppTheme.error;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          if (_recordCancelled)
            Icon(Icons.close_rounded, size: 15, color: color)
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.25),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _recordCancelled ? '已取消录音' : '正在录音',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _recordCancelled ? '松开取消' : '松开发送 · 上滑取消',
                  style: const TextStyle(fontSize: 9, color: AppTheme.muted),
                ),
              ],
            ),
          ),
          Text(
            '${seconds.toStringAsFixed(1)}s',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面端：Enter 发送，Shift+Enter 换行（Ctrl+V 由全局键盘监听处理）。
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (!_isDesktop) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (_input.value.composing.isValid) return KeyEventResult.ignored;
    if (_canSend && !_sending) {
      _send();
    }
    return KeyEventResult.handled;
  }
}
