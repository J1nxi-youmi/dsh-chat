import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.api,
    required this.conversationId,
    required this.title,
  });

  final ChatApi api;
  final String conversationId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();

  List<Message> _messages = const [];
  final List<Attachment> _pending = [];
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
    _connected = widget.api.connected.value;
    widget.api.connected.addListener(_onConnection);
    _input.addListener(_onInputChanged);
    _loadOutbox();
    _load();
    _events = widget.api.events.listen(_onEvent);
  }

  @override
  void dispose() {
    widget.api.connected.removeListener(_onConnection);
    _input.removeListener(_onInputChanged);
    _events?.cancel();
    _ticker?.cancel();
    _recorder.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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
        _lastSeq = _messages.fold(0, (max, item) => item.seq > max ? item.seq : max);
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
      final fresh = await widget.api.messagesSince(widget.conversationId, _lastSeq);
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
    _messages = [..._messages, message]..sort((left, right) => left.seq.compareTo(right.seq));
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

  Future<void> _pickFiles() async {
    try {
      // file_picker 13.x：pickFiles 直接返回 List<PlatformFile>（多选默认开），
      // 字节要自己 readAsBytes()，没有 withData 参数了。
      final files = await FilePicker.pickFiles();
      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (bytes.length > 12 * 1024 * 1024) {
          _toast('${file.name} 超过 12MB');
          continue;
        }
        final mime = _guessMime(file.name);
        final isImage = mime.startsWith('image/');
        final attachment = await widget.api.upload(
          name: file.name,
          mime: mime,
          bytes: bytes,
          kind: isImage ? 'image' : 'file',
          textPreview: _isText(file.name) ? String.fromCharCodes(bytes.take(4000)) : null,
        );
        if (!mounted) return;
        setState(() => _pending.add(attachment));
      }
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopRecording();
      return;
    }
    if (!await _recorder.hasPermission()) {
      _toast('没有麦克风权限');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
      path: path,
    );
    setState(() {
      _recording = true;
      _recordStarted = DateTime.now();
      _recorded = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _recordStarted == null) return;
      setState(() => _recorded = DateTime.now().difference(_recordStarted!));
    });
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    _ticker?.cancel();
    final duration = _recorded.inMilliseconds / 1000;
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recorded = Duration.zero;
    });
    if (path == null || duration < 0.5) {
      _toast('太短了，再说长一点');
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
      setState(() => _pending.add(attachment));
      await _send();
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    final item = Outgoing(
      clientMessageId: _newClientId(),
      text: text,
      attachments: _pending.toList(),
      at: DateTime.now(),
    );
    _input.clear();
    setState(() {
      _pending.clear();
      _outbox.add(item);
    });
    await _saveOutbox();
    await _deliver(item);
    if (mounted) setState(() {});
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
        attachmentIds: item.attachments.map((attachment) => attachment.id).toList(),
        clientMessageId: item.clientMessageId,
      );
      _outbox.removeWhere((entry) => entry.clientMessageId == item.clientMessageId);
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
        if (!_outbox.any((entry) => entry.clientMessageId == item.clientMessageId)) continue;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _guessMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.txt') || lower.endsWith('.md') || lower.endsWith('.json')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  bool _isText(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.txt') || lower.endsWith('.md') || lower.endsWith('.json') ||
        lower.endsWith('.csv') || lower.endsWith('.log');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: StarryBackground(
        child: Column(
          children: [
            if (!_connected) _connectionBanner(),
            Expanded(child: _messageList()),
            if (_pending.isNotEmpty) _pendingBar(),
            _composer(),
          ],
        ),
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
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFE8B93E)),
          ),
          SizedBox(width: 8),
          Text('连接中断，正在重连…', style: TextStyle(fontSize: 12, color: Color(0xFFE8B93E))),
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
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
      itemCount: _messages.length + _outbox.length + (_sending ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _messages.length) {
          return MessageBubble(
            message: _messages[index],
            mediaUrl: widget.api.mediaUrl,
          );
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
    );
  }

  Widget _pendingBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: AppTheme.panel,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _pending.map((attachment) {
          return Chip(
            backgroundColor: AppTheme.panelAlt,
            label: Text(
              attachment.isVoice
                  ? '🎙️ ${attachment.duration.toStringAsFixed(1)}s'
                  : attachment.isImage
                      ? '🖼️ ${attachment.name}'
                      : '📎 ${attachment.name}',
              style: const TextStyle(fontSize: 12),
            ),
            onDeleted: () => setState(() => _pending.remove(attachment)),
          );
        }).toList(),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.panel,
          border: Border(top: BorderSide(color: AppTheme.line)),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            RoundButton(icon: Icons.attach_file_rounded, onPressed: _pickFiles),
            const SizedBox(width: 6),
            RoundButton(
              icon: _recording ? Icons.stop_rounded : Icons.mic_none_rounded,
              color: _recording ? AppTheme.error : null,
              onPressed: _toggleRecording,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _recording ? '录音中 ${_recorded.inSeconds}s…' : '说点什么…',
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            RoundButton(
              icon: Icons.arrow_upward_rounded,
              color: AppTheme.accent,
              onPressed: _sending || !_canSend ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
