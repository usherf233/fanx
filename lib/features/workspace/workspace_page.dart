import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';
import '../agent/agent_tabs.dart';
import '../library/library_view.dart';
import '../agent/models_tab.dart';
import '../agents/create_agent_dialog.dart';
import '../chat/chat_panel.dart';
import 'session_sidebar.dart';

/// 工作区：顶部是 Agent 菜单 + 功能小菜单，左侧是这个 Agent 的会话列表。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, required this.agentId});

  final String agentId;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  List<AgentSession> _sessions = const [];
  bool _sessionsLoading = true;

  /// daemon 真正激活的会话（有 runtime）。只有发消息才需要切它。
  String? _activeSessionId;

  /// 当前正在查看的会话。点侧栏只改这个值，不碰后端。
  String? _viewSessionId;

  /// 正在读盘取预览历史的会话，侧栏给一个转圈反馈。
  String? _previewingId;
  bool _previewLoading = false;

  /// 最近看过的会话快照。切回去时先画缓存，不等任何网络请求。
  final Map<String, AgentState> _stateCache = {};
  // ChatPanel 只在 initState 读种子；种子变了要换 key 才会重新装载。
  int _viewRevision = 0;

  AgentState _state = AgentState.empty;
  String? _error;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// `/a/:id` 只有一条路由：换 Agent 时 go_router 复用同一个 State。
  /// 每次换 Agent 递增代次，飞在半路的旧请求回来后直接丢弃。
  int _agentEpoch = 0;
  bool _isStale(int epoch) => !mounted || epoch != _agentEpoch;

  /// 删除请求在飞的条目（转圈 + 淡化）与正在播退场动画的条目。
  final Set<String> _deletingSessionIds = {};
  final Set<String> _exitingSessionIds = {};

  Agent? get _agent => appState.byId(widget.agentId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (appState.agents.isEmpty) appState.refresh();
    _bootstrap();
  }

  /// 同路由换 `:id` 时 State 不会重建：必须把上一个 Agent 的一切清干净，
  /// 否则会话列表、状态缓存、查看中的会话号都会串到新 Agent 上。
  @override
  void didUpdateWidget(covariant WorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId == widget.agentId) return;
    _agentEpoch++;
    _stateCache.clear();
    _deletingSessionIds.clear();
    _exitingSessionIds.clear();
    _sessions = const [];
    _sessionsLoading = true;
    _state = AgentState.empty;
    _activeSessionId = null;
    _viewSessionId = null;
    _previewingId = null;
    _previewLoading = false;
    _error = null;
    _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
    _viewRevision++;
    // framework 已经在这一帧重建，字段直接改即可，不用 setState。
    _bootstrap();
  }

  /// 从后台切回来时重拉一次会话列表：文件可能在别处被改动过
  /// （删除、另一个窗口写入），陈旧的列表是"点开会话却不存在"的主要来源。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshSessions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  /// 进入工作区：状态 + 会话列表并行读。没有运行中的会话时只预览最近一次
  /// 历史，runtime 等用户第一次发消息再建，首屏不付切换/重建的代价。
  Future<void> _bootstrap() async {
    final epoch = _agentEpoch;
    final agentId = widget.agentId;
    try {
      late final AgentState state;
      late final List<AgentSession> sessions;
      await Future.wait<void>([
        appState.client.getState(agentId).then((value) {
          state = value;
        }),
        appState.client.listSessions(agentId).then((value) {
          sessions = value;
        }),
      ]);
      if (_isStale(epoch)) return;
      final view =
          state.sessionId ?? (sessions.isEmpty ? null : sessions.first.id);
      final needsPreview = view != null && view != state.sessionId;
      setState(() {
        _state = state;
        _sessions = sessions;
        _sessionsLoading = false;
        _activeSessionId = state.sessionId;
        _viewSessionId = view;
        _previewLoading = needsPreview;
        _previewingId = needsPreview ? view : null;
      });
      if (state.sessionId != null) _cacheState(state.sessionId!, state);
      if (needsPreview) await _loadPreview(agentId, view, epoch: epoch);
    } on ApiException catch (exception) {
      if (!_isStale(epoch)) {
        setState(() {
          _error = exception.message;
          _sessionsLoading = false;
        });
      }
    }
  }

  /// 新建 / 删除当前会话 / 自愈后调用：回到后端真正激活的会话。
  Future<void> _reload() async {
    final epoch = _agentEpoch;
    final agentId = widget.agentId;
    try {
      late final AgentState state;
      late final List<AgentSession> sessions;
      await Future.wait<void>([
        appState.client.getState(agentId).then((value) {
          state = value;
        }),
        appState.client.listSessions(agentId).then((value) {
          sessions = value;
        }),
      ]);
      if (_isStale(epoch)) return;
      setState(() {
        _state = state;
        _sessions = sessions;
        _activeSessionId = state.sessionId;
        _viewSessionId = state.sessionId;
        _sessionsLoading = false;
        _previewLoading = false;
        _previewingId = null;
        _error = null;
        _viewRevision++;
      });
      if (state.sessionId != null) _cacheState(state.sessionId!, state);
    } on ApiException catch (exception) {
      if (!_isStale(epoch)) setState(() => _error = exception.message);
    }
  }

  /// 侧栏刷新：只更新列表与后端 active 号，不打断正在预览的会话。
  Future<void> _refresh() async {
    final epoch = _agentEpoch;
    final agentId = widget.agentId;
    try {
      late final AgentState state;
      late final List<AgentSession> sessions;
      await Future.wait<void>([
        appState.client.getState(agentId).then((value) {
          state = value;
        }),
        appState.client.listSessions(agentId).then((value) {
          sessions = value;
        }),
      ]);
      if (_isStale(epoch)) return;
      setState(() {
        _sessions = sessions;
        _sessionsLoading = false;
        _activeSessionId = state.sessionId;
        _viewSessionId ??= state.sessionId;
        if (state.sessionId == _viewSessionId) _state = state;
        _error = null;
      });
      if (state.sessionId != null) _cacheState(state.sessionId!, state);
    } on ApiException catch (exception) {
      if (!_isStale(epoch)) setState(() => _error = exception.message);
    }
  }

  /// 缓存含全量消息历史，留最近 8 个会话就够，别随会话数一直涨。
  void _cacheState(String id, AgentState state) {
    _stateCache.remove(id);
    _stateCache[id] = state;
    while (_stateCache.length > 8) {
      _stateCache.remove(_stateCache.keys.first);
    }
  }

  /// 对话有产出时同步顶栏状态，并刷新侧栏的标题与条数。
  /// 状态直接用事件里带的数据，不再额外请求；列表刷新节流 2 秒。
  void _onChatActivity(AgentState state) {
    if (!mounted) return;
    // 后端可能刚被激活到目标会话，先把 active 号跟上。
    if (state.sessionId != null && state.sessionId != _activeSessionId) {
      setState(() => _activeSessionId = state.sessionId);
    }
    // 预览别的会话时后端会按会话号过滤事件，正常到不了这里；
    // 兜一层仍然只更新 active 号，绝不让别的会话的消息盖住当前视图。
    if (state.sessionId != _viewSessionId) return;

    // 顶栏只读这几个字段：只有它们真的变化才重建工作区。一轮对话里
    // 中间的 state 事件不该把整个 TabBarView 和侧栏带着一起重建，
    // 节流也只应该作用于列表请求，不该把状态更新一起丢掉。
    final changed =
        _state.busy != state.busy ||
        _state.running != state.running ||
        _state.modelLabel != state.modelLabel ||
        _state.sessionId != state.sessionId ||
        _state.lastError != state.lastError;
    if (changed) setState(() => _state = state);
    if (state.sessionId != null) _cacheState(state.sessionId!, state);

    // 预览读盘期间别再拉列表，和这次请求抢同一个事件循环没意义。
    if (_previewingId != null) return;

    final now = DateTime.now();
    if (now.difference(_lastRefresh) < const Duration(seconds: 2)) return;
    _lastRefresh = now;
    _refreshSessions();
  }

  /// 只拉会话列表（标题、条数、时间），不碰运行时状态。
  Future<void> _refreshSessions() async {
    final epoch = _agentEpoch;
    final agentId = widget.agentId;
    try {
      final sessions = await appState.client.listSessions(agentId);
      if (_isStale(epoch)) return;
      setState(() => _sessions = sessions);
    } on ApiException {
      // 列表刷新失败不该打断对话，静默即可。
    }
  }

  Future<void> _newSession() async {
    try {
      await appState.client.createSession(widget.agentId);
      await _reload();
    } on ApiException catch (exception) {
      _toast(exception.message);
    }
  }

  /// 点侧栏：只换视图，不切后端会话。命中缓存即零延迟显示，没命中才读
  /// 一次目标 JSONL（读一个文件比销毁重建 runtime 便宜一个数量级）。
  void _preview(String sessionId) {
    if (sessionId == _viewSessionId) return;
    final previous = _viewSessionId;
    if (previous != null && _state.sessionId == previous) {
      _cacheState(previous, _state);
    }
    final cached = _stateCache[sessionId];
    setState(() {
      _viewSessionId = sessionId;
      _state = cached ?? _placeholder(sessionId);
      _previewLoading = cached == null;
      _previewingId = cached == null ? sessionId : null;
      _viewRevision++;
      _error = null;
    });
    if (cached == null) _loadPreview(widget.agentId, sessionId);
  }

  /// 只读取目标会话的历史。后端不会切 runtime，也不会广播任何状态。
  Future<void> _loadPreview(
    String agentId,
    String sessionId, {
    int? epoch,
  }) async {
    final gen = epoch ?? _agentEpoch;
    try {
      final state = await appState.client.sessionState(agentId, sessionId);
      if (_isStale(gen) || _viewSessionId != sessionId) return;
      if (state == null) throw ApiException('会话内容为空');
      _cacheState(sessionId, state);
      setState(() {
        _state = state;
        _previewLoading = false;
        _previewingId = null;
        _viewRevision++;
      });
    } on ApiException catch (exception) {
      if (_isStale(gen) || _viewSessionId != sessionId) return;
      setState(() {
        _previewLoading = false;
        _previewingId = null;
        _error = exception.message;
      });
      if (exception.statusCode == 404) {
        await _recoverFromMissingSession(sessionId);
      } else {
        _toast(exception.message);
      }
    }
  }

  /// 只有真的发出新消息时才切后端会话。返回 false 表示没切成，别发。
  Future<bool> _activateForSend(String sessionId) async {
    final epoch = _agentEpoch;
    try {
      final state = await appState.client.activateSession(
        widget.agentId,
        sessionId,
      );
      if (_isStale(epoch)) return false;
      if (state != null) _cacheState(sessionId, state);
      setState(() {
        _activeSessionId = sessionId;
        if (state != null) _state = state;
        _error = null;
      });
      _refreshSessions();
      return true;
    } on ApiException catch (exception) {
      if (_isStale(epoch)) return false;
      if (exception.statusCode == 404) {
        await _recoverFromMissingSession(sessionId);
        return false;
      }
      // 其余错误交给 ChatPanel 显示横幅并保留输入，这里不重复弹 toast。
      rethrow;
    }
  }

  /// 没缓存时的占位种子：sessionId 必须指向目标会话，这样 ChatPanel
  /// 会走 seeded 分支，不会误发一次 getState 把当前会话内容拉回来。
  AgentState _placeholder(String sessionId) => AgentState(
    running: true,
    busy: false,
    messages: const <ChatMessage>[],
    modelLabel: _state.modelLabel,
    lastError: null,
    sessionId: sessionId,
  );

  /// 目标会话文件丢失时的自愈：重拉列表 + 回到 daemon 实际在用的会话。
  Future<void> _recoverFromMissingSession(String missingId) async {
    final short = missingId.length > 8
        ? '${missingId.substring(0, 8)}…'
        : missingId;
    _toast('会话 $short 的文件已不存在，已刷新列表');
    await _reload();
    // 列表里一个都不剩时，至少留一个可用的空会话。
    if (mounted && _sessions.isEmpty) {
      try {
        await appState.client.createSession(widget.agentId);
        await _reload();
      } on ApiException {
        // 建不起来就保持空态，用户还能手动点「+」。
      }
    }
  }

  Future<void> _deleteSession(AgentSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('「${session.title}」的对话记录会从磁盘删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.tokens.danger,
              foregroundColor: context.tokens.isDark
                  ? const Color(0xFF1A0505)
                  : Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final epoch = _agentEpoch;
    final agentId = widget.agentId;
    // 先把条目留在列表里给出「删除中」反馈，盖住这段网络等待。
    setState(() => _deletingSessionIds.add(session.id));
    try {
      await appState.client.deleteSession(agentId, session.id);
      if (_isStale(epoch)) return;
      // 数据先不换：让条目淡出 + 左移 + 高度收起，下方会话平滑顶上来。
      setState(() {
        _deletingSessionIds.remove(session.id);
        _exitingSessionIds.add(session.id);
      });
      await Future<void>.delayed(kSessionExitDuration);
      if (_isStale(epoch)) return;
      // 删的是正在看 / 正在跑的会话才回到 active，否则别打断预览。
      if (session.id == _viewSessionId || session.id == _activeSessionId) {
        await _reload();
      } else {
        await _refreshSessions();
      }
      if (mounted) setState(() => _exitingSessionIds.remove(session.id));
    } on ApiException catch (exception) {
      if (_isStale(epoch)) return;
      setState(() {
        _deletingSessionIds.remove(session.id);
        _exitingSessionIds.remove(session.id);
      });
      _toast(exception.message);
    }
  }

  Future<void> _switchAgent(String agentId) async {
    if (agentId == widget.agentId) return;
    context.go('/a/$agentId');
  }

  Future<void> _createAgent() async {
    final agent = await CreateAgentDialog.show(context);
    if (agent != null && mounted) context.go('/a/${agent.id}');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: appState,
          builder: (context, _) {
            final agent = _agent;
            if (agent == null) {
              // 可能在别处被删掉了：回启动页，不要停在一个空壳上。
              if (!appState.loading) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) context.go('/');
                });
              }
              return const LoadingBlock(label: 'syncing');
            }
            return _buildWorkspace(context, agent);
          },
        ),
      ),
    );
  }

  Widget _buildWorkspace(BuildContext context, Agent agent) {
    return Column(
      children: [
        _WorkspaceBar(
          agent: agent,
          agents: appState.agents,
          tabController: _tabs,
          modelLabel: _state.modelLabel,
          running: _state.running,
          onSwitch: _switchAgent,
          onCreate: _createAgent,
          onLauncher: () => context.go('/'),
        ),
        const HairLine(),
        if (_error != null)
          InlineNotice(
            message: _error!,
            onDismiss: () => setState(() => _error = null),
          ),
        Expanded(
          child: Row(
            children: [
              SessionSidebar(
                sessions: _sessions,
                activeSessionId: _viewSessionId,
                runningSessionId: _activeSessionId,
                loading: _sessionsLoading,
                busy: false,
                onNew: _newSession,
                onRefresh: _refresh,
                onPreview: _preview,
                onDelete: _deleteSession,
                pendingSessionId: _previewingId,
                deletingSessionIds: _deletingSessionIds,
                exitingSessionIds: _exitingSessionIds,
              ),
              const HairLine(vertical: true),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    ChatPanel(
                      key: ValueKey(
                        '${agent.id}:${_viewSessionId ?? '-'}:$_viewRevision',
                      ),
                      agent: agent,
                      // 只有"状态确实属于正在看的会话"时才当种子用：
                      // 首次进入时两者都是 null，不能把空状态当种子，否则不会拉取消息。
                      initialState:
                          _viewSessionId != null &&
                              _state.sessionId == _viewSessionId
                          ? _state
                          : null,
                      expectedSessionId: _viewSessionId,
                      pending: _previewLoading,
                      preview:
                          _viewSessionId != null &&
                          _viewSessionId != _activeSessionId,
                      onActivate: _activateForSend,
                      onState: _onChatActivity,
                      onOpenModels: () => _tabs.animateTo(1),
                    ),
                    ModelsTab(
                      agent: agent,
                      onChanged: () => appState.refresh(),
                    ),
                    ConfigTab(agent: agent),
                    LibraryView(agent: agent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 顶栏
// ---------------------------------------------------------------------------

class _WorkspaceBar extends StatelessWidget {
  const _WorkspaceBar({
    required this.agent,
    required this.agents,
    required this.tabController,
    required this.modelLabel,
    required this.running,
    required this.onSwitch,
    required this.onCreate,
    required this.onLauncher,
  });

  final Agent agent;
  final List<Agent> agents;
  final TabController tabController;
  final String? modelLabel;
  final bool running;
  final Future<void> Function(String agentId) onSwitch;
  final Future<void> Function() onCreate;
  final VoidCallback onLauncher;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          _AgentMenu(
            agent: agent,
            agents: agents,
            onSwitch: onSwitch,
            onCreate: onCreate,
            onLauncher: onLauncher,
          ),
          const SizedBox(width: FanxSpace.sm),
          Container(width: 1, height: 16, color: t.border),
          const SizedBox(width: FanxSpace.sm),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                controller: tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                splashFactory: NoSplash.splashFactory,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                labelPadding: const EdgeInsets.symmetric(
                  horizontal: FanxSpace.md,
                ),
                indicatorWeight: 2,
                tabs: const [
                  _TabItem(index: '01', label: '对话'),
                  _TabItem(index: '02', label: '模型'),
                  _TabItem(index: '03', label: '配置'),
                  _TabItem(index: '04', label: '资源库'),
                ],
              ),
            ),
          ),
          if (modelLabel != null) ...[
            _ModelBadge(label: modelLabel!),
            const SizedBox(width: FanxSpace.md),
          ],
          _IconAction(
            tooltip: '返回启动页',
            icon: Icons.grid_view_rounded,
            onTap: onLauncher,
          ),
          const SizedBox(width: FanxSpace.sm),
          // 一个极小的运行指示，让顶栏右侧不空着。
          Padding(
            padding: const EdgeInsets.only(right: FanxSpace.lg),
            child: Tooltip(
              message: running ? '会话运行中' : '会话空闲',
              child: StatusDot(
                color: running ? t.success : t.textFaint,
                pulsing: running,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.index, required this.label});

  final String index;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 46,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MetaTag(index, size: 9.5, tracking: 1.4, inheritColor: true),
          const SizedBox(width: FanxSpace.xs + 2),
          Text(label),
        ],
      ),
    );
  }
}

class _ModelBadge extends StatelessWidget {
  const _ModelBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Tooltip(
      message: '当前模型',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FanxSpace.sm + 2,
          vertical: FanxSpace.xs + 1,
        ),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(FanxRadius.sm),
          border: Border.all(color: t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory, size: 11, color: t.accent),
            const SizedBox(width: FanxSpace.xs + 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.mono(size: 11, color: t.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: FanxMotion.fast,
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? t.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(FanxRadius.sm),
              border: Border.all(
                color: _hover ? t.borderStrong : Colors.transparent,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: _hover ? t.text : t.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Agent 切换器
// ---------------------------------------------------------------------------

class _AgentMenu extends StatefulWidget {
  const _AgentMenu({
    required this.agent,
    required this.agents,
    required this.onSwitch,
    required this.onCreate,
    required this.onLauncher,
  });

  final Agent agent;
  final List<Agent> agents;
  final Future<void> Function(String agentId) onSwitch;
  final Future<void> Function() onCreate;
  final VoidCallback onLauncher;

  @override
  State<_AgentMenu> createState() => _AgentMenuState();
}

class _AgentMenuState extends State<_AgentMenu> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final agent = widget.agent;

    return PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      color: t.surfaceRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FanxRadius.md),
        side: BorderSide(color: t.borderStrong),
      ),
      onSelected: (value) {
        if (value == '__new__') {
          widget.onCreate();
        } else if (value == '__launcher__') {
          widget.onLauncher();
        } else {
          widget.onSwitch(value);
        }
      },
      itemBuilder: (context) => [
        for (final item in widget.agents)
          PopupMenuItem<String>(
            value: item.id,
            height: 38,
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: item.id == agent.id
                      ? Icon(Icons.check, size: 13, color: t.accent)
                      : null,
                ),
                const SizedBox(width: FanxSpace.sm),
                Expanded(
                  child: Text(item.name, style: context.texts.bodyMedium),
                ),
                if (item.running) ...[
                  const SizedBox(width: FanxSpace.sm),
                  StatusDot(color: t.success, size: 5),
                ],
              ],
            ),
          ),
        PopupMenuDivider(height: 9, color: t.border),
        PopupMenuItem<String>(
          value: '__new__',
          height: 38,
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: Icon(Icons.add, size: 13, color: t.textMuted),
              ),
              const SizedBox(width: FanxSpace.sm),
              Text('新建 Agent', style: context.texts.bodyMedium),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: '__launcher__',
          height: 38,
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: Icon(
                  Icons.grid_view_rounded,
                  size: 13,
                  color: t.textMuted,
                ),
              ),
              const SizedBox(width: FanxSpace.sm),
              Text('返回启动页', style: context.texts.bodyMedium),
            ],
          ),
        ),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          height: 32,
          margin: const EdgeInsets.only(left: FanxSpace.md),
          padding: const EdgeInsets.fromLTRB(
            FanxSpace.xs + 2,
            0,
            FanxSpace.sm,
            0,
          ),
          decoration: BoxDecoration(
            color: _hover ? t.surfaceRaised : Colors.transparent,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
            border: Border.all(
              color: _hover ? t.borderStrong : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: BorderRadius.circular(FanxRadius.xs),
                ),
                child: Text(
                  agent.name.isEmpty ? '?' : agent.name.characters.first,
                  style: TextStyle(
                    fontFamilyFallback: FanxFonts.fallback,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: t.onAccent,
                  ),
                ),
              ),
              const SizedBox(width: FanxSpace.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  agent.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleSmall,
                ),
              ),
              const SizedBox(width: FanxSpace.xs),
              Icon(Icons.unfold_more, size: 13, color: t.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}
