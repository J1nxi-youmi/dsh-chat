import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'src/api.dart';
import 'src/notify.dart';
import 'src/screens/connect_screen.dart';
import 'src/screens/conversations_screen.dart';
import 'src/screens/desktop_home.dart';
import 'src/profile.dart';
import 'src/session.dart';
import 'src/theme.dart';

bool get _isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isDesktopPlatform) {
    await windowManager.ensureInitialized();
    // 初始窗口按 QQ 的大小来：够放下三栏，又不会一开就糊满屏幕。
    const options = WindowOptions(
      size: Size(980, 660),
      minimumSize: Size(780, 560),
      center: true,
      title: 'dsh-chat',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  // Windows 的系统通知、Android 的前台服务都在这里初始化。
  await Notifier.setup();
    // 先把「我的资料」读出来（昵称 + 自定义头像）。
  await AppProfile.instance.load();
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
  bool _attached = false;

  @override
  void dispose() {
    Session.dispose();
    super.dispose();
  }

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
        if (!_attached) {
          _attached = true;
          Session.attach(ChatApi(baseUrl: server, token: token));
        }
        // Windows / macOS / Linux 走三栏桌面布局，手机走原来的列表+聊天页。
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          return DesktopHome(api: Session.api!, server: server, token: token);
        }
        return ConversationsScreen(
          api: Session.api!,
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
