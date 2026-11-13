import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

import 'package:dsh_chat/src/core/models.dart';

/// 文件消息的复制、另存为、保存、打开。全部走真实下载，不做假按钮。
class ChatFileActions {
  static bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static String _safeName(String name) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return safe.isEmpty ? 'attachment' : safe;
  }

  static Future<Uint8List> _bytes(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw '下载失败（HTTP ${response.statusCode}）';
    }
    return response.bodyBytes;
  }

  static Future<File> _tempFile(String url, Attachment attachment) async {
    final data = await _bytes(url);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/qingyu-${DateTime.now().millisecondsSinceEpoch}-${_safeName(attachment.name)}',
    );
    await file.writeAsBytes(data, flush: true);
    return file;
  }

  static Future<String> copy(String url, Attachment attachment) async {
    if (!_desktop) {
      await Clipboard.setData(ClipboardData(text: url));
      return '已复制文件链接';
    }
    final file = await _tempFile(url, attachment);
    final ok = await Pasteboard.writeFiles([file.path]);
    return ok ? '已复制文件' : '复制文件失败';
  }

  static Future<String> saveAs(String url, Attachment attachment) async {
    final data = await _bytes(url);
    final uri = await FilePicker.saveFile(
      fileName: _safeName(attachment.name),
      bytes: data,
      mimeType: attachment.mime.isEmpty
          ? 'application/octet-stream'
          : attachment.mime,
    );
    if (uri == null) return '已取消保存';
    return '已另存为 ${uri.toString()}';
  }

  static Future<String> save(String url, Attachment attachment) async {
    final data = await _bytes(url);
    Directory? dir;
    if (Platform.isAndroid || Platform.isIOS) {
      dir = await getApplicationDocumentsDirectory();
    } else {
      dir = await getDownloadsDirectory();
    }
    dir ??= await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${_safeName(attachment.name)}');
    await file.writeAsBytes(data, flush: true);
    return '已保存到 ${file.path}';
  }

  static Future<String> open(String url, Attachment attachment) async {
    final file = await _tempFile(url, attachment);
    final result = await OpenFilex.open(file.path);
    return result.type == ResultType.done ? '已打开文件' : '打开失败：${result.message}';
  }

  static Future<String> openFolder(String url, Attachment attachment) async {
    if (!_desktop) return '手机端不支持打开文件夹';
    final file = await _tempFile(url, attachment);
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', file.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', file.path]);
    } else {
      await Process.run('xdg-open', [file.parent.path]);
    }
    return '已打开文件夹';
  }
}
