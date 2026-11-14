import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 当前是否运行在桌面平台（Windows / macOS / Linux）。
/// 用 defaultTargetPlatform 判断，避免在 Web 上引入 dart:io 导致编译失败。
bool get isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// 桌面窗口初始化：PC 端优先，先给一个合适的默认尺寸与最小尺寸。
abstract final class DesktopWindow {
  static Future<void> setup() async {
    await windowManager.ensureInitialized();

    const options = WindowOptions(
      size: Size(1320, 860),
      minimumSize: Size(920, 620),
      center: true,
      title: 'Fanx',
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
}
