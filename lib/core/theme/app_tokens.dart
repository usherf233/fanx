import 'package:flutter/material.dart';

/// 设计令牌：颜色、间距、圆角、字体族集中在这里。
///
/// 视觉方向是「工业仪表盘」：暖调近黑底、发丝边框、单一琥珀橙强调色。
/// 组件里禁止硬编码色值，一律走 `context.tokens`。
@immutable
class FanxTokens extends ThemeExtension<FanxTokens> {
  const FanxTokens({
    required this.isDark,
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.accentWash,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final bool isDark;

  /// 页面底色。
  final Color bg;

  /// 面板/卡片底色。
  final Color surface;

  /// 悬浮或选中态的抬升底色。
  final Color surfaceRaised;

  /// 输入框、代码块等下沉底色。
  final Color surfaceSunken;

  /// 发丝分隔线。
  final Color border;

  /// 强调边框（悬停、聚焦）。
  final Color borderStrong;

  final Color text;
  final Color textMuted;
  final Color textFaint;

  /// 全局唯一强调色，只给关键动作与当前态。
  final Color accent;
  final Color onAccent;

  /// 强调色的极淡填充，用于选中块。
  final Color accentWash;

  final Color success;
  final Color warning;
  final Color danger;

  static const dark = FanxTokens(
    isDark: true,
    bg: Color(0xFF0E0E0F),
    surface: Color(0xFF161618),
    surfaceRaised: Color(0xFF1F1F22),
    surfaceSunken: Color(0xFF08080A),
    border: Color(0xFF2A2A2E),
    borderStrong: Color(0xFF3D3D43),
    text: Color(0xFFF3F0EA),
    textMuted: Color(0xFF93908A),
    textFaint: Color(0xFF615F5B),
    accent: Color(0xFFF4713A),
    onAccent: Color(0xFF1A0B04),
    accentWash: Color(0x1FF4713A),
    success: Color(0xFF4CC38A),
    warning: Color(0xFFE2B23C),
    danger: Color(0xFFE5484D),
  );

  static const light = FanxTokens(
    isDark: false,
    bg: Color(0xFFF5F3EE),
    surface: Color(0xFFFCFBF8),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFEDEAE3),
    border: Color(0xFFDDD8CD),
    borderStrong: Color(0xFFBFB9AC),
    text: Color(0xFF14130F),
    textMuted: Color(0xFF6B6862),
    textFaint: Color(0xFF9B968C),
    accent: Color(0xFFC8480C),
    onAccent: Color(0xFFFFF8F3),
    accentWash: Color(0x1FC8480C),
    success: Color(0xFF1F7A4D),
    warning: Color(0xFF9A6B0B),
    danger: Color(0xFFB3261E),
  );

  @override
  FanxTokens copyWith({
    bool? isDark,
    Color? bg,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? textMuted,
    Color? textFaint,
    Color? accent,
    Color? onAccent,
    Color? accentWash,
    Color? success,
    Color? warning,
    Color? danger,
  }) {
    return FanxTokens(
      isDark: isDark ?? this.isDark,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      textFaint: textFaint ?? this.textFaint,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentWash: accentWash ?? this.accentWash,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  FanxTokens lerp(ThemeExtension<FanxTokens>? other, double t) {
    if (other is! FanxTokens) return this;
    return FanxTokens(
      isDark: t < 0.5 ? isDark : other.isDark,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentWash: Color.lerp(accentWash, other.accentWash, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// 间距梯度。所有 padding / gap 只取这几个值。
abstract final class FanxSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;
  static const double giant = 64;
}

/// 圆角：工业方向偏小，不用胶囊与大圆角。
abstract final class FanxRadius {
  static const double xs = 3;
  static const double sm = 5;
  static const double md = 8;
  static const double lg = 12;
}

/// 字体族。GoogleFonts 在首次调用时注册这些 family 名，
/// 之后组件里直接用字符串即可（无需再触发字体加载逻辑）。
/// 中文由系统字体回落，无需单独打包。
abstract final class FanxFonts {
  /// 展示字：Archivo —— 工业感的几何无衬线。
  static const String display = 'Archivo';

  /// 正文字：IBM Plex Sans。
  static const String body = 'IBMPlexSans';

  /// 等宽字：IBM Plex Mono —— 用于编号、路径、ID、时间、指标。
  static const String mono = 'IBMPlexMono';

  /// 中文回落链，保证中英文混排不下坠到奇怪字形。
  static const List<String> fallback = <String>[
    'Microsoft YaHei UI',
    'PingFang SC',
    'Noto Sans SC',
    'Segoe UI',
  ];

  static const List<String> monoFallback = <String>[
    'Consolas',
    'Cascadia Mono',
    'Menlo',
    'monospace',
  ];
}

/// 动效时长。
abstract final class FanxMotion {
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 520);

  /// 出场缓动，与 skill 基准一致。
  static const Curve out = Cubic(0.16, 1, 0.3, 1);
}

extension FanxTokensX on BuildContext {
  FanxTokens get tokens =>
      Theme.of(this).extension<FanxTokens>() ?? FanxTokens.dark;

  TextTheme get texts => Theme.of(this).textTheme;

  /// 小号全大写等宽标签，贯穿全站的"仪表盘"语言。
  TextStyle monoLabel({
    Color? color,
    double size = 10.5,
    double tracking = 1.4,
  }) {
    return TextStyle(
      fontFamily: FanxFonts.mono,
      fontFamilyFallback: FanxFonts.monoFallback,
      fontSize: size,
      letterSpacing: tracking,
      fontWeight: FontWeight.w500,
      color: color ?? tokens.textMuted,
      height: 1.2,
    );
  }

  /// 中文大标题：Archivo 没有中文字形，回落后会带负字距显得拥挤，
  /// 所以中文标题单独用一套不压缩字距的样式。
  TextStyle cnDisplay({
    double size = 34,
    FontWeight weight = FontWeight.w700,
    double height = 1.28,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: FanxFonts.body,
      fontFamilyFallback: FanxFonts.fallback,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0.5,
      height: height,
      color: color ?? tokens.text,
    );
  }

  /// 数据/编号/路径统一用等宽。
  TextStyle mono({double size = 12, Color? color, FontWeight? weight}) {
    return TextStyle(
      fontFamily: FanxFonts.mono,
      fontFamilyFallback: FanxFonts.monoFallback,
      fontSize: size,
      fontWeight: weight ?? FontWeight.w400,
      color: color ?? tokens.text,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.5,
    );
  }
}
