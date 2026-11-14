import 'package:flutter/material.dart';

import 'app.dart';
import 'core/platform/desktop_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 只有桌面端才初始化原生窗口；Web / 移动端直接跳过。
  if (isDesktopPlatform) {
    await DesktopWindow.setup();
  }

  runApp(const FanxApp());
}
