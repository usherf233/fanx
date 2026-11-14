import 'dart:convert';

import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/core/ui/fanx_kit.dart';
import 'package:fanx/features/chat/chat_panel.dart';
import 'package:fanx/features/workspace/workspace_page.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 用假 daemon 渲染真实工作区：能验证布局是否溢出、会话栏是否读到数据，
/// 而不依赖本机后端是否在跑。
void main() {
  late AppState previous;
  int activateCalls = 0;
  int chatCalls = 0;
  int previewCalls = 0;
  bool activateFails = false;
  final Set<String> deletedIds = {};

  setUp(() {
    previous = appState;
    activateCalls = 0;
    chatCalls = 0;
    previewCalls = 0;
    activateFails = false;
    deletedIds.clear();
  });
  tearDown(() => appState = previous);

  Map<String, dynamic> sessionState(String id, List<String> texts) => {
    'running': true,
    'busy': false,
    'sessionId': id,
    'sessionName': '',
    'model': {
      'provider': 'magpie',
      'id': 'deepseek/deepseek-flash',
      'name': 'DeepSeek-V4.1-Flash',
    },
    'thinkingLevel': 'off',
    'messages': [
      for (var i = 0; i < texts.length; i++)
        {
          'role': i.isEven ? 'user' : 'assistant',
          'content': [
            {'type': 'text', 'text': texts[i]},
          ],
        },
    ],
    'diagnostics': [],
    'lastError': null,
  };

  AppState buildState({
    int width = 1440,
    bool withSecondAgent = false,
    Duration slowFirstAgent = Duration.zero,
  }) {
    final client = MockClient((request) async {
      final path = request.url.path;

      if (path == '/api/agents/coding/state') {
        return http.Response(
          jsonEncode(
            sessionState('s-active', ['重构会话管理', '先做启动页，再做左侧会话栏。']),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path == '/api/agents/coding/sessions') {
        if (slowFirstAgent > Duration.zero) {
          await Future<void>.delayed(slowFirstAgent);
        }
        final rows = [
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
        ];
        return http.Response(
          jsonEncode({
            'sessions': rows
                .where((row) => !deletedIds.contains(row['id']))
                .toList(),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      // 只读预览：读一次历史，绝不切后端会话。
      if (path.startsWith('/api/agents/coding/sessions/') &&
          path.endsWith('/state') &&
          request.method == 'GET') {
        previewCalls++;
        final id = path.split('/')[5];
        if (id == 's-missing') {
          return http.Response(
            jsonEncode({'error': '会话不存在'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return http.Response(
          jsonEncode(
            sessionState(
              id,
              id == 's-old'
                  ? ['把本机路由接进来', '先接本地网关再跑一轮。']
                  : ['重构会话管理', '先做启动页，再做左侧会话栏。'],
            ),
          ),
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
        // 故意延迟，模拟真实切换的开销。只有发消息时才应该出现在这里。
        activateCalls++;
        if (activateFails) {
          return http.Response(
            jsonEncode({'error': '切换失败'}),
            500,
            headers: {'content-type': 'application/json'},
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response(
          jsonEncode({
            'ok': true,
            'state': sessionState(path.split('/')[5], ['把本机路由接进来']),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.method == 'DELETE' &&
          path.startsWith('/api/agents/coding/sessions/')) {
        // 模拟磁盘删除的等待：这段等待必须有可见的过场反馈。
        await Future<void>.delayed(const Duration(milliseconds: 150));
        deletedIds.add(path.split('/')[5]);
        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path == '/api/agents/coding/chat' && request.method == 'POST') {
        chatCalls++;
        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      // 第二个 Agent：会话列表与内容和 coding 完全不同，用来验证切换。
      if (withSecondAgent && path == '/api/agents/office/state') {
        return http.Response(
          jsonEncode(
            sessionState('o-active', ['季度汇报', '整理季度汇报材料。']),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (withSecondAgent && path == '/api/agents/office/sessions') {
        return http.Response(
          jsonEncode({
            'sessions': [
              {
                'id': 'o-active',
                'name': '',
                'firstMessage': '季度汇报',
                'modified': '2026-11-14T09:00:00.000Z',
                'messageCount': 2,
                'active': true,
              },
              {
                'id': 'o-old',
                'name': '周报',
                'firstMessage': '',
                'modified': '2026-11-14T08:00:00.000Z',
                'messageCount': 3,
                'active': false,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (withSecondAgent &&
          path.startsWith('/api/agents/office/sessions/') &&
          path.endsWith('/state')) {
        return http.Response(
          jsonEncode(sessionState(path.split('/')[5], ['周报内容'])),
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
      if (withSecondAgent)
        Agent.fromJson({
          'id': 'office',
          'name': '办公 Agent',
          'description': '文档与演示',
          'configDir': r'C:\Users\demo\.pi-manager\agents\office',
          'cwd': r'E:\office',
          'running': true,
          'skills': 0,
          'extensions': 0,
          'prompts': 0,
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

  Finder composerInput(WidgetTester tester) => find.descendant(
    of: find.byType(ChatPanel),
    matching: find.byType(TextField),
  );

  Future<void> openPreview(WidgetTester tester) async {
    await tester.tap(find.text('模型接入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('工作区渲染出会话栏与当前会话', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('重构会话管理'), findsWidgets);
    expect(find.text('模型接入'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(activateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击查看只做只读预览，不切换后端会话', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));
    const oldReply = '先做启动页，再做左侧会话栏。';
    expect(find.text(oldReply), findsOneWidget);

    await tester.tap(find.text('模型接入'));
    await tester.pump();

    // 只读历史还没回来，但旧会话画面已经撤掉，且侧栏立刻给出反馈。
    expect(find.text(oldReply), findsNothing);
    expect(find.byType(SkeletonBox), findsWidgets);
    expect(find.byType(FanxSpinner), findsOneWidget);
    expect(activateCalls, 0, reason: '点击只是看，不该销毁重建 runtime');

    await tester.pump(const Duration(milliseconds: 200));
    expect(previewCalls, 1);
    expect(find.text('把本机路由接进来'), findsWidgets);
    expect(find.text('先接本地网关再跑一轮。'), findsOneWidget);
    expect(find.byType(InlineNotice), findsNothing,
        reason: '预览是默认行为，不该再挂解释性提示条');
    expect(find.byType(FanxSpinner), findsNothing);
    expect(activateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切回访问过的会话直接从缓存显示历史', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));
    const oldReply = '先做启动页，再做左侧会话栏。';

    await openPreview(tester);
    expect(find.text(oldReply), findsNothing);

    final before = previewCalls;
    await tester.tap(find.text('重构会话管理').first);
    await tester.pump();
    expect(find.text(oldReply), findsOneWidget);
    expect(find.byType(SkeletonBox), findsNothing);
    expect(previewCalls, before, reason: '命中缓存不该再读一次盘');
    expect(activateCalls, 0);

    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('发新消息时才真正切换会话', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));
    await openPreview(tester);
    expect(activateCalls, 0);

    await tester.enterText(composerInput(tester), '继续这段对话');
    await tester.pump();
    await tester.tap(find.text('发送').first);
    await tester.pump();
    // 激活还在路上，但消息尚未发出，不能把内容发到旧会话里。
    expect(chatCalls, 0);

    await tester.pump(const Duration(milliseconds: 400));
    expect(activateCalls, 1);
    expect(chatCalls, 1);
    // 激活成功，画面干净：没有解释性提示，也没有错误横幅。
    expect(find.byType(InlineNotice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('激活失败时保留输入，不把消息发到旧会话', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));
    await openPreview(tester);
    activateFails = true;

    await tester.enterText(composerInput(tester), '继续这段对话');
    await tester.pump();
    await tester.tap(find.text('发送').first);
    await tester.pump(const Duration(milliseconds: 200));

    expect(activateCalls, 1);
    expect(chatCalls, 0, reason: '没切换成功就不能发，否则会落到旧会话里');
    expect(find.text('切换失败'), findsOneWidget);
    expect(
      tester.widget<TextField>(composerInput(tester)).controller?.text,
      '继续这段对话',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('预览到已失效的会话会自愈，不会卡住', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));

    await tester.tap(find.text('已失效会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 给出可理解的原因，而不是干巴巴一句"会话不存在"
    expect(find.textContaining('已不存在'), findsOneWidget);
    expect(find.byType(FanxSpinner), findsNothing);
    expect(activateCalls, 0, reason: '自愈也不该触发会话切换');
    expect(tester.takeException(), isNull);

    // 清掉 SnackBar 的计时器
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('切换 Agent 后会话列表和内容跟着换', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appState = buildState(withSecondAgent: true);

    Future<void> pumpAgent(String id) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: WorkspacePage(agentId: id),
      ),
    );

    await pumpAgent('coding');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('模型接入'), findsOneWidget);
    expect(find.text('编码 Agent'), findsOneWidget);

    // `/a/:id` 是同一条路由，只换路径参数时 State 会被复用。
    await pumpAgent('office');
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('模型接入'), findsNothing, reason: '旧 Agent 的列表要清掉');
    expect(find.text('周报'), findsOneWidget, reason: '新 Agent 的列表要出现');
    expect(find.text('整理季度汇报材料。'), findsOneWidget);
    expect(find.text('办公 Agent'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 清掉 _Reveal / SnackBar 的计时器。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('切换 Agent 后旧 Agent 的迟到响应不会盖掉新列表', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appState = buildState(
      withSecondAgent: true,
      slowFirstAgent: const Duration(milliseconds: 200),
    );

    Future<void> pumpAgent(String id) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: WorkspacePage(agentId: id),
      ),
    );

    await pumpAgent('coding');
    await tester.pump();
    await pumpAgent('office');
    // coding 的列表响应在这段时间里才回来，不能被写进新 Agent 的画面。
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('模型接入'), findsNothing);
    expect(find.text('周报'), findsOneWidget);
    expect(find.text('整理季度汇报材料。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('删除会话有等待反馈，随后条目退场', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 900));

    // 删除按钮只在 hover 时出现，用鼠标手势把条目悬停起来。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(find.text('模型接入')));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 30));

    // 请求还在飞：条目留在原处，淡化并显示转圈与「删除中」。
    expect(find.text('删除中…'), findsOneWidget);
    expect(find.byType(FanxSpinner), findsWidgets);
    expect(activateCalls, 0, reason: '删除不该触发会话切换');

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('模型接入'), findsOneWidget,
        reason: '退场动画没走完前条目还在');

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('模型接入'), findsNothing, reason: '动画结束后才刷新列表');
    expect(find.text('删除中…'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('窄一点的窗口下不溢出', (tester) async {
    await pumpWorkspace(tester, const Size(1100, 720));

    expect(find.text('会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
