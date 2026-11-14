import 'package:fanx/app.dart';
import 'package:fanx/features/launcher/launcher_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('启动页最先出现，且渲染出选 Agent 的入口', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const FanxApp());
    await tester.pump(const Duration(milliseconds: 50));

    // 不管 daemon 是否可达，路由的第一屏都必须是启动页而不是工作区。
    expect(find.byType(LauncherPage), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
  });

  testWidgets('daemon 不可用时给出可操作的离线提示', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const FanxApp());
    await tester.pump(const Duration(seconds: 2));

    // 测试环境的 HttpClient 被替换为返回 400 的实现，因此必然走到离线态。
    expect(find.text('连不上 daemon'), findsOneWidget);
  });

  testWidgets('窄窗口下启动页依然可用', (tester) async {
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const FanxApp());
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('连不上 daemon'), findsOneWidget);
  });
}
