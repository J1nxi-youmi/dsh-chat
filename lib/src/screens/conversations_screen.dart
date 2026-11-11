import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'connect_screen.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.conversations();
      if (!mounted) return;
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

  Future<void> _switchServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server');
    await prefs.remove('token');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ConnectScreen(
          initialServer: widget.server,
          initialToken: widget.token,
        ),
      ),
      (_) => false,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(server: widget.server, token: widget.token),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: '换一台 DSH',
            onPressed: _switchServer,
            icon: const Icon(Icons.dns_rounded),
          ),
        ],
      ),
      body: StarryBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _body(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        backgroundColor: AppTheme.accent,
        child: const Icon(Icons.add_comment_rounded),
      ),
    );
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
    if (_items.isEmpty) {
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
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, index) {
        final conversation = _items[index];
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
