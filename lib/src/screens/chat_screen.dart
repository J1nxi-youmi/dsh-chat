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
import '../theme.dart';
import '../widgets/message_bubble.dart';

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
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
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
      color: AppTheme.panelAlt,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('正在上传…', style: TextStyle(fontSize: 12, color: AppTheme.muted)),
        ],
      ),
    );
  }

  Widget _connectionBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3A2E12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFE8B93E),
            ),
          ),
          SizedBox(width: 8),
          Text(
            '连接中断，正在重连…',
            style: TextStyle(fontSize: 12, color: Color(0xFFE8B93E)),
          ),
        ],
      ),
    );
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
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
          itemCount: _messages.length + _outbox.length + (_sending ? 1 : 0),
          itemBuilder: (context, index) {
            if (index < _messages.length) {
              final message = _messages[index];
              final bubble = MessageBubble(
                message: message,
                mediaUrl: widget.api.mediaUrl,
              );
              // 跨天或隔了 5 分钟以上，插一条时间分隔。
              return _needsDivider(index)
                  ? Column(children: [_timeDivider(message.at), bubble])
                  : bubble;
            }
            final outboxIndex = index - _messages.length;
            if (outboxIndex < _outbox.length) {
              final item = _outbox[outboxIndex];
              return MessageBubble(
                message: item.asMessage(),
                mediaUrl: widget.api.mediaUrl,
                status: item.status,
                onRetry: item.status == 'failed' ? () => _retry(item) : null,
              );
            }
            return const TypingRow();
          },
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
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _pending.map((item) {
          final isImage = item.isImage;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: isImage ? 64 : null,
                height: isImage ? 64 : null,
                padding: isImage
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.panelAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.line),
                  image: isImage && item.bytes != null
                      ? DecorationImage(
                          image: Image.memory(
                            item.bytes!,
                            fit: BoxFit.cover,
                          ).image,
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                alignment: Alignment.center,
                child: isImage
                    ? (item.bytes == null
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const SizedBox.shrink())
                    : Text(
                        item.isVoice ? '🎙️ 语音' : '📎 ${item.name}',
                        style: const TextStyle(fontSize: 12),
                      ),
              ),
              if (!item.ready)
                const Positioned(
                  left: 4,
                  bottom: 4,
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Positioned(
                right: -6,
                top: -6,
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
        }).toList(),
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
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
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
    '🫶',
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
    '🫂',
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

  Future<void> _showEmojiPicker() async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.panel,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              GridView.count(
                crossAxisCount: 8,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  for (final e in _emojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.of(sheetContext).pop(e),
                      child: Center(
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (emoji != null) _insertEmoji(emoji);
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
    return Material(
      color: enabled ? AppTheme.accent : AppTheme.panelAlt,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: enabled ? _send : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _isDesktop ? 12 : 10,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isDesktop)
                Text(
                  '发送',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: enabled ? Colors.white : AppTheme.muted,
                  ),
                ),
              if (_isDesktop) const SizedBox(width: 4),
              Icon(
                _isDesktop ? Icons.send_rounded : Icons.arrow_upward_rounded,
                size: 14,
                color: enabled ? Colors.white : AppTheme.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recordingHint() {
    final seconds = _recorded.inMilliseconds / 1000;
    final color = _recordCancelled ? AppTheme.muted : AppTheme.error;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _recordCancelled ? Icons.close_rounded : Icons.graphic_eq_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Text(
              _recordCancelled
                  ? '松开取消'
                  : '录音中 ${seconds.toStringAsFixed(1)}s · 松开发送，上滑取消',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ],
        ),
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
