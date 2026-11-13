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

import '../api.dart';
import '../app_state.dart';
import '../image_utils.dart';
import '../models.dart';
import '../profile.dart';
import '../theme.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_search_dialog.dart';

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

class ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 长按录音的状态：按下的位置、是否已经上滑取消。
  Offset? _recordPointer;
  bool _recordCancelled = false;
  bool _recordStarting = false;
  bool _recordReleasedBeforeStart = false;
  bool _dragging = false;
  final int _uploading = 0;

  List<Message> _messages = const [];
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedMessageId;

  /// 待发送附件：先显示本地预览，上传在后台跑，点发送时若还没传完就等它。
  final List<_PendingItem> _pending = [];
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
    WidgetsBinding.instance.addObserver(this);
    activeConversationId.value = widget.conversationId;
    _connected = widget.api.connected.value;
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
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    if (activeConversationId.value == widget.conversationId) {
      activeConversationId.value = null;
    }
    widget.api.connected.removeListener(_onConnection);
    _input.removeListener(_onInputChanged);
    _events?.cancel();
    _ticker?.cancel();
    _recorder.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
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

  @override
  void didChangeMetrics() {
    // 键盘弹出/收起时可视高度变化，滚到底避免最新消息被输入框挡住。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToBottom();
    });
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
      if (!mounted) return;
      setState(() {
        _messages = conversation.messages;
        _lastSeq = _messages.fold(
          0,
          (max, item) => item.seq > max ? item.seq : max,
        );
        _error = null;
      });
      _jumpToBottom();
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
      setState(() {
        for (final message in fresh) {
          _merge(message);
        }
      });
      _jumpToBottom();
    } catch (_) {
      /* 下次重连再补 */
    }
  }

  /// 合并一条消息（去重、按 seq 保序、推进游标）。
  void _merge(Message message) {
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
    setState(() => _merge(message));
    _jumpToBottom();
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
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
    final item = _PendingItem(
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
          _PendingItem(
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
    final text = _input.text.trim();
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
      _pending.clear();
      _outbox.add(item);
    });
    await _saveOutbox();
    await _deliver(item);
    if (mounted) {
      setState(() {});
      _jumpToBottom();
    }
  }

  // ---------------------------------------------------------------- 未 ack 队列

  String get _outboxKey => 'chat.outbox.${widget.conversationId}';

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
      _jumpToBottom();
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
    await _deliver(item);
    if (mounted) setState(() {});
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
        if (_uploading > 0) _uploadBanner(),
        Expanded(child: _messageList()),
        _composer(),
      ],
    );
    // 桌面 embedded：背景由最外层（desktop_home）统一绘制，这里保持透明，
    // 避免两层星空叠出黑竖条；手机端自己画星空。
    final body = _isDesktop ? inner : StarryBackground(child: inner);
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

  Widget _uploadBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.05),
        border: Border(
          bottom: BorderSide(color: AppTheme.accent.withValues(alpha: 0.12)),
        ),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.accent,
            ),
          ),
          SizedBox(width: 8),
          Text('正在上传…', style: TextStyle(fontSize: 11, color: AppTheme.accent)),
        ],
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
    setState(() => _highlightedMessageId = target.id);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final targetContext = _messageKeys[target.id]?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.25,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && _highlightedMessageId == target.id) {
      setState(() => _highlightedMessageId = null);
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
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _isDesktop ? 780 : double.infinity,
        ),
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
          children: [
            for (var index = 0; index < _messages.length; index++)
              Container(
                key: _messageKeys.putIfAbsent(
                  _messages[index].id,
                  () => GlobalKey(),
                ),
                child: _needsDivider(index)
                    ? Column(
                        children: [
                          _timeDivider(_messages[index].at),
                          MessageBubble(
                            message: _messages[index],
                            mediaUrl: widget.api.mediaUrl,
                            highlighted:
                                _highlightedMessageId == _messages[index].id,
                          ),
                        ],
                      )
                    : MessageBubble(
                        message: _messages[index],
                        mediaUrl: widget.api.mediaUrl,
                        highlighted:
                            _highlightedMessageId == _messages[index].id,
                      ),
              ),
            for (final item in _outbox)
              MessageBubble(
                message: item.asMessage(),
                mediaUrl: widget.api.mediaUrl,
                status: item.status,
                onRetry: item.status == 'failed' ? () => _retry(item) : null,
              ),
            if (_sending) const TypingRow(),
          ],
        ),
      ),
    );
  }

  bool _needsDivider(int index) {
    if (index == 0) return true;
    final previous = _messages[index - 1].at;
    final current = _messages[index].at;
    if (previous.year != current.year ||
        previous.month != current.month ||
        previous.day != current.day) {
      return true;
    }
    return current.difference(previous).inMinutes >= 5;
  }

  Widget _timeDivider(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final String label;
    if (day == today) {
      label = '今天';
    } else if (day == today.subtract(const Duration(days: 1))) {
      label = '昨天';
    } else if (time.year == now.year) {
      label = '${time.month}月${time.day}日';
    } else {
      label = '${time.year}年${time.month}月${time.day}日';
    }
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.panelAlt.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$label $hhmm',
            style: const TextStyle(fontSize: 11, color: AppTheme.muted),
          ),
        ),
      ),
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
        children: _pending.map(_pendingTile).toList(),
      ),
    );
  }

  Widget _pendingTile(_PendingItem item) {
    if (item.isImage) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: AppTheme.panelAlt,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AppTheme.line),
              image: item.bytes == null
                  ? null
                  : DecorationImage(
                      image: Image.memory(item.bytes!, fit: BoxFit.cover).image,
                      fit: BoxFit.cover,
                    ),
            ),
            child: !item.ready
                ? Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          Positioned(
            right: -5,
            top: -5,
            child: GestureDetector(
              onTap: () => setState(() => _pending.remove(item)),
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppTheme.error,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final size = item.ready
        ? item.attachment!.sizeText
        : '${((item.bytes?.length ?? 0) / 1024).round().clamp(1, 9999)} KB';
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(8, 8, 7, 8),
      decoration: BoxDecoration(
        color: AppTheme.panelAlt,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              item.isVoice
                  ? Icons.mic_none_rounded
                  : Icons.insert_drive_file_outlined,
              size: 17,
              color: AppTheme.accent,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.isVoice ? '语音' : item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  item.ready ? size : '上传中… · $size',
                  style: const TextStyle(fontSize: 8, color: AppTheme.muted),
                ),
                if (!item.ready)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: const LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: AppTheme.line,
                        color: AppTheme.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _pending.remove(item)),
            child: const Icon(
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
                              fontSize: 15,
                              height: 1.45,
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

  static const _emojis = [
    '🙂',
    '😄',
    '😊',
    '🥰',
    '😌',
    '😴',
    '🤔',
    '😅',
    '😂',
    '🤗',
    '😎',
    '💛',
    '❤️',
    '✨',
    '🌙',
    '☀️',
    '🌿',
    '🍵',
    '🎵',
    '📷',
    '🎁',
    '🐱',
    '🐶',
    '🌸',
    '🍰',
    '🚀',
    '💪',
    '👏',
    '👍',
    '🙌',
    '🤝',
    '🌊',
  ];

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
    await _saveOutbox();
    await _deliver(item);
    if (mounted) {
      setState(() {});
      _jumpToBottom();
    }
  }

  Future<void> _showEmojiPicker() async {
    // 面板高度随窗口收缩，但内部保留滚动，避免小窗口截断最后一行。
    final panelHeight = (MediaQuery.sizeOf(context).height * 0.58)
        .clamp(260.0, 330.0)
        .toDouble();
    String? emoji;
    if (_isDesktop) {
      emoji = await showDialog<String>(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: AppTheme.panel,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppTheme.line),
          ),
          child: SizedBox(
            width: 360,
            height: panelHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '表情',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: AppTheme.muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: _emojiPanelContent(
                      dialogContext,
                      (value) => Navigator.of(dialogContext).pop(value),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      emoji = await showModalBottomSheet<String>(
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
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '表情',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _emojiPanelContent(
                          sheetContext,
                          (value) => Navigator.of(sheetContext).pop(value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (emoji != null) _insertEmoji(emoji);
  }

  Widget _emojiPanelContent(
    BuildContext panelContext,
    void Function(String) onEmoji,
  ) {
    return AnimatedBuilder(
      animation: AppProfile.instance,
      builder: (context, _) {
        final stickers = AppProfile.instance.stickers;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _emojiGrid(onEmoji),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text(
                  '我的表情包',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addStickers,
                  icon: const Icon(Icons.add_rounded, size: 15),
                  label: const Text('添加表情包', style: TextStyle(fontSize: 9)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            if (stickers.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.panelAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.line),
                ),
                child: const Text(
                  '还没有自定义表情包，添加后会自动同步到另一台设备。',
                  style: TextStyle(fontSize: 9, color: AppTheme.muted),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final sticker in stickers)
                    _stickerTile(panelContext, sticker),
                ],
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Widget _emojiGrid(void Function(String) onPick) {
    return GridView.count(
      crossAxisCount: 8,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 1,
      children: [
        for (final e in _emojis)
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () => onPick(e),
              child: Center(
                child: Text(e, style: const TextStyle(fontSize: 21)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _stickerTile(BuildContext panelContext, Attachment sticker) {
    return Material(
      color: AppTheme.panelAlt,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(panelContext).pop();
          unawaited(_sendSticker(sticker));
        },
        child: Container(
          width: 52,
          height: 52,
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              widget.api.mediaUrl(sticker.url),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                size: 20,
                color: AppTheme.muted,
              ),
            ),
          ),
        ),
      ),
    );
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
                  style: const TextStyle(fontSize: 8.5, color: AppTheme.muted),
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

/// 一条待发送附件：本地预览（bytes）+ 后台上传出来的 attachment。
class _PendingItem {
  _PendingItem({
    required this.name,
    required this.bytes,
    required this.isImage,
    required this.isVoice,
  });

  final String name;
  final Uint8List? bytes;
  final bool isImage;
  final bool isVoice;
  Attachment? attachment;

  bool get ready => attachment != null;
}
