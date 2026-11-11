import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的资料」：昵称 + 自定义头像，只保存在这台设备上。
class AppProfile extends ChangeNotifier {
  AppProfile._();
  static final AppProfile instance = AppProfile._();

  static const _keyNickname = 'profile.nickname';
  static const _keyAvatar = 'profile.avatar';

  String _nickname = '';
  String? _avatarPath;
  bool _loaded = false;

  String get nickname => _nickname;
  String? get avatarPath => _avatarPath;

  /// 显示名：没填昵称就用「我」。
  String get displayName => _nickname.trim().isEmpty ? '我' : _nickname.trim();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _nickname = prefs.getString(_keyNickname) ?? '';
    _avatarPath = prefs.getString(_keyAvatar);
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
  }
}
