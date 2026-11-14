import 'dart:convert';

import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/features/library/global_library_page.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 全局资源库：验证跨 Agent 的合并行、状态块点击、复制安装与窄窗口布局。
void main() {
  late AppState previous;

  setUp(() => previous = appState);
  tearDown(() => appState = previous);

  http.Response reply(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Map<String, dynamic> agent(String id, String name) => {
    'id': id,
    'name': name,
    'description': '',
    'configDir': 'C:/agents/$id',
    'cwd': 'C:/agents/$id/workspace',
    'running': false,
    'skills': 1,
    'extensions': 0,
    'prompts': 0,
  };

  (AppState, List<String>) buildState() {
    final seen = <String>[];
    var installedOnOffice = false;
    var reviewEnabled = true;

    Map<String, dynamic> presence(String id, String name, bool enabled) => {
      'agentId': id,
      'agentName': name,
      'enabled': enabled,
      'loaded': enabled,
      'entry': 'code-review',
    };

    Map<String, dynamic> library() {
      final agents = [agent('coding', '编码 Agent'), agent('office', '办公 Agent')];
      final presences = [presence('coding', '编码 Agent', reviewEnabled)];
      if (installedOnOffice) {
        presences.add(presence('office', '办公 Agent', true));
      }
      return {
        'agents': agents,
        'items': [
          {
            'key': 'skill:code-review',
            'kind': 'skill',
            'name': 'code-review',
            'description': '审查代码改动，检查边界条件与错误处理。',
            'bytes': 143,
            'files': 1,
            'issues': <String>[],
            'agents': presences,
          },
        ],
        'stats': {
          'items': 1,
          'relations': presences.length,
          'enabled': presences.where((p) => p['enabled'] == true).length,
          'issues': 0,
        },
      };
    }

    final client = MockClient((request) async {
      final path = request.url.path;
      seen.add('${request.method} $path');

      if (path == '/api/library' && request.method == 'GET') {
        return reply(library());
      }
      if (path == '/api/agents' && request.method == 'GET') {
        return reply({
          'agents': [agent('coding', '编码 Agent'), agent('office', '办公 Agent')],
        });
      }
      if (path == '/api/agents/coding/resources/toggle') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        reviewEnabled = body['enabled'] == true;
        return reply({'ok': true, 'resources': {}});
      }
      if (path == '/api/library/copy') {
        installedOnOffice = true;
        return reply({'ok': true});
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
      Agent.fromJson(agent('coding', '编码 Agent')),
      Agent.fromJson(agent('office', '办公 Agent')),
    ];
    state.loading = false;
    return (state, seen);
  }

  Future<void> pumpPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final (state, _) = buildState();
    appState = state;

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const GlobalLibraryPage()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('统一资源库把同一份技能分发到两个 Agent 上', (tester) async {
    await pumpPage(tester, const Size(1280, 860));

    expect(find.text('统一资源库'), findsOneWidget);
    expect(find.byKey(const ValueKey('lib-skill:code-review')), findsOneWidget);
    expect(find.text('RESOURCES'), findsOneWidget);
    expect(find.text('INSTALLED'), findsOneWidget);
    // 两个 Agent 各出现一次状态块
    expect(find.text('编码 Agent'), findsWidgets);
    expect(find.text('办公 Agent'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点未安装的状态块会复制一份过去', (tester) async {
    final (state, seen) = buildState();
    appState = state;

    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const GlobalLibraryPage()),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('lib-skill:code-review'));
    await tester.tap(find.descendant(of: row, matching: find.text('办公 Agent')));
    await tester.pumpAndSettle();

    expect(seen, contains('POST /api/library/copy'));
    expect(find.textContaining('已把 code-review 复制到'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('点已启用的状态块会停用', (tester) async {
    final (state, seen) = buildState();
    appState = state;

    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const GlobalLibraryPage()),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('lib-skill:code-review'));
    await tester.tap(find.descendant(of: row, matching: find.text('编码 Agent')));
    await tester.pumpAndSettle();

    expect(seen, contains('POST /api/agents/coding/resources/toggle'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口下状态块换行，不溢出', (tester) async {
    await pumpPage(tester, const Size(760, 720));

    expect(find.text('统一资源库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
