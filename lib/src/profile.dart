import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的资料」：昵称 + 头像。
/// 本地选的图存 avatarPath；云端的昵称/头像存 remoteNickname/remoteUrl，
/// 其它设备登录同一台 DSH 时自动同步。
class AppProfile extends ChangeNotifier {
  AppProfile._();
  static final AppProfile instance = AppProfile._();

  static const _keyNickname = 'profile.nickname';
  static const _keyAvatar = 'profile.avatar';
  static const _keyRemoteNickname = 'profile.remoteNickname';
  static const _keyRemoteUrl = 'profile.remoteUrl';

  String _nickname = '';
  String? _avatarPath;
  String _remoteNickname = '';
  String? _remoteUrl;
  bool _loaded = false;

  String get nickname => _nickname;
  String? get avatarPath => _avatarPath;
  String? get remoteUrl => _remoteUrl;

  /// 显示名：优先本地昵称，没填就用云端，再没有就是「我」。
  String get displayName {
    final local = _nickname.trim();
    if (local.isNotEmpty) return local;
    final remote = _remoteNickname.trim();
    if (remote.isNotEmpty) return remote;
    return '我';
  }

  /// 头像显示源：云端同步的 > 本地选的 > 内置形象（null 时走 AvatarBadge 的 asset）。
  ImageProvider? get avatarImage {
    final remote = _remoteUrl;
    if (remote != null && remote.isNotEmpty) return NetworkImage(remote);
    final path = _avatarPath;
    if (path != null && File(path).existsSync()) return FileImage(File(path));
    return null;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _nickname = prefs.getString(_keyNickname) ?? '';
    _avatarPath = prefs.getString(_keyAvatar);
    _remoteNickname = prefs.getString(_keyRemoteNickname) ?? '';
    _remoteUrl = prefs.getString(_keyRemoteUrl);
    notifyListeners();
  }

  Future<void> save({String? nickname}) async {
    if (nickname != null) _nickname = nickname.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyNickname, _nickname);
    if (_avatarPath == null) {
      await prefs.remove(_keyAvatar);
    } else {
      await prefs.setString(_keyAvatar, _avatarPath!);
    }
    notifyListeners();
  }

  /// 把选中的图片复制进应用数据目录，App 升级/换目录也不丢。
  Future<void> setAvatarFromFile(String sourcePath) async {
    final dir = await getApplicationSupportDirectory();
    final avatars = Directory('${dir.path}/avatars');
    await avatars.create(recursive: true);
    final target = File('${avatars.path}/self.png');
    await File(sourcePath).copy(target.path);
    _avatarPath = target.path;
    await save();
  }

  Future<void> resetAvatar() async {
    _avatarPath = null;
    await save();
    notifyListeners();
  }

  /// 云端拉回来的资料（连接 DSH 时调用）。
  Future<void> applyRemote({required String nickname, required String avatarUrl}) async {
    _remoteNickname = nickname;
    _remoteUrl = avatarUrl.isEmpty ? null : avatarUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyRemoteNickname, _remoteNickname);
    if (_remoteUrl == null) {
      await prefs.remove(_keyRemoteUrl);
    } else {
      await prefs.setString(_keyRemoteUrl, _remoteUrl!);
    }
    notifyListeners();
  }
}
