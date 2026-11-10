import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/api.dart';
import 'src/screens/connect_screen.dart';
import 'src/screens/conversations_screen.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '聊天',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const _Boot(),
    );
  }
}

/// 读上次的连接信息：有就直接进列表，没有就去填。
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  final _prefs = SharedPreferences.getInstance();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: _prefs,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final prefs = snapshot.data!;
        final server = prefs.getString('server') ?? '';
        final token = prefs.getString('token') ?? '';
        if (server.isEmpty || token.isEmpty) {
          return const ConnectScreen();
        }
        return ConversationsScreen(
          api: ChatApi(baseUrl: server, token: token),
          server: server,
          token: token,
        );
      },
    );
  }
}

/// 断开重连时回填的表单数据。
class Connection {
  const Connection({required this.server, required this.token});
  final String server;
  final String token;
}
