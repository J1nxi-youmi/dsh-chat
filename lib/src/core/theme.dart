import 'package:flutter/material.dart';

/// 青屿 · 陪伴版：暖白底、鼠尾草绿主色、轻盈留白。
/// 70% 日常闲聊 / 30% 远程协作，界面尽量安静，不抢对话内容。
class AppTheme {
  /// 页面底色（暖白）
  static const bg = Color(0xFFF3F1EC);

  /// 卡片 / 消息面板
  static const panel = Color(0xFFFDFDFC);

  /// 侧栏、次级面板
  static const panelAlt = Color(0xFFF5F5F1);

  /// 细边框
  static const line = Color(0xFFE1E4DC);

  /// 正文
  static const text = Color(0xFF25322E);

  /// 次要文字
  static const muted = Color(0xFF828B85);

  /// 主色：鼠尾草绿
  static const accent = Color(0xFF276A5B);
  static const accent2 = Color(0xFF77A998);

  /// 强调色（更新提示等）
  static const gold = Color(0xFFB8873F);

  /// 自己的消息气泡
  static const me = Color(0xFFE5EEE8);
  static const meBorder = Color(0xFFD9E4DC);

  /// 对方消息气泡
  static const bubble = Color(0xFFFFFFFF);
  static const bubbleBorder = Color(0xFFE1E4DC);

  static const error = Color(0xFFD65F5B);

  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accent2],
  );

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    // Windows 上 Flutter 只有灰度抗锯齿：96 DPI 下雅黑一个横画只有 1.4 个像素，
    // 细笔画会被摊成灰色，看起来又窄又虚。这里只给 Windows 换思源黑体 Medium
    // （pubspec 里声明成 NotoSansSC）；手机屏幕像素密度够，继续用系统字体。
    final desktopFont = defaultTargetPlatform == TargetPlatform.windows
        ? 'NotoSansSC'
        : null;
    final theme = base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: Colors.white,
        surface: panel,
        error: error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: text),
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panel,
        contentTextStyle: const TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        hintStyle: const TextStyle(color: muted),
        labelStyle: const TextStyle(color: muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: Color(0x33276A5B),
        selectionHandleColor: accent,
      ),
      dividerColor: line,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
    );
    if (desktopFont == null) return theme;
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: desktopFont),
    );
  }
}

/// 青屿背景：暖白到浅米色的柔和渐变，保留极淡的绿色光晕。
class QingyuBackground extends StatelessWidget {
  const QingyuBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.7, -1.0),
          radius: 1.15,
          colors: [Color(0xFFFBFCF8), AppTheme.bg],
          stops: [0, 0.72],
        ),
      ),
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// 统一的小圆按钮。
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.color,
    this.size = 42,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: color ?? AppTheme.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.32),
        side: const BorderSide(color: AppTheme.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(size * 0.32),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.46, color: AppTheme.text),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 带渐变的小头像占位（用名字首字），比纯色圆更有「角色感」。
/// 用户自己的头像。
/// 设置过自定义头像就显示图片；否则用暖珊瑚色 + 昵称首字，
/// 保证和左侧角色的默认头像明确区分。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.size = 46,
    this.image,
    this.onTap,
  });

  final String name;
  final double size;
  final ImageProvider? image;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '我' : name.substring(0, 1);
    final Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF2B193), Color(0xFFCE756B)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFCE756B).withValues(alpha: 0.18),
            blurRadius: 10,
          ),
        ],
      ),
      child: image != null
          ? Image(image: image!, fit: BoxFit.cover, width: size, height: size)
          : Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
    );
    if (onTap == null) return face;
    return GestureDetector(onTap: onTap, child: face);
  }
}

class AvatarBadge extends StatelessWidget {
  const AvatarBadge({
    super.key,
    required this.name,
    this.size = 46,
    this.image,
    this.onTap,
  });

  final String name;
  final double size;

  /// 自定义头像；为空时用内置的会话形象（assets/avatar.png）。
  final ImageProvider? image;

  /// 点头像（用于「我的资料」入口）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.substring(0, 1);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEDF2FF), Color(0xFFDDE6FA)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5A7194).withValues(alpha: 0.12),
            blurRadius: 10,
            spreadRadius: 0,
          ),
        ],
      ),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: _face(initial),
    );
  }

  Widget _face(String initial) {
    Widget face;
    if (image != null) {
      face = Image(image: image!, width: size, height: size, fit: BoxFit.cover);
    } else {
      face = Image.asset(
        'assets/avatar.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.42,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF455A7A),
          ),
        ),
      );
    }
    if (onTap == null) return face;
    return InkWell(onTap: onTap, child: face);
  }
}
