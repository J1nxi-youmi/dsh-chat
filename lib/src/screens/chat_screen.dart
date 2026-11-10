import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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
  StreamSubscription<Map<String, dynamic>>? _events;
  bool _sending = false;
  bool _recording = false;
  String? _recordingPath;
  DateTime? _recordStarted;
  Timer? _ticker;
  Duration _recorded = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _events = widget.api.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _events?.cancel();
    _ticker?.cancel();
    _recorder.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final conversation = await widget.api.conversation(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _messages = conversation.messages;
        _error = null;
      });
      _jumpToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] != 'message') return;
    if (event['conversationId'] != widget.conversationId) return;
    final raw = event['message'];
    if (raw is! Map<String, dynamic>) return;
    final message = Message.fromJson(raw);
    if (_messages.any((item) => item.id == message.id)) return;
    setState(() => _messages = [..._messages, message]);
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
      final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
      if (result == null) return;
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
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
      _recordingPath = path;
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
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    setState(() => _sending = true);
    try {
      final result = await widget.api.sendMessage(
        widget.conversationId,
        text: text,
        attachmentIds: _pending.map((item) => item.id).toList(),
      );
      if (!mounted) return;
      setState(() {
        _input.clear();
        _pending.clear();
        _messages = [..._messages, result.user, ...result.replies];
      });
      _jumpToBottom();
    } catch (error) {
      _toast(error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
            Expanded(child: _messageList()),
            if (_pending.isNotEmpty) _pendingBar(),
            _composer(),
          ],
        ),
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
      itemCount: _messages.length + (_sending ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _messages.length) return const TypingRow();
        return MessageBubble(
          message: _messages[index],
          mediaUrl: widget.api.mediaUrl,
        );
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
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
