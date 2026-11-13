import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_chat/src/core/api.dart';
import 'package:dsh_chat/src/core/session.dart';
import 'package:dsh_chat/src/core/theme.dart';
import 'conversations_screen.dart';
import 'desktop_home.dart';

/// 第一次打开：填要连的那台 DSH 上的聊天服务地址 + 令牌。
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    this.initialServer = '',
    this.initialToken = '',
  });

  final String initialServer;
  final String initialToken;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _server = TextEditingController(text: widget.initialServer);
  late final _token = TextEditingController(text: widget.initialToken);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final server = _server.text.trim().replaceAll(RegExp(r'/+$'), '');
    final token = _token.text.trim();
    if (server.isEmpty || token.isEmpty) {
      setState(() => _error = '地址和令牌都要填');
      return;
    }
    if (!server.startsWith('http://') && !server.startsWith('https://')) {
      setState(() => _error = '地址要以 http:// 或 https:// 开头');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ChatApi(baseUrl: server, token: token);
    try {
      await api.conversations();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server', server);
      await prefs.setString('token', token);
      // 换了一台 DSH：全局连接跟着换，SSE 和通知继续生效。
      Session.attach(api);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              Platform.isWindows || Platform.isLinux || Platform.isMacOS
              ? DesktopHome(api: api, server: server, token: token)
              : ConversationsScreen(api: api, server: server, token: token),
        ),
      );
    } catch (error) {
      api.dispose();
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: QingyuBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  decoration: BoxDecoration(
                    color: AppTheme.panel,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: AppTheme.line),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF25322E).withValues(alpha: 0.06),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.forum_rounded,
                        size: 52,
                        color: AppTheme.accent,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '连接一台 DSH',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '填那台机器上聊天服务的地址和令牌。\n在哪台设备上都一样：手机、电脑、树莓派。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.muted, height: 1.5),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          hintText: 'http://192.168.1.101:8792',
                          labelText: '服务器地址',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _token,
                        obscureText: true,
                        decoration: const InputDecoration(
                          hintText: '聊天服务的令牌',
                          labelText: '令牌',
                        ),
                        onSubmitted: (_) => _connect(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: AppTheme.error),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _connect,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('进入'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
