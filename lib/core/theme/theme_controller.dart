import 'package:flutter/material.dart';

/// 全局主题模式。跨端共享，默认跟随系统。
final ValueNotifier<ThemeMode> themeController = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// 按 系统 -> 浅色 -> 深色 -> 系统 的顺序循环，供桌面端快捷切换。
void cycleThemeMode() {
  themeController.value = switch (themeController.value) {
    ThemeMode.system => ThemeMode.light,
    ThemeMode.light => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.system,
  };
}

String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
};

IconData themeModeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.system => Icons.brightness_auto_outlined,
  ThemeMode.light => Icons.light_mode_outlined,
  ThemeMode.dark => Icons.dark_mode_outlined,
};
