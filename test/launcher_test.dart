import 'dart:convert';

import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/features/launcher/launcher_page.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 启动页在有数据时的布局回归：卡片是固定高度的 Wrap，
/// 内容一多最容易溢出，所以这里按三档窗口宽度各跑一遍。
void main() {
  late AppState previous;

  setUp(() {
    previous = appState;
    // 测试环境不允许发网络请求，提前关掉在线字体拉取，避免日志噪音。
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  tearDown(() => appState = previous);

  Agent agent(int index, {bool running = false}) {
    return Agent.fromJson({
      'id': 'agent-$index',
      'name': 'Agent $index',
      'description': index.isEven ? '' : '负责把本地模型接进来，顺便跑一些批处理任务。',
      'configDir': r'C:\Users\demo\.pi-manager\agents\coding',
      'cwd': r'E:\fanx',
      'running': running,
      'skills': index,
      'extensions': index + 1,
      'prompts': 3,
    });
  }

  AppState buildState() {
    final client = MockClient((request) async {
      if (request.url.path == '/api/agents') {
        return http.Response(
          jsonEncode({
            'agents': [
              for (var i = 1; i <= 5; i++) ...[
                {
                  'id': 'agent-$i',
                  'name': 'Agent $i',
                  'description': i.isEven ? '' : '负责把本地模型接进来，顺便跑一些批处理任务。',
                  'configDir': r'C:\Users\demo\.pi-manager\agents\agent',
                  'cwd': r'E:\fanx',
                  'running': i == 2,
                  'skills': i,
                  'extensions': i + 1,
                  'prompts': 3,
                },
              ],
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'error': 'unmocked ${request.url.path}'}),
        404,
      );
    });

    final state = AppState(
      DaemonClient(
        base: Uri.parse('http://127.0.0.1:4317'),
        httpClient: client,
      ),
    );
    state.agents = [for (var i = 1; i <= 5; i++) agent(i, running: i == 2)];
    state.loading = false;
    state.offline = false;
    return state;
  }

  Future<void> pumpLauncher(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    appState = buildState();
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const LauncherPage()),
    );
    await tester.pump(const Duration(milliseconds: 700));
  }

  for (final size in const [Size(1440, 900), Size(1180, 780), Size(960, 700)]) {
    testWidgets('启动页在 ${size.width.toInt()}px 下不溢出', (tester) async {
      await pumpLauncher(tester, size);

      expect(find.text('选择一个 Agent'), findsOneWidget);
      // 5 个 Agent + 1 个新建卡
      expect(find.text('新建 Agent'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('运行中的 Agent 在卡片上标记 RUNNING', (tester) async {
    await pumpLauncher(tester, const Size(1440, 900));

    expect(find.text('RUNNING'), findsWidgets);
    expect(find.text('IDLE'), findsNWidgets(4));
  });
}
