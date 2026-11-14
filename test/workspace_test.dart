import 'dart:convert';

import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/core/ui/fanx_kit.dart';
import 'package:fanx/features/workspace/workspace_page.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 用假 daemon 渲染真实工作区：能验证布局是否溢出、会话栏是否读到数据，
/// 而不依赖本机后端是否在跑。
void main() {
  late AppState previous;

  setUp(() => previous = appState);
  tearDown(() => appState = previous);

  AppState buildState({int width = 1440}) {
    final client = MockClient((request) async {
      final path = request.url.path;

      if (path == '/api/agents/coding/state') {
        return http.Response(
          jsonEncode({
            'running': true,
            'busy': false,
            'sessionId': 's-active',
            'sessionName': '',
            'model': {
              'provider': 'magpie',
              'id': 'deepseek/deepseek-flash',
              'name': 'DeepSeek-V4.1-Flash',
            },
            'thinkingLevel': 'off',
            'messages': [
              {
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': '重构会话管理'},
                ],
              },
              {
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': '先做启动页，再做左侧会话栏。'},
                ],
              },
            ],
            'diagnostics': [],
            'lastError': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path == '/api/agents/coding/sessions') {
        return http.Response(
          jsonEncode({
            'sessions': [
              {
                'id': 's-active',
                'name': '',
                'firstMessage': '重构会话管理',
                'modified': '2026-11-13T13:30:00.000Z',
                'messageCount': 2,
                'active': true,
              },
              {
                'id': 's-missing',
                'name': '已失效会话',
                'firstMessage': '',
                'modified': '2026-11-13T11:00:00.000Z',
                'messageCount': 1,
                'active': false,
              },
              {
                'id': 's-old',
                'name': '模型接入',
                'firstMessage': '把本机路由接进来',
                'modified': '2026-11-13T12:00:00.000Z',
                'messageCount': 8,
                'active': false,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/activate') && path.contains('s-missing')) {
        return http.Response(
          jsonEncode({'error': '会话不存在'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/activate')) {
        // 故意延迟，模拟真实往返，用来验证"点击后立刻有反馈"。
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response(
          jsonEncode({
            'ok': true,
            'state': {
              'running': true,
              'busy': false,
              'sessionId': path.split('/')[4],
              'sessionName': '模型接入',
              'model': {
                'provider': 'magpie',
                'id': 'deepseek/deepseek-flash',
                'name': 'DeepSeek-V4.1-Flash',
              },
              'thinkingLevel': 'off',
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': '把本机路由接进来'},
                  ],
                },
              ],
              'diagnostics': [],
              'lastError': null,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/events')) {
        return http.Response(
          '',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }

      return http.Response(jsonEncode({'error': 'unmocked $path'}), 404);
    });

    final state = AppState(
      DaemonClient(
        base: Uri.parse('http://127.0.0.1:4317'),
        httpClient: client,
      ),
    );
    state.agents = [
      Agent.fromJson({
        'id': 'coding',
        'name': '编码 Agent',
        'description': '写代码用',
        'configDir': r'C:\Users\demo\.pi-manager\agents\coding',
        'cwd': r'E:\fanx',
        'running': true,
        'skills': 2,
        'extensions': 0,
        'prompts': 1,
      }),
    ];
    state.loading = false;
    state.offline = false;
    return state;
  }

  Future<void> pumpWorkspace(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    appState = buildState();
    await tester.pumpWidget(
      MaterialApp(
        // 用真实主题跑，才能覆盖自定义 TabBar / 输入框 / 卡片样式下的布局。
        theme: AppTheme.light,
        home: const WorkspacePage(agentId: 'coding'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('工作区渲染出会话栏与当前会话', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('重构会话管理'), findsWidgets);
    expect(find.text('模型接入'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击会话后立刻有反馈，不等接口返回', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));

    // 初始不应有切换中的指示
    expect(find.byType(FanxSpinner), findsNothing);

    await tester.tap(find.text('模型接入'));
    await tester.pump();

    // 接口还没返回（mock 延迟 300ms），但界面已经给出"正在切换"的反馈
    expect(
      find.byType(FanxSpinner),
      findsOneWidget,
      reason: '点击会话后应立刻显示切换中的指示，否则用户会觉得卡住',
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(FanxSpinner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到已失效的会话会自愈，不会卡住', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));

    await tester.tap(find.text('已失效会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 给出可理解的原因，而不是干巴巴一句"会话不存在"
    expect(find.textContaining('已不存在'), findsOneWidget);
    // 切换指示必须清掉，否则之后点任何会话都没反应
    expect(find.byType(FanxSpinner), findsNothing);
    expect(tester.takeException(), isNull);

    // 清掉 SnackBar 的计时器
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('窄一点的窗口下不溢出', (tester) async {
    await pumpWorkspace(tester, const Size(1100, 720));

    expect(find.text('会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
