import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_tokens.dart';

/// 全局主题：工业仪表盘方向。
///
/// 刻意不使用 `ColorScheme.fromSeed` —— 种子色推导会把所有表面拉成同一族蓝灰，
/// 正是"看起来像默认 Material"的根源。这里手工指定每一个语义色。
abstract final class AppTheme {
  static ThemeData get light => _build(FanxTokens.light);

  static ThemeData get dark => _build(FanxTokens.dark);

  static ThemeData _build(FanxTokens t) {
    final scheme = ColorScheme(
      brightness: t.isDark ? Brightness.dark : Brightness.light,
      primary: t.accent,
      onPrimary: t.onAccent,
      primaryContainer: t.accentWash,
      onPrimaryContainer: t.accent,
      secondary: t.text,
      onSecondary: t.bg,
      secondaryContainer: t.surfaceRaised,
      onSecondaryContainer: t.text,
      tertiary: t.success,
      onTertiary: t.bg,
      error: t.danger,
      onError: t.isDark ? const Color(0xFF1A0505) : Colors.white,
      errorContainer: t.danger.withValues(alpha: t.isDark ? 0.16 : 0.10),
      onErrorContainer: t.danger,
      surface: t.bg,
      onSurface: t.text,
      onSurfaceVariant: t.textMuted,
      surfaceContainerLowest: t.surfaceSunken,
      surfaceContainerLow: t.surface,
      surfaceContainer: t.surface,
      surfaceContainerHigh: t.surfaceRaised,
      surfaceContainerHighest: t.surfaceRaised,
      outline: t.borderStrong,
      outlineVariant: t.border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: t.text,
      onInverseSurface: t.bg,
      inversePrimary: t.onAccent,
      surfaceTint: Colors.transparent,
    );

    final text = _textTheme(t);

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      textTheme: text,
      primaryTextTheme: text,
      fontFamily: FanxFonts.body,
      fontFamilyFallback: FanxFonts.fallback,
      extensions: <ThemeExtension<dynamic>>[t],
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: t.border,

      // 桌面端不需要水波纹以外的过渡，统一交给组件自己的 AnimatedContainer。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        },
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: t.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: t.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleMedium,
      ),

      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),

      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: t.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.md),
          side: BorderSide(color: t.border),
        ),
      ),

      iconTheme: IconThemeData(color: t.textMuted, size: 18),

      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: t.isDark ? t.surfaceRaised : const Color(0xFF1A1A1C),
          borderRadius: BorderRadius.circular(FanxRadius.sm),
          border: Border.all(color: t.borderStrong),
        ),
        textStyle: TextStyle(
          fontFamily: FanxFonts.mono,
          fontSize: 11,
          height: 1.4,
          color: t.isDark ? t.text : const Color(0xFFF3F0EA),
        ),
      ),

      // 输入框：下沉底 + 发丝边框，聚焦时切琥珀描边。不用 Material 默认下划线。
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: t.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        hintStyle: text.bodyMedium?.copyWith(color: t.textFaint),
        labelStyle: text.bodySmall?.copyWith(color: t.textMuted),
        floatingLabelStyle: text.bodySmall?.copyWith(color: t.accent),
        helperStyle: text.bodySmall?.copyWith(
          color: t.textFaint,
          fontSize: 11.5,
        ),
        errorStyle: text.bodySmall?.copyWith(color: t.danger, fontSize: 11.5),
        prefixIconColor: t.textMuted,
        suffixIconColor: t.textMuted,
        border: _border(t.border),
        enabledBorder: _border(t.border),
        focusedBorder: _border(t.accent, width: 1.4),
        errorBorder: _border(t.danger),
        focusedErrorBorder: _border(t.danger, width: 1.4),
        disabledBorder: _border(t.border.withValues(alpha: 0.5)),
      ),

      // 主按钮：琥珀实底 + 近黑字，唯一的高饱和色块。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.surfaceRaised,
          disabledForegroundColor: t.textFaint,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          minimumSize: const Size(0, 38),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FanxRadius.sm),
          ),
        ),
      ),

      // 次按钮：透明底 + 发丝边框。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.text,
          backgroundColor: Colors.transparent,
          side: BorderSide(color: t.borderStrong),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          minimumSize: const Size(0, 38),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FanxRadius.sm),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.textMuted,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          minimumSize: const Size(0, 32),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FanxRadius.sm),
          ),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: t.textMuted,
          highlightColor: t.surfaceRaised,
          minimumSize: const Size(32, 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FanxRadius.sm),
          ),
        ),
      ),

      // Tab：无胶囊、无底色，只用一条 2px 琥珀下划线标记当前页。
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: t.accent, width: 2),
          insets: const EdgeInsets.only(bottom: 0),
        ),
        labelColor: t.text,
        unselectedLabelColor: t.textMuted,
        labelStyle: text.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
        unselectedLabelStyle: text.titleSmall?.copyWith(
          fontWeight: FontWeight.w400,
        ),
        overlayColor: WidgetStatePropertyAll(t.accentWash),
        splashBorderRadius: BorderRadius.circular(FanxRadius.sm),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: t.isDark ? t.surfaceRaised : t.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.md),
          side: BorderSide(color: t.borderStrong),
        ),
        textStyle: text.bodyMedium,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.lg),
          side: BorderSide(color: t.borderStrong),
        ),
        titleTextStyle: text.headlineSmall,
        contentTextStyle: text.bodyMedium,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: t.isDark ? t.surfaceRaised : const Color(0xFF1A1A1C),
        contentTextStyle: text.bodySmall?.copyWith(
          color: t.isDark ? t.text : const Color(0xFFF3F0EA),
        ),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.sm),
          side: BorderSide(color: t.borderStrong),
        ),
        insetPadding: const EdgeInsets.all(FanxSpace.lg),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.onAccent;
          return t.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.surfaceSunken;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.borderStrong;
        }),
        trackOutlineWidth: const WidgetStatePropertyAll(1),
      ),

      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: t.borderStrong, width: 1.2),
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return Colors.transparent;
        }),
        checkColor: WidgetStatePropertyAll(t.onAccent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.xs),
        ),
        visualDensity: VisualDensity.compact,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.surfaceRaised,
        circularTrackColor: t.surfaceRaised,
      ),

      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(7),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) return t.borderStrong;
          return t.border;
        }),
        crossAxisMargin: 2,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: t.textMuted,
        textColor: t.text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.sm),
        ),
      ),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.accent,
        selectionColor: t.accent.withValues(alpha: 0.24),
        selectionHandleColor: t.accent,
      ),
    );
  }

  static OutlineInputBorder _border(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(FanxRadius.sm),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  /// 字阶：展示字用 Archivo，正文用 IBM Plex Sans。
  /// 中英文混排靠 fontFamilyFallback 回落，避免出现默认系统字形。
  static TextTheme _textTheme(FanxTokens t) {
    TextStyle display(
      double size, {
      double tracking = -1.2,
      FontWeight w = FontWeight.w700,
    }) {
      return GoogleFonts.archivo(
        fontSize: size,
        fontWeight: w,
        letterSpacing: tracking,
        height: 1.04,
        color: t.text,
        fontStyle: FontStyle.normal,
      ).copyWith(fontFamilyFallback: FanxFonts.fallback);
    }

    TextStyle sans(
      double size, {
      FontWeight w = FontWeight.w400,
      double height = 1.6,
      Color? color,
    }) {
      return GoogleFonts.ibmPlexSans(
        fontSize: size,
        fontWeight: w,
        height: height,
        color: color ?? t.text,
      ).copyWith(fontFamilyFallback: FanxFonts.fallback);
    }

    TextStyle mono(
      double size, {
      FontWeight w = FontWeight.w500,
      double tracking = 1.2,
      Color? color,
    }) {
      return GoogleFonts.ibmPlexMono(
        fontSize: size,
        fontWeight: w,
        letterSpacing: tracking,
        height: 1.2,
        color: color ?? t.textMuted,
      ).copyWith(fontFamilyFallback: FanxFonts.monoFallback);
    }

    return TextTheme(
      displayLarge: display(58, tracking: -2.4),
      displayMedium: display(44, tracking: -1.8),
      displaySmall: display(32, tracking: -1.0),
      headlineLarge: display(28, tracking: -0.8),
      headlineMedium: display(23, tracking: -0.6, w: FontWeight.w600),
      headlineSmall: display(19, tracking: -0.4, w: FontWeight.w600),
      titleLarge: sans(16.5, w: FontWeight.w600, height: 1.35),
      titleMedium: sans(14.5, w: FontWeight.w600, height: 1.4),
      titleSmall: sans(13.5, w: FontWeight.w600, height: 1.4),
      bodyLarge: sans(15),
      bodyMedium: sans(13.5, height: 1.62),
      bodySmall: sans(12, height: 1.55, color: t.textMuted),
      labelLarge: sans(13, w: FontWeight.w600, height: 1.2),
      labelMedium: mono(11, tracking: 1.0, color: t.text),
      labelSmall: mono(10, tracking: 1.6),
    );
  }
}
