import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';
import 'chat_empty.dart';
import 'chat_markdown.dart';

/// 一个 Agent 的对话面板：进入时拉状态并订阅事件流，切换 Agent 或会话时整体重建。
///
/// 版式是「运行日志」而不是聊天软件：助手回复走文档流（Markdown、代码块、轮次编号），
/// 用户输入是右对齐的指令条。长回答按文档读，短指令按命令看。
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.agent,
    this.onState,
    this.initialState,
    this.expectedSessionId,
    this.pending = false,
    this.preview = false,
    this.onActivate,
    this.onOpenModels,
  });

  final Agent agent;
  final ValueChanged<AgentState>? onState;
  final AgentState? initialState;

  /// 当前查看的会话号。SSE 只接收属于它的事件，避免预览时串到别的会话。
  final String? expectedSessionId;

  /// 目标会话没有本地缓存时先显示骨架，且暂不订阅 SSE。
  final bool pending;

  /// 只读预览：看的是历史会话，后端仍停在原会话上。
  /// 此时不切换 runtime，只有真的发出新消息才激活。
  final bool preview;

  /// 发送前激活目标会话；由父级执行，返回 false 表示没切成、不要发送。
  final Future<bool> Function(String sessionId)? onActivate;

  /// 空态里点「管理模型」时切到工作区的模型标签页。
  final VoidCallback? onOpenModels;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

/// 打字机按 UTF-16 code unit 推进，别把 emoji / 生僻字的代理对切成半个。
/// 公开是为了让测试能直接覆盖代理对边界。
String revealPrefix(String text, int reveal) {
  var end = reveal.clamp(0, text.length);
  if (end > 0 && end < text.length) {
    final unit = text.codeUnitAt(end);
    if (unit >= 0xDC00 && unit <= 0xDFFF) end -= 1;
  }
  return text.substring(0, end);
}

/// 高频变化的「实时区」：流式正文、思考中、打字机进度。
/// 放进 ValueNotifier 后，token 与 Ticker 只重建最后一条消息，
/// 不再让整个 ChatPanel（含所有历史消息）跟着 rebuild。
class _LiveState {
  const _LiveState({
    required this.streamText,
    required this.thinking,
    required this.typingIndex,
    required this.revealTotal,
    required this.revealed,
  });

  final String streamText;
  final bool thinking;
  final int typingIndex;
  final int revealTotal;
  final int revealed;

  static const _LiveState empty = _LiveState(
    streamText: '',
    thinking: false,
    typingIndex: -1,
    revealTotal: 0,
    revealed: 0,
  );

  _LiveState copyWith({
    String? streamText,
    bool? thinking,
    int? typingIndex,
    int? revealTotal,
    int? revealed,
  }) => _LiveState(
    streamText: streamText ?? this.streamText,
    thinking: thinking ?? this.thinking,
    typingIndex: typingIndex ?? this.typingIndex,
    revealTotal: revealTotal ?? this.revealTotal,
    revealed: revealed ?? this.revealed,
  );
}

class _ChatPanelState extends State<ChatPanel> with TickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();

  StreamSubscription<Map<String, dynamic>>? _subscription;
  AgentState _state = AgentState.empty;
  bool _loading = true;
  String? _error;
  bool _awayFromBottom = false;

  final ValueNotifier<_LiveState> _live = ValueNotifier<_LiveState>(
    _LiveState.empty,
  );

  /// 流式正文用 StringBuffer 累积，避免 Dart 字符串 `+=` 的 O(n²) 拷贝。
  final StringBuffer _streamBuffer = StringBuffer();
  int _streamLength = 0;
  DateTime _lastStreamFlush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRevealFlush = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _throttleFromChars = 800;
  static const Duration _throttleInterval = Duration(milliseconds: 32);

  /// 打字机：provider 不流式时（本机网关整包返回），最终消息到达后按
  /// 字符数平滑展开，视觉上仍像逐字输出。
  // 必须在 initState 里创建：惰性初始化会让 dispose 里第一次触发
  // createTicker，那时元素已 deactivate，查 TickerMode 会崩。
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    final seed = widget.initialState;
    if (seed != null) {
      _state = seed;
      _loading = false;
    }
    _scroll.addListener(_onScroll);
    _bootstrap(seeded: seed != null, pending: widget.pending);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _live.dispose();
    _subscription?.cancel();
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 用户往上翻的时候不要再自动拽回底部，只给一个「回到最新」的入口。
  /// 进出各留一段回差，自动滚动时不会在阈值边缘反复切换状态。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final distance = _scroll.position.maxScrollExtent - _scroll.offset;
    final away = _awayFromBottom ? distance > 80 : distance > 160;
    if (away != _awayFromBottom) {
      setState(() => _awayFromBottom = away);
    }
  }

  Future<void> _bootstrap({bool seeded = false, bool pending = false}) async {
    if (seeded) {
      _scrollToBottom(animate: false);
    } else {
      try {
        final state = await appState.client.getState(widget.agent.id);
        if (!mounted) return;
        setState(() {
          _state = state;
          _loading = false;
        });
        _scrollToBottom();
      } on ApiException catch (exception) {
        if (mounted) {
          setState(() {
            _error = exception.message;
            _loading = false;
          });
        }
      }
    }

    // 预览缓存还没读回来时先不连 SSE，骨架窗口里没有可展示的事件。
    // 连上之后后端会按 ?session= 过滤：看历史会话时不会收到当前会话的
    // token，激活目标会话后同一条连接会自然开始收事件，无需重建。
    if (pending) return;

    _subscription = appState.client
        .events(widget.agent.id, sessionId: widget.expectedSessionId)
        .listen(
          (event) {
            if (!mounted) return;
            final type = event['type'];
            final payload = event['state'];
            if (type == 'state' && payload is Map<String, dynamic>) {
              // 切换窗口里旧连接仍可能推来上一个会话的快照。先看轻量的
              // sessionId，不匹配就直接丢，连全量 fromJson 都省掉。
              final incomingId = payload['sessionId'];
              final expected = widget.expectedSessionId;
              if (expected != null &&
                  incomingId is String &&
                  incomingId.isNotEmpty &&
                  incomingId != expected) {
                return;
              }
              final next = AgentState.fromJson(payload);
              final wasBusy = _state.busy;
              final grew = next.messages.length > _state.messages.length;
              // 只有最终消息到达或这一轮结束时流式缓冲才退场：一轮里
              // 工具/agent_end 也会推 state，无条件清空会让正文倒退重来。
              if (grew || !next.busy) {
                _resetStream();
                _live.value = _live.value.copyWith(
                  streamText: '',
                  thinking: false,
                );
              }
              setState(() => _state = next);
              if (wasBusy && grew && next.messages.isNotEmpty) {
                final last = next.messages.last;
                if (last.isAssistant &&
                    !last.failed &&
                    last.text.trim().isNotEmpty) {
                  _startTyping(next.messages.length - 1, last.text);
                }
              }
              if (!_awayFromBottom) _scrollToBottom();
              widget.onState?.call(next);
            } else if (type == 'delta' && event['text'] is String) {
              _appendDelta(event['text'] as String);
            } else if (type == 'thinking') {
              _live.value = _live.value.copyWith(thinking: true);
            } else if (type == 'text_start') {
              _live.value = _live.value.copyWith(thinking: false);
            } else if (type == 'error' && event['message'] is String) {
              setState(() => _error = event['message'] as String);
            }
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() => _error = '事件流断开：$error');
          },
        );
  }

  /// token 增量：只写缓冲并更新实时区，不碰父级 setState。
  /// 短回复逐 token 实时刷新；超过 800 字后合并到约 30fps，避免每个 token
  /// 都重写整段正文并重新排版。最终 state 到达时会换成正式消息。
  void _appendDelta(String text) {
    _streamBuffer.write(text);
    _streamLength += text.length;
    final now = DateTime.now();
    if (_streamLength >= _throttleFromChars &&
        now.difference(_lastStreamFlush) < _throttleInterval) {
      return;
    }
    _flushStream(now);
  }

  void _flushStream(DateTime now) {
    _lastStreamFlush = now;
    _live.value = _live.value.copyWith(
      streamText: _streamBuffer.toString(),
      thinking: false,
    );
    // 流式期间直接跟随内容高度，不再每 token 启动一次被打断的滚动动画。
    if (!_awayFromBottom) _scrollToBottom(animate: false);
  }

  void _resetStream() {
    _streamBuffer.clear();
    _streamLength = 0;
    _lastStreamFlush = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 平滑展开最新一条回复。总时长按长度收敛在 0.7–2.8s，短回复不拖沓、
  /// 长回复也不会让人干等。
  void _startTyping(int index, String text) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) return;
    _live.value = _live.value.copyWith(
      typingIndex: index,
      revealTotal: text.length,
      revealed: 0,
    );
    _lastRevealFlush = DateTime.fromMillisecondsSinceEpoch(0);
    _ticker.stop();
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final live = _live.value;
    if (live.revealTotal <= 0) {
      _ticker.stop();
      return;
    }
    final durationMs = (700 + live.revealTotal * 1.2).clamp(700, 2800).toInt();
    final progress = (elapsed.inMilliseconds / durationMs).clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(progress);
    final target = (live.revealTotal * eased).round();
    // 打字机期间每帧都要重解析 Markdown，合并到约 30fps；
    // 结束帧直接落到完整正文，不会卡在半截。
    final now = DateTime.now();
    final due = now.difference(_lastRevealFlush) >= _throttleInterval;
    if (due && target != live.revealed) {
      _lastRevealFlush = now;
      _live.value = live.copyWith(revealed: target);
    }
    if (progress >= 1.0) {
      _ticker.stop();
      _live.value = _live.value.copyWith(revealTotal: 0, typingIndex: -1);
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: FanxMotion.base,
          curve: FanxMotion.out,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  /// 预览态只在真的要发消息时才切后端会话。点侧栏看历史不付这个代价，
  /// 切换期间后端事件仍按会话号过滤，激活成功后同一条 SSE 会自然接上。
  Future<bool> _ensureActive() async {
    if (!widget.preview) return true;
    final id = widget.expectedSessionId;
    final activate = widget.onActivate;
    if (id == null || activate == null) return true;
    try {
      return await activate(id);
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
      return false;
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _state.busy) return;
    // 激活失败时保留输入，别让用户白打一遍。
    if (!await _ensureActive()) return;
    _input.clear();
    _resetStream();
    _live.value = _live.value.copyWith(streamText: '', thinking: false);
    setState(() => _error = null);
    try {
      await appState.client.sendMessage(widget.agent.id, text);
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    }
    _inputFocus.requestFocus();
    _scrollToBottom();
  }

  Future<void> _abort() async {
    try {
      await appState.client.runAction(widget.agent.id, 'abort');
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    }
  }

  /// 重试：把最后一条用户消息原样再发一次。失败消息不参与，避免叠罗汉。
  Future<void> _retryLast() async {
    ChatMessage? lastUser;
    for (final message in _state.messages) {
      if (message.isUser) lastUser = message;
    }
    if (lastUser == null || _state.busy) return;
    if (!await _ensureActive()) return;
    _resetStream();
    _live.value = _live.value.copyWith(streamText: '', thinking: false);
    setState(() => _error = null);
    try {
      await appState.client.sendMessage(widget.agent.id, lastUser.text);
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    }
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    // 切换到没缓存的会话时立刻显示骨架，不再把旧会话画面留在原地。
    if (widget.pending || _loading) return const _ChatSkeleton();

    final messages = _state.messages;
    // 模型调用失败已经由对应的消息卡片原样展示，顶部不再重复；
    // 只有"没有留下消息的失败"（事件流断开、prompt 抛异常）才走这条横幅。
    final hasFailureCard = messages.any((message) => message.failed);
    final error = _error ?? (hasFailureCard ? null : _state.lastError);

    // 列表作为 child 缓存：itemCount 不随实时状态变化，ValueNotifier 通知时
    // ListView 本身不重建，只有订阅了 _live 的末尾两项会更新。
    final list = _MessageList(
      scroll: _scroll,
      messages: messages,
      modelLabel: _state.modelLabel,
      busy: _state.busy,
      live: _live,
      onRetry: () => _retryLast(),
    );

    return Column(
      children: [
        if (error != null)
          InlineNotice(
            message: error,
            onDismiss: () => setState(() => _error = null),
          ),
        Expanded(
          child: ValueListenableBuilder<_LiveState>(
            valueListenable: _live,
            builder: (context, live, child) {
              final showEmpty =
                  messages.isEmpty &&
                  !_state.busy &&
                  live.streamText.isEmpty &&
                  !live.thinking;
              if (showEmpty) {
                return ChatEmptyState(
                  agent: widget.agent,
                  runtimeModelLabel: _state.modelLabel,
                  onOpenModels: widget.onOpenModels,
                );
              }
              return Stack(
                children: [
                  child!,
                  Positioned(
                    right: FanxSpace.xl,
                    bottom: FanxSpace.sm,
                    child: IgnorePointer(
                      ignoring: !_awayFromBottom,
                      child: AnimatedOpacity(
                        duration: FanxMotion.fast,
                        opacity: _awayFromBottom ? 1 : 0,
                        child: _JumpToLatest(onTap: () => _scrollToBottom()),
                      ),
                    ),
                  ),
                ],
              );
            },
            child: list,
          ),
        ),
        HairLine(color: t.border),
        _Composer(
          controller: _input,
          focusNode: _inputFocus,
          busy: _state.busy,
          modelLabel: _state.modelLabel,
          onSend: _send,
          onAbort: _abort,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 消息列表
// ---------------------------------------------------------------------------

/// 消息列表：末尾固定留一个实时行（内容为空时收成零高度），itemCount 因此
/// 与高频状态无关，整个 ListView 才能作为 ValueListenableBuilder 的 child 复用。
/// 只有「实时行」和「最后一条消息」订阅 _live，历史消息不随 token 重建。
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.scroll,
    required this.messages,
    required this.modelLabel,
    required this.busy,
    required this.live,
    required this.onRetry,
  });

  final ScrollController scroll;
  final List<ChatMessage> messages;
  final String? modelLabel;
  final bool busy;
  final ValueNotifier<_LiveState> live;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xl,
        FanxSpace.lg,
        FanxSpace.xl,
        FanxSpace.md,
      ),
      itemCount: messages.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _SessionStart(count: messages.length, modelLabel: modelLabel);
        }
        if (index == messages.length + 1) {
          return ValueListenableBuilder<_LiveState>(
            valueListenable: live,
            builder: (context, value, _) {
              if (value.streamText.isNotEmpty) {
                return _StreamingMessage(
                  text: value.streamText,
                  index: index + 1,
                );
              }
              if (busy || value.thinking) {
                return _GeneratingRow(thinking: value.thinking);
              }
              return const SizedBox.shrink();
            },
          );
        }

        final message = messages[index - 1];
        if (index == messages.length) {
          // 打字机只作用于最后一条回复。
          return ValueListenableBuilder<_LiveState>(
            valueListenable: live,
            builder: (context, value, _) => _MessageBlock(
              message: message,
              index: index,
              isLast: true,
              reveal: value.typingIndex == index - 1 && value.revealTotal > 0
                  ? value.revealed
                  : null,
              onRetry: onRetry,
            ),
          );
        }
        return _MessageBlock(message: message, index: index, isLast: false);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 会话起点
// ---------------------------------------------------------------------------

class _SessionStart extends StatelessWidget {
  const _SessionStart({required this.count, required this.modelLabel});

  final int count;
  final String? modelLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(bottom: FanxSpace.xl),
      child: Row(
        children: [
          Expanded(child: HairLine(color: t.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
            child: Row(
              children: [
                MetaTag(
                  'SESSION START · ${'$count'.padLeft(2, '0')} MESSAGES',
                  size: 9,
                  tracking: 1.6,
                  bracket: true,
                ),
                if (modelLabel != null) ...[
                  const SizedBox(width: FanxSpace.sm),
                  Text(
                    modelLabel!.toUpperCase(),
                    style: context.mono(size: 8.5, color: t.textFaint),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: HairLine(color: t.border)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 消息
// ---------------------------------------------------------------------------

class _MessageBlock extends StatelessWidget {
  const _MessageBlock({
    required this.message,
    required this.index,
    required this.isLast,
    this.onRetry,
    this.reveal,
  });

  final ChatMessage message;
  final int index;
  final bool isLast;
  final VoidCallback? onRetry;

  /// 打字机进行中：只渲染前 N 个字符；null 表示整条展示。
  final int? reveal;

  @override
  Widget build(BuildContext context) {
    return message.isUser
        ? _UserMessage(message: message, index: index)
        : _AssistantMessage(
            message: message,
            index: index,
            isLast: isLast,
            onRetry: onRetry,
            reveal: reveal,
          );
  }
}

/// 用户指令：右对齐的窄条，右侧一条琥珀边，和正文的左侧书脊形成对照。
class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.message, required this.index});

  final ChatMessage message;
  final int index;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(bottom: FanxSpace.xl, left: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${message.text.length} 字',
                style: context.mono(size: 9, color: t.textFaint),
              ),
              const SizedBox(width: FanxSpace.sm),
              _CopyAction(text: message.text, compact: true),
              const SizedBox(width: FanxSpace.xs),
              MetaTag(
                'YOU · ${'$index'.padLeft(2, '0')}',
                size: 9,
                tracking: 1.6,
              ),
            ],
          ),
          const SizedBox(height: FanxSpace.xs + 2),
          Container(
            constraints: const BoxConstraints(maxWidth: 640),
            padding: const EdgeInsets.fromLTRB(
              FanxSpace.lg,
              FanxSpace.md,
              FanxSpace.md + 2,
              FanxSpace.md,
            ),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: t.isDark ? t.surface : t.surfaceRaised,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(FanxRadius.sm),
                topRight: Radius.circular(FanxRadius.xs),
                bottomLeft: Radius.circular(FanxRadius.sm),
                bottomRight: Radius.circular(FanxRadius.xs),
              ),
              border: Border.all(color: t.border),
            ),
            // 右缘的琥珀竖条用叠层画：圆角容器不允许非均匀边框。
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: SelectableText(
                    message.text,
                    style: context.texts.bodyLarge?.copyWith(
                      color: t.text,
                      height: 1.65,
                      fontFamilyFallback: FanxFonts.fallback,
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: 2,
                  child: ColoredBox(color: t.accent.withValues(alpha: 0.65)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 助手回复：左侧轮次书脊 + 文档流正文。长回答按文章读，代码块自带语言标签。
class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.index,
    required this.isLast,
    this.onRetry,
    this.reveal,
  });

  final ChatMessage message;
  final int index;
  final bool isLast;
  final VoidCallback? onRetry;
  final int? reveal;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final empty = message.text.trim().isEmpty;
    final failed = message.failed;

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? FanxSpace.md : FanxSpace.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Text(
                  '$index'.padLeft(2, '0'),
                  style: context.mono(size: 9, color: t.textFaint),
                ),
                const SizedBox(height: FanxSpace.xs + 1),
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: message.pending ? t.accentWash : Colors.transparent,
                    border: Border.all(
                      color: message.pending
                          ? t.accent
                          : t.accent.withValues(alpha: 0.55),
                    ),
                    borderRadius: BorderRadius.circular(FanxRadius.xs),
                  ),
                  child: Icon(Icons.auto_awesome, size: 9, color: t.accent),
                ),
              ],
            ),
          ),
          const SizedBox(width: FanxSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    MetaTag(
                      message.pending
                          ? 'ASSISTANT · GENERATING'
                          : failed
                          ? 'ASSISTANT · FAILED'
                          : 'ASSISTANT',
                      size: 9,
                      tracking: 1.7,
                      color: message.pending
                          ? t.accent
                          : failed
                          ? t.danger
                          : t.textFaint,
                    ),
                    if (message.pending) ...[
                      const SizedBox(width: FanxSpace.sm),
                      FanxSpinner(size: 10),
                    ],
                    const Spacer(),
                    if (!empty && !failed)
                      Text(
                        '${message.text.length} 字',
                        style: context.mono(size: 9, color: t.textFaint),
                      ),
                    if (!empty && !failed) ...[
                      const SizedBox(width: FanxSpace.xs),
                      _CopyAction(text: message.text, compact: true),
                    ],
                  ],
                ),
                const SizedBox(height: FanxSpace.xs + 2),
                ConstrainedBox(
                  // 正文行宽控制在 760：再宽就成了"读不到的横排"。
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Container(
                    padding: const EdgeInsets.only(left: FanxSpace.lg),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: message.pending
                              ? t.accent.withValues(alpha: 0.5)
                              : t.border,
                        ),
                      ),
                    ),
                    child: failed
                        ? _FailureBlock(message: message, onRetry: onRetry)
                        : message.pending && empty
                        ? const _Thinking()
                        : reveal == null
                        ? ChatMarkdown(text: empty ? '（空回复）' : message.text)
                        : ChatMarkdown(
                            text: empty
                                ? '（空回复）'
                                : revealPrefix(message.text, reveal!),
                            streaming: true,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 生成中的占位：三行渐隐骨架，比一个转圈更能说明"正在写"。
class _GeneratingRow extends StatelessWidget {
  const _GeneratingRow({this.thinking = false});

  final bool thinking;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FanxSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 26,
            child: Padding(
              padding: EdgeInsets.only(top: 4),
              child: FanxSpinner(size: 12),
            ),
          ),
          SizedBox(width: FanxSpace.sm),
          Expanded(child: _Thinking(label: thinking ? '模型在思考…' : '正在生成…')),
        ],
      ),
    );
  }
}

/// 流式消息：正文随 token 到达逐段长出，这就是"打字机"。
class _StreamingMessage extends StatelessWidget {
  const _StreamingMessage({required this.text, required this.index});

  final String text;
  final int index;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(bottom: FanxSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Text(
                  '$index'.padLeft(2, '0'),
                  style: context.mono(size: 9, color: t.textFaint),
                ),
                const SizedBox(height: FanxSpace.xs + 1),
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.accentWash,
                    border: Border.all(color: t.accent),
                    borderRadius: BorderRadius.circular(FanxRadius.xs),
                  ),
                  child: Icon(Icons.auto_awesome, size: 9, color: t.accent),
                ),
              ],
            ),
          ),
          const SizedBox(width: FanxSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    MetaTag(
                      'ASSISTANT · STREAMING',
                      size: 9,
                      tracking: 1.7,
                      color: t.accent,
                    ),
                    const SizedBox(width: FanxSpace.sm),
                    StatusDot(color: t.accent, pulsing: true, size: 5),
                    const Spacer(),
                    Text(
                      '${text.length} 字',
                      style: context.mono(size: 9, color: t.textFaint),
                    ),
                  ],
                ),
                const SizedBox(height: FanxSpace.xs + 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Container(
                    padding: const EdgeInsets.only(left: FanxSpace.lg),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: t.accent.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                    // 流式正文同样走完整 Markdown；ChatMarkdown 的增量解析
                    // 只重算最后一个未封口的块，已完成的块沿用缓存。
                    child: ChatMarkdown(text: text, streaming: true),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({this.label = '正在生成…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.mono(size: 10, color: t.textMuted)),
        const SizedBox(height: FanxSpace.sm),
        const SkeletonBox(height: 10, width: double.infinity),
        const SizedBox(height: 7),
        const SkeletonBox(
          height: 10,
          width: double.infinity,
          delay: Duration(milliseconds: 140),
        ),
        const SizedBox(height: 7),
        const SkeletonBox(
          height: 10,
          width: 200,
          delay: Duration(milliseconds: 280),
        ),
      ],
    );
  }
}

/// 失败卡片：原样摆出 pi 的报错，再补一句能行动的话。
class _FailureBlock extends StatelessWidget {
  const _FailureBlock({required this.message, this.onRetry});

  final ChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final raw = message.errorMessage?.trim();
    final hint = message.errorHint;
    final endpoint = [
      message.provider,
      message.model,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' / ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.md,
        FanxSpace.md,
        FanxSpace.md,
        FanxSpace.sm,
      ),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: t.isDark ? 0.10 : 0.05),
        border: Border(
          left: BorderSide(color: t.danger, width: 2),
          top: BorderSide(color: t.danger.withValues(alpha: 0.25)),
          right: BorderSide(color: t.danger.withValues(alpha: 0.25)),
          bottom: BorderSide(color: t.danger.withValues(alpha: 0.25)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 13, color: t.danger),
              const SizedBox(width: FanxSpace.xs + 1),
              Text(
                '模型调用失败',
                style: context.texts.titleSmall?.copyWith(
                  fontSize: 12,
                  color: t.danger,
                ),
              ),
              const Spacer(),
              if (message.durationMs != null)
                Text(
                  '${(message.durationMs! / 1000).toStringAsFixed(1)} s',
                  style: context.mono(size: 9, color: t.textFaint),
                ),
            ],
          ),
          const SizedBox(height: FanxSpace.sm),
          SelectableText(
            raw == null || raw.isEmpty ? 'pi 没有返回具体原因，只给了一条空消息。' : raw,
            style: context
                .mono(size: 11, color: t.text, weight: FontWeight.w400)
                .copyWith(height: 1.6),
          ),
          if (hint != null) ...[
            const SizedBox(height: FanxSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.subdirectory_arrow_right,
                    size: 12,
                    color: t.danger,
                  ),
                ),
                const SizedBox(width: FanxSpace.xs),
                Expanded(
                  child: Text(
                    hint,
                    style: context.texts.bodySmall?.copyWith(
                      fontSize: 11.5,
                      color: t.text,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: FanxSpace.sm),
          Row(
            children: [
              if (endpoint.isNotEmpty)
                Flexible(
                  child: Text(
                    endpoint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.mono(size: 9, color: t.textFaint),
                  ),
                ),
              const Spacer(),
              _MiniAction(
                icon: Icons.content_copy,
                label: '复制错误',
                onTap: () =>
                    Clipboard.setData(ClipboardData(text: raw ?? '模型调用失败')),
              ),
              if (onRetry != null) ...[
                const SizedBox(width: FanxSpace.xs),
                _MiniAction(
                  icon: Icons.refresh,
                  label: '重试',
                  accent: true,
                  onTap: onRetry!,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniAction extends StatefulWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  State<_MiniAction> createState() => _MiniActionState();
}

class _MiniActionState extends State<_MiniAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = widget.accent ? t.accent : t.textMuted;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: FanxSpace.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: _hover ? base.withValues(alpha: 0.10) : Colors.transparent,
            borderRadius: BorderRadius.circular(FanxRadius.xs),
            border: Border.all(
              color: _hover ? base.withValues(alpha: 0.5) : t.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 11, color: base),
              const SizedBox(width: FanxSpace.xs),
              Text(widget.label, style: context.mono(size: 9.5, color: base)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyAction extends StatefulWidget {
  const _CopyAction({required this.text, this.compact = false});

  final String text;
  final bool compact;

  @override
  State<_CopyAction> createState() => _CopyActionState();
}

class _CopyActionState extends State<_CopyAction> {
  bool _hover = false;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = _copied ? t.success : (_hover ? t.text : t.textFaint);

    return Tooltip(
      message: _copied ? '已复制' : '复制这段内容',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: _copy,
          child: Container(
            width: 22,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? t.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(FanxRadius.xs),
            ),
            child: Icon(
              _copied ? Icons.check : Icons.content_copy,
              size: widget.compact ? 10 : 12,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FanxSpace.md,
            vertical: FanxSpace.sm,
          ),
          decoration: BoxDecoration(
            color: t.surfaceRaised,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
            border: Border.all(color: t.borderStrong),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: t.isDark ? 0.4 : 0.10),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('回到最新', style: context.mono(size: 10, color: t.textMuted)),
              const SizedBox(width: FanxSpace.xs),
              Icon(Icons.arrow_downward, size: 12, color: t.accent),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 输入区
// ---------------------------------------------------------------------------

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.modelLabel,
    required this.onSend,
    required this.onAbort,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final String? modelLabel;
  final Future<void> Function() onSend;
  final Future<void> Function() onAbort;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  /// 回车发送。中文输入法正在拼字时不发——那一下回车是确认候选词。
  void _onEnter() {
    if (widget.controller.value.composing.isValid) return;
    if (widget.controller.text.trim().isEmpty || widget.busy) return;
    widget.onSend();
  }

  /// Ctrl / ⌘ / Shift + 回车换行：手动插到光标处，保持选择位置在换行之后。
  void _insertNewline() {
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final next = text.replaceRange(start, end, '\n');
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final canSend = hasText && !widget.busy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xl,
        FanxSpace.md,
        FanxSpace.xl,
        FanxSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MetaTag('COMPOSE / 指令', size: 8.5, tracking: 1.7),
              const Spacer(),
              if (widget.modelLabel != null)
                Row(
                  children: [
                    Icon(Icons.memory, size: 10, color: t.textFaint),
                    const SizedBox(width: FanxSpace.xs),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        widget.modelLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.mono(size: 9, color: t.textFaint),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: FanxSpace.xs + 2),
          CallbackShortcuts(
            bindings: {
              // 回车直接发（最高频动作），换行走 Shift / Ctrl / ⌘ + 回车。
              const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
              const SingleActivator(LogicalKeyboardKey.numpadEnter): _onEnter,
              const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                  _insertNewline,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _insertNewline,
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _insertNewline,
            },
            child: _ComposerShell(
              focusNode: widget.focusNode,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      left: FanxSpace.lg,
                      bottom: FanxSpace.md + 4,
                    ),
                    child: Text(
                      '›',
                      style: context.mono(
                        size: 15,
                        color: canSend || widget.busy ? t.accent : t.textFaint,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      minLines: 1,
                      maxLines: 8,
                      autofocus: false,
                      cursorWidth: 1.5,
                      style: context.texts.bodyLarge?.copyWith(
                        color: t.text,
                        height: 1.6,
                        fontFamilyFallback: FanxFonts.fallback,
                      ),
                      decoration: InputDecoration(
                        filled: false,
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(
                          FanxSpace.sm,
                          FanxSpace.md + 2,
                          FanxSpace.sm,
                          FanxSpace.md + 2,
                        ),
                        hintText: widget.busy
                            ? '生成中…可以继续写下一句'
                            : '给这个 Agent 一条指令',
                        hintStyle: context.texts.bodyLarge?.copyWith(
                          color: t.textMuted,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FanxSpace.sm,
                      0,
                      FanxSpace.sm,
                      FanxSpace.sm,
                    ),
                    child: _SendButton(
                      label: widget.busy ? '停止' : '发送',
                      icon: widget.busy
                          ? Icons.stop_rounded
                          : Icons.arrow_upward_rounded,
                      tone: widget.busy ? _SendTone.stop : _SendTone.send,
                      enabled: widget.busy || canSend,
                      onTap: widget.busy ? widget.onAbort : widget.onSend,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: FanxSpace.sm),
          Row(
            children: [
              KeyHint(
                label: '⏎',
                color: widget.busy ? t.border : t.borderStrong,
              ),
              const SizedBox(width: FanxSpace.xs + 1),
              Text(
                widget.busy ? '生成中，可随时停止' : '发送',
                style: context.texts.bodySmall?.copyWith(
                  color: widget.busy ? t.accent : t.textFaint,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(width: FanxSpace.md),
              KeyHint(
                label: 'SHIFT + ⏎',
                color: widget.busy ? t.border : t.borderStrong,
              ),
              const SizedBox(width: FanxSpace.xs + 1),
              Text(
                '换行',
                style: context.texts.bodySmall?.copyWith(
                  color: t.textFaint,
                  fontSize: 11.5,
                ),
              ),
              const Spacer(),
              if (hasText)
                Text(
                  '${widget.controller.text.length} 字',
                  style: context.mono(size: 9.5, color: t.textFaint),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposerShell extends StatefulWidget {
  const _ComposerShell({required this.focusNode, required this.child});

  final FocusNode focusNode;
  final Widget child;

  @override
  State<_ComposerShell> createState() => _ComposerShellState();
}

class _ComposerShellState extends State<_ComposerShell> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ComposerShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = widget.focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return AnimatedContainer(
      duration: FanxMotion.fast,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FanxRadius.md),
        border: Border.all(
          color: _focused ? t.accent.withValues(alpha: 0.7) : t.border,
          width: _focused ? 1.4 : 1,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: t.accent.withValues(alpha: t.isDark ? 0.10 : 0.06),
                  blurRadius: 24,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: widget.child,
    );
  }
}

enum _SendTone { send, stop }

class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.enabled,
    this.tone = _SendTone.send,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  final _SendTone tone;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isStop = widget.tone == _SendTone.stop;
    final enabled = widget.enabled;
    final background = !enabled
        ? t.surfaceRaised
        : isStop
        ? (_hover ? t.danger : t.danger.withValues(alpha: 0.12))
        : (_hover ? Color.lerp(t.accent, Colors.black, 0.16)! : t.accent);
    final foreground = !enabled
        ? t.textFaint
        : isStop
        ? (_hover
              ? (t.isDark ? const Color(0xFF1A0505) : Colors.white)
              : t.danger)
        : t.onAccent;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
            border: Border.all(
              color: isStop && enabled
                  ? t.danger.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: context.texts.labelLarge?.copyWith(
                  color: foreground,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: FanxSpace.xs + 1),
              Icon(widget.icon, size: 13, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 骨架
// ---------------------------------------------------------------------------

class _ChatSkeleton extends StatelessWidget {
  const _ChatSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xl,
        FanxSpace.lg,
        FanxSpace.xl,
        FanxSpace.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(color: t.accent, pulsing: true, size: 5),
              const SizedBox(width: FanxSpace.sm),
              MetaTag('CONNECTING · EVENT STREAM', size: 9.5, tracking: 1.8),
            ],
          ),
          const SizedBox(height: FanxSpace.lg),
          const HairLine(),
          for (var i = 0; i < 3; i++) ...[
            const SizedBox(height: FanxSpace.xl),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(
                  width: 20,
                  height: 20,
                  radius: FanxRadius.xs,
                  delay: Duration(milliseconds: i * 160),
                ),
                const SizedBox(width: FanxSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(
                        width: 108,
                        height: 9,
                        delay: Duration(milliseconds: i * 160 + 40),
                      ),
                      const SizedBox(height: FanxSpace.md),
                      SkeletonBox(
                        width: double.infinity,
                        height: 12,
                        delay: Duration(milliseconds: i * 160 + 80),
                      ),
                      const SizedBox(height: 7),
                      SkeletonBox(
                        width: double.infinity,
                        height: 12,
                        delay: Duration(milliseconds: i * 160 + 120),
                      ),
                      const SizedBox(height: 7),
                      SkeletonBox(
                        width: 220,
                        height: 12,
                        delay: Duration(milliseconds: i * 160 + 160),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
