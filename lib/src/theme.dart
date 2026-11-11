import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 深空底色 + 星点，参考星伴的观感：暗、静、留白多。
class AppTheme {
  static const bg = Color(0xFF080A10);
  static const panel = Color(0xFF12151F);
  static const panelAlt = Color(0xFF1A1E2B);
  static const line = Color(0xFF262C3D);
  static const text = Color(0xFFEDEEF5);
  static const muted = Color(0xFF8B93A7);
  static const accent = Color(0xFF7C8CFF);
  static const accent2 = Color(0xFF4F8CFF);
  static const gold = Color(0xFFF0C987);
  static const me = Color(0xFF2B4BC7);
  static const error = Color(0xFFFF6B6B);

  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accent2],
  );

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        surface: panel,
        error: error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panelAlt,
        contentTextStyle: const TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel.withValues(alpha: 0.9),
        hintStyle: const TextStyle(color: muted),
        labelStyle: const TextStyle(color: muted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: accent),
        ),
      ),
      dividerColor: line.withValues(alpha: 0.6),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
    );
  }
}

/// 背景：一层暗色渐变 + 稀疏星点（固定种子，不会每次重绘乱闪）。
class StarryBackground extends StatelessWidget {
  const StarryBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.2, -0.9),
                radius: 1.1,
                colors: [
                  AppTheme.accent.withValues(alpha: 0.12),
                  AppTheme.bg,
                  const Color(0xFF05060A),
                ],
                stops: const [0, 0.55, 1],
              ),
            ),
          ),
        ),
        Positioned.fill(child: CustomPaint(painter: _StarPainter())),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}

class _StarPainter extends CustomPainter {
  static final List<Offset> _dots = () {
    final random = math.Random(20261111);
    return List.generate(90, (_) => Offset(random.nextDouble(), random.nextDouble()));
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var i = 0; i < _dots.length; i++) {
      final dot = _dots[i];
      final radius = i % 7 == 0 ? 1.4 : 0.9;
      paint.color = Colors.white.withValues(alpha: i % 7 == 0 ? 0.55 : 0.22);
      canvas.drawCircle(Offset(dot.dx * size.width, dot.dy * size.height), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
      color: color ?? AppTheme.panelAlt,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.5, color: AppTheme.text),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 带渐变的小头像占位（用名字首字），比纯色圆更有「角色感」。
class AvatarBadge extends StatelessWidget {
  const AvatarBadge({super.key, required this.name, this.size = 46});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.substring(0, 1);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppTheme.accentGradient,
        boxShadow: [
          BoxShadow(
            color: AppTheme.accent.withValues(alpha: 0.35),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
      ),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      // 统一的会话形象：assets/avatar.png；加载失败回退到首字。
      child: Image.asset(
        'assets/avatar.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.42,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
