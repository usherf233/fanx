import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';

// ---------------------------------------------------------------------------
// 流式增量解析
// ---------------------------------------------------------------------------

/// 找出「已经封口」的前缀末尾：最后一个不在代码/公式围栏内的空行之后。
///
/// 空行是块级结构的天然分界，之前的部分不会再被后续 token 改变。
/// 代码块内部的空行必须跳过，否则会把一个还没写完的代码块劈成两段，
/// 既闪烁又让缓存前缀不断变化。
int markdownStableCut(String source) {
  final text = source.replaceAll('\r\n', '\n');
  final lines = text.split('\n');
  var inFence = false;
  var inMath = false;
  var offset = 0;
  var cut = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    final next = offset + line.length + (i + 1 < lines.length ? 1 : 0);
    if (inFence) {
      if (trimmed.startsWith('```')) inFence = false;
    } else if (inMath) {
      if (line.contains(r'$$')) inMath = false;
    } else if (trimmed.startsWith('```')) {
      inFence = true;
    } else if (trimmed.startsWith(r'$$')) {
      if (!trimmed.substring(2).contains(r'$$')) inMath = true;
    } else if (line.trim().isEmpty) {
      cut = next;
    }
    offset = next;
  }
  return cut;
}

/// 流式/打字机专用的增量解析器：正文是「前缀追加」的，
/// 已封口的块只解析一次，每次只重解析最后一个未完成的块。
class MarkdownStreamParser {
  String _prefix = '';
  List<MarkdownBlock> _committed = const <MarkdownBlock>[];

  void reset() {
    _prefix = '';
    _committed = const <MarkdownBlock>[];
  }

  List<MarkdownBlock> parse(String text) {
    final source = text.replaceAll('\r\n', '\n');
    final cut = markdownStableCut(source);
    if (cut <= 0) return parseMarkdown(source);

    final prefix = source.substring(0, cut);
    if (prefix != _prefix) {
      _prefix = prefix;
      _committed = parseMarkdown(prefix);
    }
    final tail = source.substring(cut);
    if (tail.trim().isEmpty) return _committed;
    return <MarkdownBlock>[..._committed, ...parseMarkdown(tail)];
  }
}

/// Markdown 渲染：覆盖 Agent 回复里真正会出现的东西。
///
/// 不引第三方包：标题、段落、有序/无序/嵌套/任务列表、引用、分隔线、表格、
/// 代码块（含轻量高亮）、行内代码、粗体、斜体、删除线、链接、图片。
/// 视觉跟全站一致——等宽读数、发丝线、单一琥珀强调色。
class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown({super.key, required this.text, this.streaming = false});

  final String text;

  /// 流式/打字机期间启用增量解析；正式消息用全量解析拿到最终结构。
  final bool streaming;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  /// 解析结果只取决于正文，不取决于主题。父级因无关状态重建时，
  /// 历史消息不必再对整篇 Markdown 做 split + 逐行正则。
  String? _source;
  bool? _streaming;
  List<MarkdownBlock> _blocks = const <MarkdownBlock>[];
  final MarkdownStreamParser _streamParser = MarkdownStreamParser();

  @override
  Widget build(BuildContext context) {
    if (_source != widget.text || _streaming != widget.streaming) {
      _source = widget.text;
      if (_streaming != widget.streaming) {
        _streaming = widget.streaming;
        // 流式结束（或中途回退成整包消息）时丢弃增量缓存，
        // 重新按完整正文解析，避免残留半个代码块。
        _streamParser.reset();
      }
      _blocks = widget.streaming
          ? _streamParser.parse(widget.text)
          : parseMarkdown(widget.text);
    }
    final blocks = _blocks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < blocks.length; index++)
          Padding(
            padding: EdgeInsets.only(
              top: index == 0 ? 0 : _gapAfter(blocks[index - 1]),
            ),
            child: _buildBlock(context, blocks[index]),
          ),
      ],
    );
  }

  double _gapAfter(MarkdownBlock block) => switch (block) {
    MarkdownHeading() => FanxSpace.sm + 2,
    MarkdownCode() => FanxSpace.lg,
    MarkdownTable() => FanxSpace.lg,
    MarkdownMath() => FanxSpace.lg,
    MarkdownList() => FanxSpace.sm,
    MarkdownRule() => FanxSpace.lg,
    _ => FanxSpace.md,
  };

  Widget _buildBlock(BuildContext context, MarkdownBlock block) {
    final t = context.tokens;

    return switch (block) {
      MarkdownParagraph(:final text) => MarkdownText(text: text),
      MarkdownHeading(:final level, :final text) => Padding(
        padding: EdgeInsets.only(top: level <= 2 ? FanxSpace.sm : 0),
        child: MarkdownText(
          text: text,
          style: context.cnDisplay(
            size: switch (level) {
              1 => 21,
              2 => 18,
              _ => 15.5,
            },
            weight: FontWeight.w600,
            height: 1.4,
          ),
        ),
      ),
      MarkdownCode(:final code, :final language) => _CodeBlock(
        code: code,
        language: language,
      ),
      MarkdownQuote(:final text) => Container(
        padding: const EdgeInsets.fromLTRB(
          FanxSpace.md,
          FanxSpace.xs,
          0,
          FanxSpace.xs,
        ),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: t.accent.withValues(alpha: 0.5), width: 2),
          ),
        ),
        child: MarkdownText(
          text: text,
          style: context.texts.bodyLarge?.copyWith(
            color: t.textMuted,
            height: 1.7,
            fontFamilyFallback: FanxFonts.fallback,
          ),
        ),
      ),
      MarkdownList() => _ListBlock(block: block),
      MarkdownTable() => _TableBlock(block: block),
      MarkdownImage(:final alt, :final url) => _ImageBlock(alt: alt, url: url),
      MarkdownMath(:final latex) => _MathBlock(latex: latex),
      MarkdownRule() => Padding(
        padding: const EdgeInsets.symmetric(vertical: FanxSpace.sm),
        child: HairLine(color: t.border),
      ),
    };
  }
}

// ---------------------------------------------------------------------------
// 行内文本
// ---------------------------------------------------------------------------

/// 一段文本：没有行内标记时走纯文本，避免每次都构造 TextSpan；
/// 有标记时按 `code` / **bold** / *italic* / ~~strike~~ / [link](url) 拆 span。
///
/// 行内解析结果按「正文 + 样式 + 主题」缓存：流式刷新时历史段落会跟着
/// 父级 rebuild，但不必每 32ms 对同一段文字重跑一遍正则与 span 构造。
class MarkdownText extends StatefulWidget {
  const MarkdownText({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  FanxTokens? _tokens;
  String? _text;
  TextStyle? _base;
  List<InlineSpan>? _spans; // null 表示无行内标记，走纯文本

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final TextStyle base =
        widget.style ??
        context.texts.bodyLarge?.copyWith(
          color: t.text,
          height: 1.78,
          fontFamilyFallback: FanxFonts.fallback,
        ) ??
        const TextStyle();

    if (!identical(_tokens, t) || _text != widget.text || _base != base) {
      _tokens = t;
      _text = widget.text;
      _base = base;
      _spans = _inlinePattern.hasMatch(widget.text)
          ? _inlineSpans(context, widget.text, base)
          : null;
    }

    final spans = _spans;
    if (spans == null) return SelectableText(widget.text, style: base);
    return SelectableText.rich(TextSpan(style: base, children: spans));
  }
}

final RegExp _inlinePattern = RegExp(
  r'(`[^`\n]+`|\$\$[^$\n]+\$\$|\$[^$\n]+\$|\*\*[^*\n]+\*\*|~~[^~\n]+~~|\*[^*\n]+\*|!?\[[^\]\n]*\]\([^)\n]+\))',
);

/// 行内链接只做样式区分、不做跳转：SelectableText 里的 recognizer 会破坏选区。
List<InlineSpan> _inlineSpans(
  BuildContext context,
  String text,
  TextStyle base,
) {
  final t = context.tokens;
  final spans = <InlineSpan>[];
  var cursor = 0;

  for (final match in _inlinePattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    final token = match.group(0)!;

    if (token.startsWith(r'$')) {
      final inner = token.startsWith(r'$$')
          ? token.substring(2, token.length - 2)
          : token.substring(1, token.length - 1);
      // $5 这种价格不当公式：内容不带任何数学记号且不止一个短变量名，就原样输出。
      if (_looksLikeMath(inner)) {
        spans.addAll(buildMathSpans(inner, base, t));
      } else {
        spans.add(TextSpan(text: token));
      }
    } else if (token.startsWith('`')) {
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: base.copyWith(
            fontFamily: FanxFonts.mono,
            fontFamilyFallback: FanxFonts.monoFallback,
            fontSize: (base.fontSize ?? 15) - 1.5,
            backgroundColor: t.surfaceSunken,
            color: t.text,
          ),
        ),
      );
    } else if (token.startsWith('**')) {
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          style: base.copyWith(fontWeight: FontWeight.w600, color: t.text),
        ),
      );
    } else if (token.startsWith('~~')) {
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          style: base.copyWith(
            decoration: TextDecoration.lineThrough,
            color: t.textMuted,
          ),
        ),
      );
    } else if (token.startsWith('!')) {
      final closing = token.indexOf('](');
      spans.add(
        TextSpan(
          text: '[图片 ${token.substring(2, closing)}]',
          style: base.copyWith(color: t.accent, fontStyle: FontStyle.italic),
        ),
      );
    } else if (token.startsWith('[')) {
      final closing = token.indexOf('](');
      spans.add(
        TextSpan(
          text: token.substring(1, closing),
          style: base.copyWith(
            color: t.accent,
            decoration: TextDecoration.underline,
            decorationColor: t.accent.withValues(alpha: 0.4),
          ),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    }

    cursor = match.end;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}

// ---------------------------------------------------------------------------
// 列表
// ---------------------------------------------------------------------------

class _ListBlock extends StatelessWidget {
  const _ListBlock({required this.block});

  final MarkdownList block;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    // 每层自己的计数器：嵌套有序列表从各自的第一项重新编号。
    final counters = <int>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < block.items.length; index++)
          Builder(
            builder: (context) {
              final item = block.items[index];
              final depth = item.depth.clamp(0, 6);
              while (counters.length <= depth) {
                counters.add(0);
              }
              if (counters.length > depth + 1) {
                counters.removeRange(depth + 1, counters.length);
              }
              counters[depth] += 1;
              final number = block.ordered
                  ? (depth == 0 ? block.start : 1) + counters[depth] - 1
                  : 0;

              return Padding(
                padding: EdgeInsets.only(
                  left: depth * 16,
                  bottom: item.checked == null ? 3 : 5,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: block.ordered ? 24 : 16,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: item.checked != null
                            ? Icon(
                                item.checked!
                                    ? Icons.check_box_outlined
                                    : Icons.check_box_outline_blank,
                                size: 13,
                                color: item.checked! ? t.accent : t.textFaint,
                              )
                            : Text(
                                block.ordered
                                    ? '$number.'
                                    : const ['·', '◦', '▪'][depth % 3],
                                style: context.mono(
                                  size: 12,
                                  color: t.accent.withValues(alpha: 0.75),
                                ),
                              ),
                      ),
                    ),
                    Expanded(
                      child: MarkdownText(
                        text: item.text,
                        style: item.checked == true
                            ? context.texts.bodyLarge?.copyWith(
                                color: t.textMuted,
                                height: 1.75,
                                decoration: TextDecoration.lineThrough,
                                decorationColor: t.textFaint,
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 表格
// ---------------------------------------------------------------------------

class _TableBlock extends StatelessWidget {
  const _TableBlock({required this.block});

  final MarkdownTable block;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final border = BorderSide(color: t.border);

    TextStyle cellStyle({bool header = false}) =>
        (header ? context.texts.titleSmall : context.texts.bodyMedium)
            ?.copyWith(
              fontSize: header ? 11.5 : 12.5,
              height: 1.5,
              color: header ? t.text : t.textMuted,
              fontWeight: header ? FontWeight.w600 : FontWeight.w400,
            ) ??
        const TextStyle();

    TextAlign alignOf(int index) =>
        index < block.aligns.length ? block.aligns[index] : TextAlign.left;

    TableRow row(List<String> cells, {bool header = false}) {
      return TableRow(
        decoration: header ? BoxDecoration(color: t.surfaceSunken) : null,
        children: [
          for (var index = 0; index < block.columns; index++)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FanxSpace.md,
                vertical: FanxSpace.sm,
              ),
              child: Text(
                index < cells.length ? cells[index] : '',
                textAlign: alignOf(index),
                style: cellStyle(header: header),
              ),
            ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(FanxRadius.sm),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(horizontalInside: border, verticalInside: border),
          children: [
            row(block.headers, header: true),
            for (final cells in block.rows) row(cells),
          ],
        ),
      ),
    );
  }
}

class _ImageBlock extends StatelessWidget {
  const _ImageBlock({required this.alt, required this.url});

  final String alt;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return ClipRRect(
      borderRadius: BorderRadius.circular(FanxRadius.sm),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: t.border)),
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => Container(
            padding: const EdgeInsets.all(FanxSpace.md),
            color: t.surfaceSunken,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, size: 14, color: t.textFaint),
                const SizedBox(width: FanxSpace.sm),
                Flexible(
                  child: Text(
                    alt.isEmpty ? url : alt,
                    style: context.texts.bodySmall?.copyWith(fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 代码块 + 轻量高亮
// ---------------------------------------------------------------------------

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.code, required this.language});

  final String code;
  final String language;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  /// 高亮结果按「正文 + 语言 + 主题」缓存。流式刷新时已写完的代码块
  /// 会跟着父级 rebuild，但不必每次都对全文重跑一遍正则与 span 构造。
  FanxTokens? _tokens;
  String? _code;
  String? _language;
  List<InlineSpan>? _spans;

  List<InlineSpan> _highlight(BuildContext context) {
    final tokens = context.tokens;
    final cached = _spans;
    if (cached != null &&
        identical(_tokens, tokens) &&
        _code == widget.code &&
        _language == widget.language) {
      return cached;
    }
    final spans = highlightCode(widget.code, widget.language, context);
    _tokens = tokens;
    _code = widget.code;
    _language = widget.language;
    _spans = spans;
    return spans;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      decoration: BoxDecoration(
        color: t.surfaceSunken,
        borderRadius: BorderRadius.circular(FanxRadius.sm),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 27,
            padding: const EdgeInsets.only(left: FanxSpace.md, right: 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Text(
                  widget.language.isEmpty
                      ? 'CODE'
                      : widget.language.toUpperCase(),
                  style: context.monoLabel(size: 8.5, tracking: 1.6),
                ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(FanxRadius.xs),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FanxSpace.sm,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check : Icons.content_copy,
                          size: 10,
                          color: _copied ? t.success : t.textFaint,
                        ),
                        const SizedBox(width: FanxSpace.xs),
                        Text(
                          _copied ? '已复制' : '复制',
                          style: context.mono(
                            size: 9.5,
                            color: _copied ? t.success : t.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 320),
              child: Padding(
                padding: const EdgeInsets.all(FanxSpace.md),
                child: SelectableText.rich(
                  TextSpan(children: _highlight(context)),
                  style: context
                      .mono(size: 11.5, color: t.text, weight: FontWeight.w400)
                      .copyWith(height: 1.72),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const Map<String, Set<String>> _keywords = {
  'dart': {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'get',
    'if',
    'implements',
    'import',
    'in',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'on',
    'operator',
    'required',
    'return',
    'sealed',
    'set',
    'static',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'while',
    'with',
    'yield',
  },
  'ts': {
    'as',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'default',
    'delete',
    'do',
    'else',
    'enum',
    'export',
    'extends',
    'false',
    'finally',
    'for',
    'from',
    'function',
    'if',
    'implements',
    'import',
    'in',
    'instanceof',
    'interface',
    'let',
    'new',
    'null',
    'of',
    'private',
    'protected',
    'public',
    'readonly',
    'return',
    'static',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'try',
    'type',
    'typeof',
    'undefined',
    'var',
    'void',
    'while',
    'yield',
  },
  'python': {
    'and',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'class',
    'continue',
    'def',
    'del',
    'elif',
    'else',
    'except',
    'False',
    'finally',
    'for',
    'from',
    'global',
    'if',
    'import',
    'in',
    'is',
    'lambda',
    'None',
    'nonlocal',
    'not',
    'or',
    'pass',
    'raise',
    'return',
    'True',
    'try',
    'while',
    'with',
    'yield',
  },
  'shell': {
    'case',
    'cd',
    'do',
    'done',
    'echo',
    'elif',
    'else',
    'esac',
    'exit',
    'export',
    'fi',
    'for',
    'function',
    'if',
    'in',
    'local',
    'readonly',
    'return',
    'then',
    'until',
    'while',
  },
  'sql': {
    'and',
    'as',
    'asc',
    'by',
    'create',
    'delete',
    'desc',
    'from',
    'group',
    'having',
    'index',
    'inner',
    'insert',
    'into',
    'join',
    'left',
    'limit',
    'not',
    'null',
    'on',
    'or',
    'order',
    'outer',
    'right',
    'select',
    'set',
    'table',
    'update',
    'values',
    'where',
  },
  'json': {'true', 'false', 'null'},
  'yaml': {'true', 'false', 'null'},
};

String _langKey(String language) {
  final lang = language.toLowerCase();
  if (const ['js', 'javascript', 'tsx', 'jsx', 'typescript'].contains(lang)) {
    return 'ts';
  }
  if (const ['sh', 'bash', 'zsh', 'console', 'shell'].contains(lang)) {
    return 'shell';
  }
  if (const ['py', 'python3'].contains(lang)) return 'python';
  if (const ['yml'].contains(lang)) return 'yaml';
  return lang;
}

/// 每种语言只编译一次正则；代码块原来每次 rebuild 都要重拼关键字串再编译。
final Map<String, RegExp> _highlightPatterns = <String, RegExp>{};

RegExp _highlightPattern(String key) => _highlightPatterns.putIfAbsent(
  key,
  () => RegExp(
    '("(?:[^"\\\\\\n]|\\\\.)*"|\'(?:[^\'\\\\\\n]|\\\\.)*\'|`(?:[^`\\\\]|\\\\.)*`)'
    r'|(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)'
    r'|\b(\d+(?:\.\d+)?)\b'
    '|\\b(${_keywords[key]!.map(RegExp.escape).join('|')})\\b',
  ),
);

/// 轻量高亮：只上四种语义色（关键字/字符串/注释/数字），不做完整语法树。
List<InlineSpan> highlightCode(
  String code,
  String language,
  BuildContext context,
) {
  final t = context.tokens;
  final key = _langKey(language);
  if (!_keywords.containsKey(key)) return [TextSpan(text: code)];

  final pattern = _highlightPattern(key);
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in pattern.allMatches(code)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: code.substring(cursor, match.start)));
    }
    final style = match.group(1) != null
        ? TextStyle(color: t.success.withValues(alpha: 0.92))
        : match.group(2) != null
        ? TextStyle(color: t.textFaint, fontStyle: FontStyle.italic)
        : match.group(3) != null
        ? TextStyle(color: t.warning)
        : TextStyle(color: t.accent);
    spans.add(TextSpan(text: match.group(0), style: style));
    cursor = match.end;
  }
  if (cursor < code.length) {
    spans.add(TextSpan(text: code.substring(cursor)));
  }
  return spans;
}

// ---------------------------------------------------------------------------
// 数学公式（轻量 LaTeX 子集，不引第三方包）
// ---------------------------------------------------------------------------
//
// 覆盖常见记号：希腊字母、上下标、分数、根号、运算符/关系符、\text{}、
// \left/\right 分隔符、\quad 间距。渲染用数学字体的斜体衬线，不追真排版。

const Map<String, String> _mathSymbols = {
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'epsilon': 'ε',
  'zeta': 'ζ',
  'eta': 'η',
  'theta': 'θ',
  'iota': 'ι',
  'kappa': 'κ',
  'lambda': 'λ',
  'mu': 'μ',
  'nu': 'ν',
  'xi': 'ξ',
  'pi': 'π',
  'rho': 'ρ',
  'sigma': 'σ',
  'tau': 'τ',
  'upsilon': 'υ',
  'phi': 'φ',
  'chi': 'χ',
  'psi': 'ψ',
  'omega': 'ω',
  'Gamma': 'Γ',
  'Delta': 'Δ',
  'Theta': 'Θ',
  'Lambda': 'Λ',
  'Xi': 'Ξ',
  'Pi': 'Π',
  'Sigma': 'Σ',
  'Phi': 'Φ',
  'Psi': 'Ψ',
  'Omega': 'Ω',
  'sum': '∑',
  'prod': '∏',
  'int': '∫',
  'iint': '∬',
  'oint': '∮',
  'infty': '∞',
  'partial': '∂',
  'nabla': '∇',
  'hbar': 'ℏ',
  'leq': '≤',
  'le': '≤',
  'geq': '≥',
  'ge': '≥',
  'neq': '≠',
  'ne': '≠',
  'approx': '≈',
  'equiv': '≡',
  'sim': '∼',
  'propto': '∝',
  'times': '×',
  'cdot': '·',
  'div': '÷',
  'pm': '±',
  'mp': '∓',
  'in': '∈',
  'notin': '∉',
  'subset': '⊂',
  'subseteq': '⊆',
  'supset': '⊃',
  'supseteq': '⊇',
  'cup': '∪',
  'cap': '∩',
  'rightarrow': '→',
  'to': '→',
  'leftarrow': '←',
  'leftrightarrow': '↔',
  'Rightarrow': '⇒',
  'Leftarrow': '⇐',
  'Leftrightarrow': '⇔',
  'mapsto': '↦',
  'forall': '∀',
  'exists': '∃',
  'emptyset': '∅',
  'varnothing': '∅',
  'angle': '∠',
  'perp': '⊥',
  'parallel': '∥',
  'ldots': '…',
  'cdots': '⋯',
  'dots': '…',
  'vdots': '⋮',
  'ddots': '⋱',
  'prime': '′',
  'circ': '∘',
  'star': '⋆',
  'ast': '∗',
  'bullet': '∙',
  'oplus': '⊕',
  'otimes': '⊗',
  'ell': 'ℓ',
  'Re': 'ℜ',
  'Im': 'ℑ',
  'aleph': 'ℵ',
  'because': '∵',
  'therefore': '∴',
};

final RegExp _latinLetter = RegExp(r'[A-Za-z]');
final RegExp _shortVariable = RegExp(r'^[A-Za-z]{1,3}$');
final RegExp _compactMath = RegExp(r'^[A-Za-z0-9+\-*/=<>()[\].,|!%]+$');
final RegExp _mathOperator = RegExp(r'[+\-*/=<>^]');
final RegExp _hasDigit = RegExp(r'\d');

/// 判定 `$...$` 里的内容是不是公式。"$5 打折" 这种价格文案要放行。
bool _looksLikeMath(String source) {
  final value = source.trim();
  if (value.isEmpty || value.length > 200) return false;
  if (value.contains('\\') || value.contains('^') || value.contains('_')) {
    return true;
  }
  // 单个短变量名（x、n）也算
  if (_shortVariable.hasMatch(value)) return true;
  // 紧凑表达式：数字与字母混合，或带运算符/比较符
  if (!_compactMath.hasMatch(value)) return false;
  return _mathOperator.hasMatch(value) ||
      (_hasDigit.hasMatch(value) && _latinLetter.hasMatch(value));
}

/// 把 LaTeX 子集拆成 TextSpan。未知命令淡出原样显示，绝不静默吞内容。
List<InlineSpan> buildMathSpans(
  String latex,
  TextStyle base,
  FanxTokens tokens,
) {
  final style = base.copyWith(
    fontFamily: 'Cambria Math',
    fontFamilyFallback: const [
      'Cambria Math',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontStyle: FontStyle.italic,
    color: tokens.text,
  );
  final spans = <InlineSpan>[];
  var i = 0;

  void add(String text, {TextStyle? styleOverride}) {
    if (text.isEmpty) return;
    spans.add(TextSpan(text: text, style: styleOverride ?? style));
  }

  // 读 `{...}` 组或单个字符
  String readGroup() {
    while (i < latex.length && latex[i] == ' ') {
      i++;
    }
    if (i >= latex.length) return '';
    if (latex[i] == '{') {
      final start = ++i;
      var depth = 1;
      while (i < latex.length && depth > 0) {
        if (latex[i] == '{') depth++;
        if (latex[i] == '}') {
          depth--;
          if (depth == 0) break;
        }
        i++;
      }
      final group = latex.substring(start, i);
      if (i < latex.length) i++;
      return group;
    }
    return latex[i++];
  }

  while (i < latex.length) {
    final ch = latex[i];

    if (ch == '\\') {
      i++;
      if (i >= latex.length) break;
      final next = latex[i];
      if (!_latinLetter.hasMatch(next)) {
        i++;
        add(switch (next) {
          ',' || ':' || ';' => ' ',
          '!' => '',
          '\\' => '\n',
          _ => next,
        });
        continue;
      }

      final start = i;
      while (i < latex.length && _latinLetter.hasMatch(latex[i])) {
        i++;
      }
      final cmd = latex.substring(start, i);

      switch (cmd) {
        case 'frac' || 'dfrac' || 'tfrac':
          final numerator = readGroup();
          final denominator = readGroup();
          add('(');
          spans.addAll(buildMathSpans(numerator, base, tokens));
          add(
            ' ⁄ ',
            styleOverride: style.copyWith(fontStyle: FontStyle.normal),
          );
          spans.addAll(buildMathSpans(denominator, base, tokens));
          add(')');
        case 'sqrt':
          final inner = readGroup();
          add('√');
          spans.addAll(
            buildMathSpans(
              inner,
              style.copyWith(
                decoration: TextDecoration.overline,
                decorationColor: tokens.text,
              ),
              tokens,
            ),
          );
        case 'text' || 'mathrm' || 'operatorname' || 'textrm':
          add(
            readGroup(),
            styleOverride: style.copyWith(fontStyle: FontStyle.normal),
          );
        case 'mathbf' || 'boldsymbol' || 'mathbb':
          add(
            readGroup(),
            styleOverride: style.copyWith(
              fontStyle: FontStyle.normal,
              fontWeight: FontWeight.w700,
            ),
          );
        case 'mathit':
          add(readGroup());
        case 'left' || 'right':
          while (i < latex.length && latex[i] == ' ') {
            i++;
          }
          if (i < latex.length && latex[i] != '\\') {
            add(latex[i]);
            i++;
          }
        case 'begin' || 'end':
          readGroup();
          add(' ');
        case 'quad':
          add('　');
        case 'qquad':
          add('　　');
        default:
          final symbol = _mathSymbols[cmd];
          if (symbol != null) {
            add(symbol);
          } else {
            add(
              '\\$cmd',
              styleOverride: style.copyWith(
                color: tokens.textFaint,
                fontStyle: FontStyle.normal,
              ),
            );
          }
      }
      continue;
    }

    if (ch == '^' || ch == '_') {
      i++;
      final group = readGroup();
      final size = style.fontSize ?? base.fontSize ?? 15;
      final small = style.copyWith(fontSize: size * 0.72, height: 1.2);
      spans.addAll(buildMathSpans(group, small, tokens));
      continue;
    }

    if (ch == '{' || ch == '}') {
      i++;
      continue;
    }
    if (ch == '&' || ch == '~') {
      add(' ');
      i++;
      continue;
    }

    add(ch);
    i++;
  }

  return spans;
}

class _MathBlock extends StatelessWidget {
  const _MathBlock({required this.latex});

  final String latex;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base =
        context.texts.bodyLarge?.copyWith(fontSize: 16, height: 1.6) ??
        const TextStyle(fontSize: 16);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: FanxSpace.sm),
      child: Center(
        child: SelectableText.rich(
          TextSpan(children: buildMathSpans(latex, base, t)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

sealed class MarkdownBlock {
  const MarkdownBlock();
}

class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.text);
  final String text;
}

class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading(this.level, this.text);
  final int level;
  final String text;
}

class MarkdownCode extends MarkdownBlock {
  const MarkdownCode(this.language, this.code);
  final String language;
  final String code;
}

class MarkdownQuote extends MarkdownBlock {
  const MarkdownQuote(this.text);
  final String text;
}

class MarkdownList extends MarkdownBlock {
  const MarkdownList({
    required this.ordered,
    required this.start,
    required this.items,
  });

  final bool ordered;
  final int start;
  final List<MarkdownListItem> items;
}

class MarkdownListItem {
  const MarkdownListItem(this.text, this.depth, {this.checked});

  final String text;
  final int depth;

  /// 任务列表的勾选状态；普通条目为 null。
  final bool? checked;
}

class MarkdownTable extends MarkdownBlock {
  const MarkdownTable({
    required this.headers,
    required this.aligns,
    required this.rows,
  });

  final List<String> headers;
  final List<TextAlign> aligns;
  final List<List<String>> rows;

  int get columns => headers.length;
}

class MarkdownImage extends MarkdownBlock {
  const MarkdownImage(this.alt, this.url);
  final String alt;
  final String url;
}

/// 数学公式块（`$$ ... $$`）。
class MarkdownMath extends MarkdownBlock {
  const MarkdownMath(this.latex);
  final String latex;
}

class MarkdownRule extends MarkdownBlock {
  const MarkdownRule();
}

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _quotePattern = RegExp(r'^>\s?(.*)$');
final RegExp _taskPattern = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$');
final RegExp _unorderedPattern = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final RegExp _orderedPattern = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final RegExp _rulePattern = RegExp(r'^\s*([-*_])\1{2,}\s*$');
final RegExp _imagePattern = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)$');
final RegExp _tableSeparator = RegExp(
  r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$',
);

bool _isTableStart(List<String> lines, int index) {
  if (index + 1 >= lines.length) return false;
  final head = lines[index].trim();
  if (!head.contains('|')) return false;
  return _tableSeparator.hasMatch(lines[index + 1].trim());
}

List<String> _splitRow(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  return text.split('|').map((cell) => cell.trim()).toList(growable: true);
}

TextAlign _alignOf(String cell) {
  final value = cell.trim();
  final left = value.startsWith(':');
  final right = value.endsWith(':');
  if (left && right) return TextAlign.center;
  if (right) return TextAlign.right;
  return TextAlign.left;
}

/// 把 Markdown 拆成块。行内语法留给渲染阶段处理。
List<MarkdownBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];
  List<MarkdownListItem>? listItems;
  bool listOrdered = false;
  bool listTask = false;
  int listStart = 1;

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    final text = paragraph.join('\n').trim();
    paragraph.clear();
    if (text.isEmpty) return;
    final image = _imagePattern.firstMatch(text);
    if (image != null) {
      blocks.add(MarkdownImage(image.group(1) ?? '', image.group(2) ?? ''));
      return;
    }
    blocks.add(MarkdownParagraph(text));
  }

  void flushList() {
    final items = listItems;
    if (items == null || items.isEmpty) return;
    blocks.add(
      MarkdownList(ordered: listOrdered, start: listStart, items: items),
    );
    listItems = null;
    listTask = false;
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trimRight();

    // 代码围栏：整段原样保留，不解析里面的 Markdown。
    if (trimmed.trimLeft().startsWith('```')) {
      flushParagraph();
      flushList();
      final language = trimmed.trimLeft().substring(3).trim();
      final code = <String>[];
      index += 1;
      while (index < lines.length &&
          !lines[index].trimLeft().startsWith('```')) {
        code.add(lines[index]);
        index += 1;
      }
      index += 1;
      blocks.add(MarkdownCode(language, code.join('\n')));
      continue;
    }

    // 数学公式块：$$ 开头，收集到下一个 $$ 结束（同一行闭合也支持）
    if (trimmed.trimLeft().startsWith('\$\$')) {
      flushParagraph();
      flushList();
      var rest = trimmed.trimLeft().substring(2);
      final buffer = <String>[];
      var closed = false;
      final sameLine = rest.indexOf('\$\$');
      if (sameLine != -1) {
        buffer.add(rest.substring(0, sameLine));
        closed = true;
        index += 1;
      } else {
        if (rest.trim().isNotEmpty) buffer.add(rest);
        index += 1;
        while (index < lines.length && !closed) {
          final line = lines[index];
          final end = line.indexOf('\$\$');
          if (end != -1) {
            buffer.add(line.substring(0, end));
            closed = true;
          } else {
            buffer.add(line);
          }
          index += 1;
        }
      }
      final latex = buffer.join('\n').trim();
      if (latex.isNotEmpty) blocks.add(MarkdownMath(latex));
      continue;
    }

    if (trimmed.trim().isEmpty) {
      flushParagraph();
      flushList();
      index += 1;
      continue;
    }

    // 表格：当前行含 |，下一行是分隔线
    if (_isTableStart(lines, index)) {
      flushParagraph();
      flushList();
      final headers = _splitRow(lines[index]);
      final separator = _splitRow(lines[index + 1]);
      final aligns = [
        for (var i = 0; i < headers.length; i++)
          _alignOf(i < separator.length ? separator[i] : '---'),
      ];
      final rows = <List<String>>[];
      index += 2;
      while (index < lines.length) {
        final row = lines[index].trim();
        if (row.isEmpty || !row.contains('|')) break;
        final cells = _splitRow(row);
        // 行短了补空，长了并进最后一格，避免 Table 列数不一致。
        if (cells.length < headers.length) {
          cells.addAll(List.filled(headers.length - cells.length, ''));
        } else if (cells.length > headers.length) {
          final head = cells.take(headers.length - 1).toList();
          head.add(cells.skip(headers.length - 1).join(' | '));
          rows.add(head);
          index += 1;
          continue;
        }
        rows.add(cells);
        index += 1;
      }
      blocks.add(MarkdownTable(headers: headers, aligns: aligns, rows: rows));
      continue;
    }

    if (_rulePattern.hasMatch(trimmed)) {
      flushParagraph();
      flushList();
      blocks.add(const MarkdownRule());
      index += 1;
      continue;
    }

    final heading = _headingPattern.firstMatch(trimmed);
    if (heading != null) {
      flushParagraph();
      flushList();
      blocks.add(
        MarkdownHeading(heading.group(1)!.length, heading.group(2)!.trim()),
      );
      index += 1;
      continue;
    }

    final quote = _quotePattern.firstMatch(trimmed);
    if (quote != null) {
      flushParagraph();
      flushList();
      final buffer = <String>[quote.group(1) ?? ''];
      index += 1;
      while (index < lines.length) {
        final next = _quotePattern.firstMatch(lines[index].trimRight());
        if (next == null) break;
        buffer.add(next.group(1) ?? '');
        index += 1;
      }
      blocks.add(MarkdownQuote(buffer.join('\n').trim()));
      continue;
    }

    final task = _taskPattern.firstMatch(trimmed);
    final unordered = task == null
        ? _unorderedPattern.firstMatch(trimmed)
        : null;
    final ordered = (task == null && unordered == null)
        ? _orderedPattern.firstMatch(trimmed)
        : null;

    if (task != null || unordered != null || ordered != null) {
      flushParagraph();
      final match = task ?? unordered ?? ordered!;
      final indent = match.group(1)!.length;
      final depth = (indent ~/ 2).clamp(0, 6);
      final isOrdered = ordered != null;
      final isTask = task != null;
      // 有序/无序交替、任务列表与普通列表交替时必须断开。
      if (listItems != null &&
          (listOrdered != isOrdered || (listTask != isTask))) {
        flushList();
      }
      if (listItems == null) {
        listItems = <MarkdownListItem>[];
        listOrdered = isOrdered;
        listTask = isTask;
        listStart = ordered == null ? 1 : int.tryParse(ordered.group(2)!) ?? 1;
      }
      if (task != null) {
        listItems!.add(
          MarkdownListItem(
            task.group(3)!.trim(),
            depth,
            checked: task.group(2)!.toLowerCase() == 'x',
          ),
        );
      } else if (unordered != null) {
        listItems!.add(MarkdownListItem(unordered.group(2)!.trim(), depth));
      } else {
        listItems!.add(MarkdownListItem(ordered!.group(3)!.trim(), depth));
      }
      index += 1;
      continue;
    }

    flushList();
    paragraph.add(trimmed);
    index += 1;
  }

  flushParagraph();
  flushList();
  return blocks;
}
