import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/features/agents/create_agent_dialog.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 新建 Agent 面板：双栏/单栏两种布局都要不溢出，
/// 并且"留空时 id 会变成什么"必须在界面上说清楚。
void main() {
  late AppState previous;

  setUp(() {
    previous = appState;
    GoogleFonts.config.allowRuntimeFetching = false;
    appState = AppState(
      DaemonClient(
        base: Uri.parse('http://127.0.0.1:4317'),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    appState.agents = [
      Agent.fromJson({
        'id': 'coding',
        'name': '编码 Agent',
        'description': '写代码用',
        'configDir': r'C:\Users\demo\.pi-manager\agents\coding',
        'cwd': r'E:\fanx',
        'running': false,
        'skills': 1,
        'extensions': 0,
        'prompts': 1,
      }),
    ];
    appState.loading = false;
  });

  tearDown(() => appState = previous);

  Future<void> pumpDialog(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: CreateAgentDialog()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('宽窗口下是双栏，且底部给出落盘路径', (tester) async {
    await pumpDialog(tester, const Size(1440, 900));

    expect(find.text('身份'), findsOneWidget);
    expect(find.text('环境与人格'), findsOneWidget);
    // 配置目录预览：与已有 Agent 同级，分隔符沿用后端返回值
    expect(find.textContaining(r'.pi-manager\agents'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口退化为单栏也不溢出', (tester) async {
    await pumpDialog(tester, const Size(720, 720));

    expect(find.text('身份'), findsOneWidget);
    expect(find.text('环境与人格'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('中文名称会提示 id 回退', (tester) async {
    await pumpDialog(tester, const Size(1440, 900));

    await tester.enterText(find.byType(TextFormField).first, '我的助手');
    await tester.pump();

    expect(find.textContaining('回退为'), findsOneWidget);
  });

  testWidgets('ASCII 名称推出可用的 id', (tester) async {
    await pumpDialog(tester, const Size(1440, 900));

    await tester.enterText(find.byType(TextFormField).first, 'Review Bot');
    await tester.pump();

    expect(find.textContaining('留空则自动生成：review-bot'), findsOneWidget);
  });

  testWidgets('重名 id 给出明确错误', (tester) async {
    await pumpDialog(tester, const Size(1440, 900));

    // 第二个输入框是 ID
    await tester.enterText(find.byType(TextFormField).at(1), 'coding');
    await tester.pump();

    expect(find.text('这个 id 已被占用'), findsOneWidget);
  });
}
