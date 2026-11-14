import 'dart:convert';

import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/features/library/library_view.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 用假 daemon 渲染真实资源库：验证读数、选中检视、启停与窄窗口布局。
void main() {
  late AppState previous;

  setUp(() => previous = appState);
  tearDown(() => appState = previous);

  Map<String, dynamic> skill({bool enabled = true, bool loaded = true}) => {
    'name': 'pdf-tools',
    'entry': 'pdf-tools',
    'description': '从 PDF 里抽取文字与表格，处理 PDF 文档时使用。',
    'path': r'C:\agents\coding\skills\pdf-tools',
    'relPath': 'skills/pdf-tools',
    'kind': 'skill',
    'enabled': enabled,
    'declaredName': 'pdf-tools',
    'bytes': 2048,
    'files': 3,
    'modified': '2026-11-13T10:20:00.000Z',
    'issues': <String>[],
    'loaded': loaded,
  };

  Map<String, dynamic> snapshot({bool pdfEnabled = true}) => {
    'skills': [skill(enabled: pdfEnabled, loaded: pdfEnabled)],
    'extensions': [
      {
        'name': 'permission-gate',
        'entry': 'permission-gate.ts',
        'description': 'permission-gate.ts',
        'path': r'C:\agents\coding\extensions\permission-gate.ts',
        'relPath': 'extensions/permission-gate.ts',
        'kind': 'extension',
        'enabled': true,
        'bytes': 1200,
        'files': 1,
        'modified': '2026-11-12T09:00:00.000Z',
        'issues': <String>[],
        'loaded': true,
      },
    ],
    'prompts': [
      {
        'name': 'review',
        'entry': 'review.md',
        'description': '代码审查用提示词',
        'path': r'C:\agents\coding\prompts\review.md',
        'relPath': 'prompts/review.md',
        'kind': 'prompt',
        'enabled': false,
        'bytes': 300,
        'files': 1,
        'modified': '2026-11-10T09:00:00.000Z',
        'issues': <String>[],
        'loaded': false,
      },
    ],
    'effective': null,
  };

  Map<String, dynamic> detail({bool enabled = true}) => {
    'item': {
      ...skill(enabled: enabled, loaded: enabled),
      'entryFile': 'SKILL.md',
      'content': '# PDF 工具\n\n## 用法\n\n抽取表格。',
      'frontmatter': {'name': 'pdf-tools', 'license': 'MIT'},
      'tools': <String>[],
      'commands': <String>[],
      'entries': [
        {'path': 'SKILL.md', 'bytes': 512, 'dir': false},
        {'path': 'scripts', 'bytes': 0, 'dir': true},
        {'path': 'scripts/extract.sh', 'bytes': 1536, 'dir': false},
      ],
    },
  };

  http.Response reply(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  (AppState, List<String>) buildState() {
    final seen = <String>[];
    var pdfEnabled = true;

    final client = MockClient((request) async {
      final path = request.url.path;
      seen.add('${request.method} $path');

      if (path == '/api/agents' && request.method == 'GET') {
        return reply({'agents': <Object>[]});
      }
      if (path == '/api/agents/coding/resources' && request.method == 'GET') {
        return reply(snapshot(pdfEnabled: pdfEnabled));
      }
      if (path == '/api/agents/coding/resources/item') {
        return reply(detail(enabled: pdfEnabled));
      }
      if (path == '/api/agents/coding/resources/toggle') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        pdfEnabled = body['enabled'] == true;
        return reply({
          'ok': true,
          'resources': snapshot(pdfEnabled: pdfEnabled),
        });
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
        'configDir': r'C:\agents\coding',
        'cwd': r'E:\fanx',
        'running': true,
        'skills': 1,
        'extensions': 1,
        'prompts': 1,
      }),
    ];
    state.loading = false;
    return (state, seen);
  }

  Future<void> pumpLibrary(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final (state, _) = buildState();
    appState = state;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: LibraryView(agent: appState.agents.first)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('资源库列出全部能力，并给出读数', (tester) async {
    await pumpLibrary(tester, const Size(1280, 860));

    expect(find.text('资源库'), findsOneWidget);
    expect(find.text('pdf-tools'), findsWidgets);
    expect(find.text('permission-gate'), findsWidgets);
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.text('ENABLED'), findsOneWidget);
    // 三条资源，两条启用
    expect(find.text('3'), findsWidgets);
    expect(find.text('2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中后检视面板摊开 SKILL.md', (tester) async {
    await pumpLibrary(tester, const Size(1280, 860));

    await tester.tap(find.byKey(const ValueKey('res-skill:pdf-tools')));
    await tester.pumpAndSettle();

    expect(find.text('SKILL / INSPECTOR'), findsOneWidget);
    expect(find.text('pi 已加载'), findsOneWidget);

    // 内容预览在面板底部，列表是懒构建的，滚到位才验证得到。
    await tester.scrollUntilVisible(
      find.textContaining('抽取表格', findRichText: true),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('抽取表格', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关掉技能开关会落到磁盘状态上', (tester) async {
    final (state, seen) = buildState();
    appState = state;

    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: LibraryView(agent: appState.agents.first)),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('res-skill:pdf-tools'));
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(seen, contains('POST /api/agents/coding/resources/toggle'));
    expect(find.text('已停用'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多种窗口宽度下都不溢出', (tester) async {
    for (final size in const [
      Size(900, 760),
      Size(1024, 800),
      Size(1440, 900),
    ]) {
      await pumpLibrary(tester, size);
      expect(tester.takeException(), isNull, reason: '宽度 ${size.width} 溢出');
    }
  });

  testWidgets('窄窗口点条目，检视面板改用弹窗', (tester) async {
    await pumpLibrary(tester, const Size(760, 720));

    await tester.tap(find.byKey(const ValueKey('res-skill:pdf-tools')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('SKILL / INSPECTOR'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口下切到单栏，不溢出', (tester) async {
    await pumpLibrary(tester, const Size(760, 720));

    expect(find.text('资源库'), findsOneWidget);
    expect(find.text('pdf-tools'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
