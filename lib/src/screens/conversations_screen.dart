import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../profile.dart';
import '../models.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'connect_screen.dart';
import 'profile_dialog.dart';
import 'settings_screen.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({
    super.key,
    required this.api,
    required this.server,
    required this.token,
  });

  final ChatApi api;
  final String server;
  final String token;

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation> _items = const [];
  bool _loading = true;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  int? _latency;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connected = widget.api.connected.value;
    widget.api.connected.addListener(_onConnection);
    _load();
  }

  void _onConnection() {
    if (!mounted) return;
    setState(() => _connected = widget.api.connected.value);
    if (_connected) unawaited(_measureLatency());
  }

  @override
  void dispose() {
    widget.api.connected.removeListener(_onConnection);
    _search.dispose();
    super.dispose();
  }

  Future<void> _measureLatency() async {
    final ms = await widget.api.measureLatency();
    if (mounted) setState(() => _latency = ms);
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.conversations();
      if (!mounted) return;
      unawaited(_measureLatency());
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    try {
      final conversation = await widget.api.createConversation();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            api: widget.api,
            conversationId: conversation.id,
            title: conversation.title,
          ),
        ),
      );
      _load();
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
      _load();
    } catch (error) {
      _toast(error.toString());
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            AnimatedBuilder(
              animation: AppProfile.instance,
              builder: (context, _) => GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => ProfileDialog(api: widget.api),
                ),
                child: AvatarBadge(
                  name: AppProfile.instance.displayName,
                  size: 34,
                  image: AppProfile.instance.avatarImage,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AnimatedBuilder(
                animation: AppProfile.instance,
                builder: (context, _) => Text(
                  AppProfile.instance.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(server: widget.server, token: widget.token, api: widget.api),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: StarryBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索会话',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppTheme.muted),
                  filled: true,
                  fillColor: AppTheme.panelAlt,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: _body(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 7, color: _connected ? const Color(0xFF3DD68C) : AppTheme.muted),
                  const SizedBox(width: 6),
                  Text(
                    _connected
                        ? (_latency == null ? '在线' : '在线 · $_latency ms')
                        : '连接中…',
                    style: const TextStyle(fontSize: 11, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        backgroundColor: AppTheme.accent,
        child: const Icon(Icons.add_comment_rounded),
      ),
    );
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

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.cloud_off_rounded, size: 42, color: AppTheme.muted),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.muted)),
          const SizedBox(height: 16),
          Center(
            child: FilledButton(onPressed: _load, child: const Text('重试')),
          ),
        ],
      );
    }
    if (_filtered.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          Icon(Icons.forum_outlined, size: 42, color: AppTheme.muted),
          SizedBox(height: 12),
          Text('还没有对话，点右下角开一个',
              textAlign: TextAlign.center, style: TextStyle(color: AppTheme.muted)),
        ],
      );
    }
    return ListView.separated(
      itemCount: _filtered.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, index) {
        final conversation = _filtered[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: AvatarBadge(name: conversation.title),
          title: Text(
            conversation.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            conversation.preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.muted, fontSize: 13),
          ),
          trailing: Text(
            _timeText(conversation.updatedAt),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  api: widget.api,
                  conversationId: conversation.id,
                  title: conversation.title,
                ),
              ),
            );
            _load();
          },
          onLongPress: () => _delete(conversation),
        );
      },
    );
  }

  String _timeText(DateTime time) {
    final now = DateTime.now();
    if (time.year == now.year && time.month == now.month && time.day == now.day) {
      return DateFormat('HH:mm').format(time);
    }
    return DateFormat('MM/dd').format(time);
  }
}
