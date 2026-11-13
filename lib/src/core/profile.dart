import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

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
  static const _keyStickers = 'profile.stickers';

  String _nickname = '';
  String? _avatarPath;
  String _remoteNickname = '';
  String? _remoteUrl;
  List<Attachment> _stickers = const [];
  bool _loaded = false;

  String get nickname => _nickname;
  String? get avatarPath => _avatarPath;
  String? get remoteUrl => _remoteUrl;
  List<Attachment> get stickers => List.unmodifiable(_stickers);

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
    final rawStickers = prefs.getString(_keyStickers);
    if (rawStickers != null) {
      try {
        _stickers = (jsonDecode(rawStickers) as List)
            .whereType<Map<String, dynamic>>()
            .map(Attachment.fromJson)
            .toList();
      } catch (_) {
        _stickers = const [];
      }
    }
    notifyListeners();
  }

  Future<void> saveStickers(List<Attachment> stickers) async {
    _stickers = List.unmodifiable(stickers);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyStickers,
      jsonEncode(_stickers.map((item) => item.toJson()).toList()),
    );
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

  /// 把选中的图片统一转成 PNG 存进应用数据目录。
  /// 相册里很多图实际是 BMP/HEIC，直接按 .png 存会在部分端渲染失败。
  Future<void> setAvatarFromFile(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw '图片解码失败';
    final dir = await getApplicationSupportDirectory();
    final avatars = Directory('${dir.path}/avatars');
    await avatars.create(recursive: true);
    final target = File('${avatars.path}/self.png');
    await target.writeAsBytes(png.buffer.asUint8List(), flush: true);
    _avatarPath = target.path;
    await save();
  }

  Future<void> resetAvatar() async {
    _avatarPath = null;
    await save();
    notifyListeners();
  }

  /// 云端拉回来的资料（连接/收到 profile 事件时调用）。云端是权威：直接覆盖本地。
  Future<void> applyRemote({
    required String nickname,
    required String avatarUrl,
    List<Attachment>? stickers,
  }) async {
    _remoteNickname = nickname;
    if (nickname.trim().isNotEmpty) {
      _nickname = nickname.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyNickname, _nickname);
    }
    _remoteUrl = avatarUrl.isEmpty ? null : avatarUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyRemoteNickname, _remoteNickname);
    if (_remoteUrl == null) {
      await prefs.remove(_keyRemoteUrl);
    } else {
      await prefs.setString(_keyRemoteUrl, _remoteUrl!);
    }
    if (stickers != null) {
      _stickers = List.unmodifiable(stickers);
      await prefs.setString(
        _keyStickers,
        jsonEncode(_stickers.map((item) => item.toJson()).toList()),
      );
    }
    notifyListeners();
  }
}
