import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../models.dart';
import '../profile.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// 桌面端：左边图标栏 + 会话列表 + 右边聊天，QQ / 星伴那种三栏。
class DesktopHome extends StatefulWidget {
  const DesktopHome({
    super.key,
    required this.api,
    required this.server,
    required this.token,
  });

  final ChatApi api;
  final String server;
  final String token;

  @override
  State<DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends State<DesktopHome> {
  final _search = TextEditingController();
  List<Conversation> _items = const [];
  String? _selectedId;
  String _query = '';
  bool _loading = true;
  String? _error;
  bool _connected = false;
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _connected = widget.api.connected.value;
    widget.api.connected.addListener(_onConnection);
    // 收到任何消息都让列表（预览/时间）跟着更新，抖一下再刷。
    _events = widget.api.events.listen((event) {
      if (event['type'] != 'message') return;
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 600), _load);
    });
    _load();
  }

  @override
  void dispose() {
    widget.api.connected.removeListener(_onConnection);
    _events?.cancel();
    _refreshTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onConnection() {
    if (mounted) setState(() => _connected = widget.api.connected.value);
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.conversations();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
        if (_selectedId == null || !items.any((item) => item.id == _selectedId)) {
          _selectedId = items.isNotEmpty ? items.first.id : null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    try {
      final conversation = await widget.api.createConversation();
      if (!mounted) return;
      setState(() => _selectedId = conversation.id);
      await _load();
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _delete(Conversation conversation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: const Text('删除对话'),
        content: Text('「${conversation.title}」会一起从 DSH 里删掉。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteConversation(conversation.id);
      await _load();
    } catch (error) {
      _toast(error.toString());
    }
  }

  ImageProvider? _avatarImage(AppProfile profile) {
    final path = profile.avatarPath;
    if (path == null || !File(path).existsSync()) return null;
    return FileImage(File(path));
  }

  void _openProfile() {
    showDialog<void>(context: context, builder: (_) => const _ProfileDialog());
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(server: widget.server, token: widget.token),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  List<Conversation> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _items;
    return _items
        .where((item) =>
            item.title.toLowerCase().contains(query) ||
            item.preview.toLowerCase().contains(query))
        .toList();
  }

  Conversation? get _selected {
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Row(
        children: [
          _rail(),
          Container(width: 1, color: AppTheme.line),
          SizedBox(width: 300, child: _listPane()),
          Container(width: 1, color: AppTheme.line),
          Expanded(
            child: selected == null
                ? _emptyPane()
                : Column(
                    children: [
                      _chatHeader(selected),
                      Container(height: 1, color: AppTheme.line),
                      Expanded(
                        child: ChatScreen(
                          key: ValueKey(selected.id),
                          api: widget.api,
                          conversationId: selected.id,
                          title: selected.title,
                          embedded: true,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _rail() {
    return Container(
      width: 62,
      color: AppTheme.panel,
      child: Column(
        children: [
          const SizedBox(height: 18),
          AnimatedBuilder(
            animation: AppProfile.instance,
            builder: (context, _) {
              final profile = AppProfile.instance;
              return AvatarBadge(
                name: profile.displayName,
                size: 36,
                image: _avatarImage(profile),
                onTap: _openProfile,
              );
            },
          ),
          const SizedBox(height: 22),
          _railButton(Icons.chat_bubble_rounded, '消息', selected: true),
          const Spacer(),
          _railButton(Icons.settings_rounded, '设置', onTap: _openSettings),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _railButton(IconData icon, String tooltip, {bool selected = false, VoidCallback? onTap}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: selected ? AppTheme.accent.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            size: 21,
            color: selected ? AppTheme.accent : AppTheme.muted,
          ),
        ),
      ),
    );
  }

  Widget _listPane() {
    return Container(
      color: AppTheme.panel,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 12, 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text('消息',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  tooltip: '新对话',
                  onPressed: _create,
                  icon: const Icon(Icons.add_rounded, size: 22, color: AppTheme.muted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: '搜索会话',
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppTheme.muted),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.accent),
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Expanded(child: _conversationList()),
          Container(
            height: 1,
            color: AppTheme.line,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.circle, size: 7, color: _connected ? const Color(0xFF3DD68C) : AppTheme.muted),
                const SizedBox(width: 6),
                Text(
                  _connected ? '在线 · 直连' : '连接中…',
                  style: const TextStyle(fontSize: 11, color: AppTheme.muted),
                ),
                const Spacer(),
                const Text('dsh-chat', style: TextStyle(fontSize: 11, color: AppTheme.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _conversationList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.error, fontSize: 12)),
              const SizedBox(height: 10),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final items = _filtered;
    if (items.isEmpty) {
      return const Center(
        child: Text('还没有对话，点右上角 + 开一个',
            style: TextStyle(color: AppTheme.muted, fontSize: 12)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: items.length,
      itemBuilder: (context, index) => _tile(items[index]),
    );
  }

  Widget _tile(Conversation conversation) {
    final selected = conversation.id == _selectedId;
    return InkWell(
      onTap: () => setState(() => _selectedId = conversation.id),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accent.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            AvatarBadge(name: conversation.title, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        _timeText(conversation.updatedAt),
                        style: const TextStyle(fontSize: 10.5, color: AppTheme.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.lastRole == 'user'
                              ? '我：${conversation.preview}'
                              : conversation.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.muted),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.more_horiz_rounded, color: AppTheme.muted),
                        onSelected: (value) {
                          if (value == 'delete') _delete(conversation);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'delete', child: Text('删除对话')),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeText(DateTime time) {
    final now = DateTime.now();
    if (time.year == now.year && time.month == now.month && time.day == now.day) {
      return DateFormat('HH:mm').format(time);
    }
    if (time.year == now.year) return DateFormat('MM/dd').format(time);
    return DateFormat('yyyy/MM/dd').format(time);
  }

  Widget _chatHeader(Conversation conversation) {
    return Container(
      color: AppTheme.panel,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          AvatarBadge(name: conversation.title, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 6,
                      color: _connected ? const Color(0xFF3DD68C) : AppTheme.muted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _connected ? '在线 · 本地直连' : '连接中…',
                      style: const TextStyle(fontSize: 11, color: AppTheme.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 19, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  Widget _emptyPane() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 42, color: AppTheme.muted),
          SizedBox(height: 12),
          Text('选一个对话，或者点右上角 + 开一个',
              style: TextStyle(color: AppTheme.muted, fontSize: 13)),
        ],
      ),
    );
  }
}

/// 「我的资料」：点头像换图、改昵称，只保存在这台设备上。
class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog();

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final TextEditingController _name =
      TextEditingController(text: AppProfile.instance.nickname);
  ImageProvider? _image;

  @override
  void initState() {
    super.initState();
    final path = AppProfile.instance.avatarPath;
    if (path != null && File(path).existsSync()) _image = FileImage(File(path));
  }

  Future<void> _pick() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result.isEmpty ? null : result.first.path;
    if (path == null) return;
    await AppProfile.instance.setAvatarFromFile(path);
    if (!mounted) return;
    setState(() => _image = FileImage(File(AppProfile.instance.avatarPath!)));
  }

  Future<void> _reset() async {
    await AppProfile.instance.resetAvatar();
    if (!mounted) return;
    setState(() => _image = null);
  }

  Future<void> _save() async {
    await AppProfile.instance.save(nickname: _name.text);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      title: const Text('我的资料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: GestureDetector(
              onTap: _pick,
              child: AvatarBadge(name: _name.text, size: 88, image: _image),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text(
              '点头像换一张图片',
              style: TextStyle(fontSize: 11, color: AppTheme.muted),
            ),
          ),
          const SizedBox(height: 14),
          const Text('我的昵称', style: TextStyle(fontSize: 12, color: AppTheme.muted)),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '昵称和头像会保存在这台设备上，换设备需要重新设置。',
            style: TextStyle(fontSize: 11, color: AppTheme.muted),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _reset, child: const Text('恢复默认头像')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存资料')),
      ],
    );
  }
}
