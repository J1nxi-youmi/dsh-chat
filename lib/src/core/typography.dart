import 'package:flutter/material.dart';

import 'theme.dart';

/// 全站字号只有这几档。
///
/// 以前每个页面各自写 `fontSize: 12.5 / 13.5 / 10.5 …`（全仓 118 处），
/// 想改一次正文字号得翻十几二十个文件——这次调字体来来回回改了好几版，
/// 就是被这个拖的。以后字号只从这里取，改一处就全站生效。
class AppText {
  /// 正文：消息气泡、输入框、正文段落。
  static const body = TextStyle(fontSize: 14, height: 1.5, color: AppTheme.text);

  /// 正文的次要版本（说明文字）。
  static const bodyMuted = TextStyle(fontSize: 14, height: 1.5, color: AppTheme.muted);

  /// 小一号的正文：引用、附件名。
  static const small = TextStyle(fontSize: 13, height: 1.45, color: AppTheme.text);

  /// 次要信息：会话预览、设置项描述。
  static const meta = TextStyle(fontSize: 12, height: 1.35, color: AppTheme.muted);

  /// 时间、角标、计数。
  static const caption = TextStyle(fontSize: 11, height: 1.3, color: AppTheme.muted);

  /// 会话标题、设置项标题。
  static const title = TextStyle(
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: AppTheme.text,
  );

  /// 页面内的大标题。
  static const heading = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: AppTheme.text,
  );

  /// 输入框里的字。
  static const input = TextStyle(fontSize: 14, height: 1.5, color: AppTheme.text);
}
