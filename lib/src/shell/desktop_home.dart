import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:dsh_chat/src/core/api.dart';
import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/core/profile.dart';
import 'package:dsh_chat/src/core/theme.dart';
import '../chat/chat_screen.dart';
import '../settings/profile_dialog.dart';
import '../settings/settings_screen.dart';

/// 桌面端：会话列表 + 右侧聊天，青屿陪伴版的双栏布局。
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
  final _searchFocus = FocusNode();
  final Map<String, GlobalKey<ChatScreenState>> _chatKeys = {};
  List<Conversation> _items = const [];
  String? _selectedId;
  String _query = '';
  bool _loading = true;
  String? _error;
  bool _connected = false;
  int? _latency;
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _refreshTimer;
  Timer? _latencyTimer;

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
    _latencyTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _measureLatency(),
    );
    _load();
  }

  @override
  void dispose() {
    _latencyTimer?.cancel();
    widget.api.connected.removeListener(_onConnection);
    _events?.cancel();
    _refreshTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _measureLatency() async {
    final ms = await widget.api.measureLatency();
    if (mounted) setState(() => _latency = ms);
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
        if (_selectedId == null ||
            !items.any((item) => item.id == _selectedId)) {
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
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

  void _openProfile() {
    showDialog<void>(
      context: context,
      builder: (_) => ProfileDialog(api: widget.api),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          server: widget.server,
          token: widget.token,
          api: widget.api,
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  GlobalKey<ChatScreenState> _chatKey(String conversationId) {
    return _chatKeys.putIfAbsent(
      conversationId,
      () => GlobalKey<ChatScreenState>(),
    );
  }

  List<Conversation> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _items;
    return _items
        .where(
          (item) =>
              item.title.toLowerCase().contains(query) ||
              item.preview.toLowerCase().contains(query),
        )
        .toList();
  }

  Conversation? get _selected {
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  void _clearSearch() {
    _search.clear();
    if (_query.isNotEmpty) setState(() => _query = '');
    _searchFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          _searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
      },
      child: Focus(
        autofocus: true,
        child: QingyuBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Row(
              children: [
                SizedBox(width: 282, child: _listPane()),
                Expanded(
                  child: selected == null
                      ? _emptyPane()
                      : Container(
                          color: AppTheme.panel,
                          child: Column(
                            children: [
                              _chatHeader(selected),
                              Expanded(
                                child: ChatScreen(
                                  key: _chatKey(selected.id),
                                  api: widget.api,
                                  conversationId: selected.id,
                                  title: selected.title,
                                  embedded: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _listPane() {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.panelAlt,
        border: Border(right: BorderSide(color: AppTheme.line)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: AppProfile.instance,
                  builder: (context, _) => UserAvatar(
                    name: AppProfile.instance.displayName,
                    size: 34,
                    image: AppProfile.instance.avatarImage,
                    onTap: _openProfile,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'YOUR SPACE',
                        style: TextStyle(
                          fontSize: 8,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.muted,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '消息',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.text,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '设置',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  onPressed: _openSettings,
                  icon: const Icon(
                    Icons.settings_outlined,
                    size: 18,
                    color: AppTheme.muted,
                  ),
                ),
                const SizedBox(width: 4),
                Material(
                  color: AppTheme.accent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _create,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                          SizedBox(width: 3),
                          Text(
                            '新对话',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: '搜索会话',
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: AppTheme.muted,
                ),
                suffixIcon: const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Align(
                    alignment: Alignment.centerRight,
                    widthFactor: 1,
                    child: Text(
                      'Ctrl K',
                      style: TextStyle(fontSize: 9, color: AppTheme.muted),
                    ),
                  ),
                ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Row(
              children: [
                const Text(
                  '最近会话',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.muted,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_filtered.length}',
                  style: const TextStyle(fontSize: 9, color: AppTheme.muted),
                ),
              ],
            ),
          ),
          Expanded(child: _conversationList()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 7,
                  color: _connected ? const Color(0xFF3DD68C) : AppTheme.muted,
                ),
                const SizedBox(width: 6),
                Text(
                  _connected
                      ? (_latency == null ? '在线' : '在线 · $_latency ms')
                      : '连接中…',
                  style: const TextStyle(fontSize: 11, color: AppTheme.muted),
                ),
                const Spacer(),
                const Text(
                  '青屿',
                  style: TextStyle(fontSize: 11, color: AppTheme.muted),
                ),
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
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.error, fontSize: 12),
              ),
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
        child: Text(
          '还没有对话，点上方「新对话」开一个',
          style: TextStyle(color: AppTheme.muted, fontSize: 12),
        ),
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
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _timeText(conversation.updatedAt),
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.muted,
                        ),
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
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.muted,
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(
                          Icons.more_horiz_rounded,
                          color: AppTheme.muted,
                        ),
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
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return DateFormat('HH:mm').format(time);
    }
    if (time.year == now.year) return DateFormat('MM/dd').format(time);
    return DateFormat('yyyy/MM/dd').format(time);
  }

  Widget _chatHeader(Conversation conversation) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
      decoration: const BoxDecoration(
        color: AppTheme.panel,
        border: Border(bottom: BorderSide(color: AppTheme.line)),
      ),
      child: Row(
        children: [
          AvatarBadge(name: conversation.title, size: 36),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        conversation.title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text(
                        'AI',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.accent,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 6,
                      color: _connected
                          ? const Color(0xFF3DAE7E)
                          : AppTheme.muted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _connected ? '在呢，随时聊' : '连接中…',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppTheme.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '搜索聊天',
            onPressed: () {
              final state = _chatKeys[conversation.id]?.currentState;
              if (state != null) {
                state.openMessageSearch();
              }
            },
            icon: const Icon(
              Icons.search_rounded,
              size: 19,
              color: AppTheme.muted,
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(
              Icons.refresh_rounded,
              size: 19,
              color: AppTheme.muted,
            ),
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
          Text(
            '选一个对话，或者点左上角「新对话」',
            style: TextStyle(color: AppTheme.muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
