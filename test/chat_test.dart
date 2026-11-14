import 'dart:async';
import 'dart:convert';

import 'package:fanx/core/api/daemon_client.dart';
import 'package:fanx/core/api/models.dart';
import 'package:fanx/core/theme/app_theme.dart';
import 'package:fanx/core/theme/app_tokens.dart';
import 'package:fanx/features/chat/chat_markdown.dart';
import 'package:fanx/features/chat/chat_panel.dart';
import 'package:fanx/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 对话区：Markdown 解析、块渲染、空态建议、生成中状态。
void main() {
  late AppState previous;

  setUp(() => previous = appState);
  tearDown(() => appState = previous);

  group('Markdown 解析', () {
    test('代码块保留原文并记下语言', () {
      final blocks = parseMarkdown('说明：\n```dart\nvoid main() {}\n```\n结束');
      expect(blocks.length, 3);
      expect(blocks[0], isA<MarkdownParagraph>());
      final code = blocks[1] as MarkdownCode;
      expect(code.language, 'dart');
      expect(code.code, 'void main() {}');
      expect(blocks[2], isA<MarkdownParagraph>());
    });

    test('标题层级与列表', () {
      final blocks = parseMarkdown('# 一\n\n## 二\n\n- a\n  - b\n1. c\n2. d');
      final headings = blocks.whereType<MarkdownHeading>().toList();
      expect(headings.map((item) => item.level), [1, 2]);
      final lists = blocks.whereType<MarkdownList>().toList();
      expect(lists.first.ordered, isFalse);
      expect(lists.first.items.first.depth, 0);
      expect(lists.first.items.last.depth, 1);
      expect(lists.last.ordered, isTrue);
      expect(lists.last.items.length, 2);
    });

    test('引用与分隔线', () {
      final blocks = parseMarkdown('> 先看日志\n> 再看代码\n\n---');
      expect(blocks.first, isA<MarkdownQuote>());
      expect((blocks.first as MarkdownQuote).text, '先看日志\n再看代码');
      expect(blocks.last, isA<MarkdownRule>());
    });
  });

  group('流式增量解析', () {
    List<String> signature(List<MarkdownBlock> blocks) => [
      for (final block in blocks)
        switch (block) {
          MarkdownParagraph(:final text) => 'p:$text',
          MarkdownHeading(:final level, :final text) => 'h$level:$text',
          MarkdownCode(:final language, :final code) => 'c:$language:$code',
          MarkdownQuote(:final text) => 'q:$text',
          MarkdownMath(:final latex) => 'm:$latex',
          MarkdownImage(:final alt, :final url) => 'i:$alt:$url',
          MarkdownList(:final items) => 'l:${items.length}',
          MarkdownTable(:final rows) => 't:${rows.length}',
          MarkdownRule() => 'rule',
        },
    ];

    test('边界跳过未闭合代码块内的空行', () {
      const source = '开头\n\n```dart\nvoid a() {}\n\nvoid b() {}\n';
      final cut = markdownStableCut(source);
      expect(source.substring(0, cut), '开头\n\n');
      expect(source.substring(cut).startsWith('```dart'), isTrue);
    });

    test('同一行闭合的公式不进入围栏状态', () {
      const source = r'$$a+b$$' '\n\n尾段';
      expect(markdownStableCut(source), r'$$a+b$$'.length + 2);
    });

    test('逐字符追加时增量结果与全量解析一致', () {
      const full =
          '# 标题\n\n第一段 **粗体**。\n\n- 一\n- 二\n\n'
          '```dart\nvoid main() {}\n\n// 注释\n```\n\n'
          '| 名称 | 状态 |\n| --- | --- |\n| a | ok |\n\n'
          r'$$\frac{a}{b}$$'
          '\n\n收尾';
      final parser = MarkdownStreamParser();
      for (var end = 1; end <= full.length; end++) {
        final slice = full.substring(0, end);
        expect(
          signature(parser.parse(slice)),
          signature(parseMarkdown(slice)),
          reason: '追加到第 $end 个字符时增量结果与全量不一致',
        );
      }
    });

    test('打字机截断不切开 emoji 代理对', () {
      expect(revealPrefix('A😀B', 2), 'A');
      expect(revealPrefix('A😀B', 3), 'A😀');
      expect(revealPrefix('abc', 99), 'abc');
    });
  });

  testWidgets('流式模式渲染完整 Markdown 并随追加更新', (tester) async {
    Widget host(String text) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ChatMarkdown(text: text, streaming: true),
        ),
      ),
    );

    await tester.pumpWidget(host('# 流式标题\n\n正文'));
    expect(find.text('流式标题'), findsOneWidget);

    await tester.pumpWidget(
      host('# 流式标题\n\n正文\n\n```dart\nvoid main() {}\n```'),
    );
    expect(find.text('DART'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('明暗主题切换后行内 span 缓存失效', (tester) async {
    for (final theme in <ThemeData>[AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ChatMarkdown(text: '先改 **配置**，再跑 `flutter test`。'),
            ),
          ),
        ),
      );
      expect(
        find.textContaining('flutter test', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    }
  });

  group('更多 Markdown 特性', () {
    test('表格：列数、对齐与行', () {
      final blocks = parseMarkdown(
        '| 名称 | 状态 |\n| --- | ---: |\n| pdf-tools | 已启用 |\n| code-review | 已停用 |',
      );
      final table = blocks.single as MarkdownTable;
      expect(table.columns, 2);
      expect(table.aligns[1], TextAlign.right);
      expect(table.rows.length, 2);
    });

    test('任务列表勾选状态', () {
      final blocks = parseMarkdown('- [x] 已完成\n- [ ] 待办');
      final list = blocks.single as MarkdownList;
      expect(list.items[0].checked, isTrue);
      expect(list.items[1].checked, isFalse);
    });

    test('行内删除线与链接', () {
      final blocks = parseMarkdown('~~旧方案~~ [文档](https://example.com)');
      expect(blocks.single, isA<MarkdownParagraph>());
    });

    test('代码高亮不改写原文', () {
      const code = 'const a = 1; // 注释';
      final blocks = parseMarkdown('```dart\n$code\n```');
      expect((blocks.single as MarkdownCode).code, code);
    });
  });

  testWidgets('表格与任务列表能渲染出来', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatMarkdown(
              text:
                  '| 名称 | 状态 |\n| --- | --- |\n| pdf-tools | 已启用 |\n\n- [x] 写完渲染器\n- [ ] 补测试',
            ),
          ),
        ),
      ),
    );

    expect(find.text('名称'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outlined), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('数学公式', () {
    test('\$\$...\$\$ 解析为公式块', () {
      final blocks = parseMarkdown('结论：\n\n\$\$\nE = mc^2\n\$\$\n\n完毕');
      expect(blocks.length, 3);
      final math = blocks[1] as MarkdownMath;
      expect(math.latex, contains('mc^2'));
    });

    test('希腊字母与上下标', () {
      final spans = buildMathSpans(
        r'\alpha + x^2',
        const TextStyle(),
        FanxTokens.light,
      );
      final text = spans
          .whereType<TextSpan>()
          .map((span) => span.toPlainText())
          .join();
      expect(text, 'α + x2');
    });

    test('分数与根号', () {
      final text = buildMathSpans(
        r'\frac{a}{b} + \sqrt{x}',
        const TextStyle(),
        FanxTokens.light,
      ).whereType<TextSpan>().map((span) => span.toPlainText()).join();
      expect(text, contains('a'));
      expect(text, contains('b'));
      expect(text, contains('⁄'));
      expect(text, contains('√'));
    });

    test('价格里的 \$ 不当成公式', () {
      final blocks = parseMarkdown('价格 \$5 和 \$10 之间');
      expect(blocks.single, isA<MarkdownParagraph>());
      expect((blocks.single as MarkdownParagraph).text, contains('\$5'));
    });

    test('行内公式嵌在句子里', () {
      final blocks = parseMarkdown(r'能量 $E=mc^2$ 很大');
      expect(blocks.single, isA<MarkdownParagraph>());
    });
  });

  testWidgets('公式能渲染出来', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatMarkdown(
              text: '行内 \$\\alpha\$ 与块：\n\n\$\$\nE = mc^2\n\$\$',
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('α', findRichText: true), findsWidgets);
    expect(find.textContaining('E = mc', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  group('错误诊断', () {
    test('连接被拒', () {
      expect(
        diagnoseModelError('502 upstream connect failed (os error 10061)'),
        contains('代理'),
      );
    });

    test('鉴权失败', () {
      expect(diagnoseModelError('401 Unauthorized'), contains('API Key'));
    });

    test('超时与未知错误', () {
      expect(diagnoseModelError('request timed out'), contains('超时'));
      expect(diagnoseModelError('something odd'), isNull);
    });
  });

  testWidgets('块渲染：标题、代码块语言标签与复制入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatMarkdown(
              text:
                  '# 结论\n\n先改 **配置**，再跑 `flutter test`。\n\n```dart\nvoid main() {}\n```',
            ),
          ),
        ),
      ),
    );

    expect(find.text('结论'), findsOneWidget);
    expect(find.text('DART'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    // 行内代码与粗体走 TextSpan，内容仍在同一段里
    expect(
      find.textContaining('flutter test', findRichText: true),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  Map<String, dynamic> state({bool busy = false, List<Object>? messages}) => {
    'running': true,
    'busy': busy,
    'sessionId': 's1',
    'model': {'provider': 'magpie', 'id': 'deepseek', 'name': 'DeepSeek-V4'},
    'messages':
        messages ??
        [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '看下这段代码'},
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text':
                    '## 结论\n\n这里有个 **空指针**：\n\n```dart\nfinal x = null;\n```\n\n- 先判空\n- 再加测试',
              },
            ],
          },
        ],
  };

  Future<void> pumpChat(
    WidgetTester tester, {
    required Map<String, dynamic> payload,
    Size size = const Size(1200, 900),
    List<String>? sent,
    List<String>? modelSelections,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/state')) {
        return http.Response(
          jsonEncode(payload),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path.endsWith('/events')) {
        return http.Response(
          '',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (path.endsWith('/chat')) {
        sent?.add(request.body);
        return http.Response(
          '{"accepted":true}',
          202,
          headers: {'content-type': 'application/json'},
        );
      }
      // 空态读的是真实配置（models.json + 资源快照），不是运行时 state。
      if (path.endsWith('/models')) {
        return http.Response(
          jsonEncode({
            'providers': [
              {
                'id': 'local',
                'name': 'Local',
                'baseUrl': 'http://127.0.0.1:11434',
                'api': 'openai',
                'models': [
                  {'id': 'qwen3:8b', 'name': 'Qwen3 8B'},
                  {'id': 'gpt-4o', 'name': 'GPT-4o'},
                ],
              },
            ],
            'defaultProvider': 'local',
            'defaultModel': 'qwen3:8b',
            'active': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/resources')) {
        return http.Response(
          jsonEncode({
            'skills': [
              {
                'name': 'code-review',
                'description': '代码评审流程',
                'kind': 'skill',
                'enabled': true,
                'relPath': 'skills/code-review',
              },
              {
                'name': 'flutter-perf',
                'description': '性能排查',
                'kind': 'skill',
                'enabled': true,
                'relPath': 'skills/flutter-perf',
              },
            ],
            'extensions': [
              {
                'name': 'shell-tools',
                'description': '终端工具',
                'kind': 'extension',
                'enabled': true,
                'relPath': 'extensions/shell-tools.ts',
              },
            ],
            'prompts': [
              {
                'name': 'review',
                'description': '评审模板',
                'kind': 'prompt',
                'enabled': false,
                'relPath': 'prompts/review.md',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/model') && request.method == 'PUT') {
        modelSelections?.add(request.body);
        return http.Response(
          '{"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final state = AppState(
      DaemonClient(
        base: Uri.parse('http://127.0.0.1:4317'),
        httpClient: client,
      ),
    );
    state.loading = false;
    appState = state;

    final agent = Agent.fromJson({
      'id': 'coding',
      'name': '编码 Agent',
      'description': '写代码用',
      'configDir': 'C:/agents/coding',
      'cwd': 'E:/fanx',
      'running': true,
      'skills': 2,
      'extensions': 1,
      'prompts': 3,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ChatPanel(agent: agent)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('回复按 Markdown 渲染，用户指令保留原样', (tester) async {
    await pumpChat(tester, payload: state());

    expect(find.text('看下这段代码'), findsOneWidget);
    expect(find.text('结论'), findsOneWidget);
    expect(find.text('DART'), findsOneWidget);
    expect(find.text('先判空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型失败时原样显示 pi 的报错，而不是空回复', (tester) async {
    const rawError =
        '502 upstream connect failed: 由于目标计算机积极拒绝，无法连接。 (os error 10061)';
    await pumpChat(
      tester,
      payload: state(
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '帮我改个 bug'},
            ],
          },
          {
            'role': 'assistant',
            'content': <Object>[],
            'stopReason': 'error',
            'errorMessage': rawError,
            'provider': 'magpie',
            'model': 'workbuddy/kimi-k3.1-pro',
            'durationMs': 2041,
          },
        ],
      ),
    );

    expect(find.text('模型调用失败'), findsOneWidget);
    expect(find.textContaining('10061'), findsOneWidget);
    expect(find.textContaining('拒绝连接'), findsOneWidget);
    expect(find.text('magpie / workbuddy/kimi-k3.1-pro'), findsOneWidget);
    expect(find.text('2.0 s'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 不能再出现"空回复"这种掩盖真实原因的字样
    expect(find.textContaining('空回复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生成中显示占位骨架与停止按钮', (tester) async {
    await pumpChat(
      tester,
      payload: state(
        busy: true,
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '继续'},
            ],
          },
        ],
      ),
    );

    expect(find.text('正在生成…'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回车直接发送，Shift+回车换行', (tester) async {
    final sent = <String>[];
    await pumpChat(
      tester,
      payload: state(messages: <Object>[]),
      sent: sent,
    );

    final field = find.byType(TextField);
    await tester.enterText(field, '第一行');
    await tester.pump();

    // Shift + Enter：换行，不发送
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(sent, isEmpty);
    var widget = tester.widget<TextField>(field);
    expect(widget.controller!.text, contains('\n'));

    // 输入法拼字中按回车是确认候选，不应该发出去
    widget = tester.widget<TextField>(field);
    widget.controller!.value = const TextEditingValue(
      text: 'ni',
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, isEmpty);
    widget.controller!.value = const TextEditingValue(text: '第一行');

    // 补一句再按 Enter：直接发送
    await tester.enterText(field, '第一条指令');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 50));

    expect(sent.length, 1);
    expect(sent.first, contains('第一条指令'));
    widget = tester.widget<TextField>(field);
    expect(widget.controller!.text, isEmpty);
    // 空态的 Reveal 有错峰定时器，等它跑完再收尾
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态列出真实模型与资源名称，不再有示例卡', (tester) async {
    await pumpChat(tester, payload: state(messages: <Object>[]));
    await tester.pumpAndSettle();

    expect(find.text('编码 Agent'), findsWidgets);
    // 模型来自配置，而不是「未选模型」：runtime 未启动时 state 不带 model 字段。
    expect(find.text('local / qwen3:8b'), findsOneWidget);
    expect(find.text('未选模型'), findsNothing);
    // 列的是具体名字，不是「2 技能」这种计数。
    expect(find.text('code-review'), findsOneWidget);
    expect(find.text('flutter-perf'), findsOneWidget);
    expect(find.text('shell-tools'), findsOneWidget);
    expect(find.text('review'), findsOneWidget);
    expect(find.text('停用'), findsOneWidget);
    // 旧的三条示例提示已移除。
    expect(find.textContaining('先摸清这个项目的结构'), findsNothing);
    expect(find.textContaining('从这里开始'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态模型行可直接切换', (tester) async {
    final selected = <String>[];
    await pumpChat(
      tester,
      payload: state(messages: <Object>[]),
      modelSelections: selected,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('local / qwen3:8b'));
    await tester.pumpAndSettle();
    expect(find.text('local / gpt-4o'), findsOneWidget);

    await tester.tap(find.text('local / gpt-4o'));
    await tester.pumpAndSettle();
    expect(selected.length, 1);
    expect(selected.single, contains('gpt-4o'));
    expect(find.text('已切换到 local / gpt-4o'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('整包回复也会平滑展开（打字机），展开完显示全文', (tester) async {
    final controller = StreamController<Map<String, dynamic>>();
    addTearDown(controller.close);
    appState = AppState(_FakeStreamClient(controller))..loading = false;

    final agent = Agent.fromJson({
      'id': 'coding',
      'name': '编码 Agent',
      'description': '',
      'configDir': 'C:/agents/coding',
      'cwd': 'E:/fanx',
      'running': true,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ChatPanel(agent: agent)),
      ),
    );
    await tester.pump();

    Map<String, dynamic> stateWith(List<Object> messages, bool busy) => {
      'running': true,
      'busy': busy,
      'messages': messages,
    };

    controller.add({
      'type': 'state',
      'state': stateWith([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '介绍下自己'},
          ],
        },
      ], true),
    });
    await tester.pump();

    controller.add({
      'type': 'state',
      'state': stateWith([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '介绍下自己'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': '你好，世界'},
          ],
        },
      ], false),
    });
    await tester.pump();

    // 刚到的回复还没展开完，全文不该一次性出现
    expect(find.text('你好，世界'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('你好，世界'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('token 增量让正文逐段长出，收到最终消息后不再显示流式标签', (tester) async {
    final controller = StreamController<Map<String, dynamic>>();
    addTearDown(controller.close);

    appState = AppState(_FakeStreamClient(controller))..loading = false;
    final agent = Agent.fromJson({
      'id': 'coding',
      'name': '编码 Agent',
      'description': '',
      'configDir': 'C:/agents/coding',
      'cwd': 'E:/fanx',
      'running': true,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ChatPanel(agent: agent)),
      ),
    );
    await tester.pump();

    controller.add({'type': 'delta', 'text': '你好，'});
    await tester.pump();
    expect(find.text('ASSISTANT · STREAMING'), findsOneWidget);
    expect(find.text('你好，'), findsOneWidget);

    controller.add({'type': 'delta', 'text': '世界'});
    await tester.pump();
    expect(find.text('你好，世界'), findsOneWidget);

    // 最终消息到达：流式缓冲被清掉，标签消失，正文留在正式消息里
    controller.add({
      'type': 'state',
      'state': {
        'running': true,
        'busy': false,
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': '你好，世界'},
            ],
          },
        ],
      },
    });
    await tester.pump();
    expect(find.text('ASSISTANT · STREAMING'), findsNothing);
    expect(find.text('你好，世界'), findsWidgets);

    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换窗口里旧会话的 SSE 快照不会盖到新会话上', (tester) async {
    final controller = StreamController<Map<String, dynamic>>();
    addTearDown(controller.close);
    appState = AppState(_FakeStreamClient(controller))..loading = false;
    final agent = Agent.fromJson({
      'id': 'coding',
      'name': '编码 Agent',
      'description': '',
      'configDir': 'C:/agents/coding',
      'cwd': 'E:/fanx',
      'running': true,
    });
    String? notifiedSessionId;
    int? notifiedCount;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ChatPanel(
            agent: agent,
            initialState: AgentState.fromJson({
              'running': true,
              'busy': false,
              'sessionId': 's2',
              'messages': [],
            }),
            expectedSessionId: 's2',
            onState: (state) {
              notifiedSessionId = state.sessionId;
              notifiedCount = state.messages.length;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    Map<String, dynamic> stateEvent(String sessionId, String text) => {
      'type': 'state',
      'state': {
        'running': true,
        'busy': false,
        'sessionId': sessionId,
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': text},
            ],
          },
        ],
      },
    };

    controller.add(stateEvent('s1', '旧会话内容'));
    await tester.pump();
    await tester.pump();
    expect(find.text('旧会话内容'), findsNothing);
    expect(notifiedSessionId, isNull);

    controller.add(stateEvent('s2', '新会话内容'));
    await tester.pump();
    await tester.pump();
    // 空态退场时 _Reveal 会按序号排 0~350ms 的延时动画，走完再结束用例。
    await tester.pump(const Duration(milliseconds: 500));
    expect(notifiedSessionId, 's2');
    expect(notifiedCount, 1);
    expect(
      find.textContaining('新会话内容', findRichText: true),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  test('events 带上期望会话号，避免后端推旧会话快照', () async {
    Uri? captured;
    final client = DaemonClient(
      base: Uri.parse('http://127.0.0.1:4317'),
      httpClient: MockClient((request) async {
        captured = request.url;
        return http.Response(
          '',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    addTearDown(client.dispose);

    await client.events('coding', sessionId: 's2').listen((_) {}).asFuture<void>();
    expect(captured?.queryParameters['session'], 's2');
  });
}

class _FakeStreamClient extends DaemonClient {
  _FakeStreamClient(this.controller)
    : super(base: Uri.parse('http://127.0.0.1:4317'));

  final StreamController<Map<String, dynamic>> controller;

  @override
  Stream<Map<String, dynamic>> events(String id, {String? sessionId}) =>
      controller.stream;

  @override
  Future<AgentState> getState(String id) async => AgentState.empty;
}
