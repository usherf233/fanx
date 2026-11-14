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
  String? _activeSessionId;

  /// 正在切换过去的会话。用来在侧栏立刻给出反馈：点击即高亮 + 转圈，
  /// 而不是等三个请求串行跑完才有任何反应。
  String? _switchingSessionId;
  AgentState _state = AgentState.empty;
  String? _error;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  Agent? get _agent => appState.byId(widget.agentId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (appState.agents.isEmpty) appState.refresh();
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

  /// 进入工作区：读状态 + 会话列表；没有运行中的会话时，默认恢复最近一次。
  Future<void> _bootstrap() async {
    try {
      final state = await appState.client.getState(widget.agentId);
      final sessions = await appState.client.listSessions(widget.agentId);
      if (!mounted) return;
      setState(() {
        _state = state;
        _sessions = sessions;
        _sessionsLoading = false;
        _activeSessionId = state.sessionId;
      });

      if (!state.running) {
        if (sessions.isEmpty) {
          await appState.client.createSession(widget.agentId);
        } else {
          try {
            await appState.client.activateSession(
              widget.agentId,
              sessions.first.id,
            );
          } on ApiException {
            // 最近那次会话的文件可能已经没了，退化成新建一个，别让工作区空着。
            await appState.client.createSession(widget.agentId);
          }
        }
        await _reload();
      }
    } on ApiException catch (exception) {
      if (mounted) {
        setState(() {
          _error = exception.message;
          _sessionsLoading = false;
        });
      }
    }
  }

  Future<void> _reload() async {
    try {
      final state = await appState.client.getState(widget.agentId);
      final sessions = await appState.client.listSessions(widget.agentId);
      if (!mounted) return;
      setState(() {
        _state = state;
        _sessions = sessions;
        _activeSessionId = state.sessionId;
        _sessionsLoading = false;
        _error = null;
      });
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    }
  }

  /// 对话有产出时同步顶栏状态，并刷新侧栏的标题与条数。
  /// 状态直接用事件里带的数据，不再额外请求；列表刷新节流 2 秒。
  void _onChatActivity(AgentState state) {
    if (!mounted) return;
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

    final now = DateTime.now();
    if (now.difference(_lastRefresh) < const Duration(seconds: 2)) return;
    _lastRefresh = now;
    _refreshSessions();
  }

  /// 只拉会话列表（标题、条数、时间），不碰运行时状态。
  Future<void> _refreshSessions() async {
    try {
      final sessions = await appState.client.listSessions(widget.agentId);
      if (!mounted) return;
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

  Future<void> _activate(String sessionId) async {
    if (sessionId == _activeSessionId || _switchingSessionId != null) return;

    // 先置位再发请求：侧栏立刻高亮，用户马上知道点中了。
    setState(() => _switchingSessionId = sessionId);
    try {
      // daemon 会把切换后的完整状态一起返回，省掉后面两次往返。
      final state = await appState.client.activateSession(
        widget.agentId,
        sessionId,
      );
      if (!mounted) return;
      setState(() {
        _activeSessionId = sessionId;
        if (state != null) _state = state;
        _error = null;
      });
    } on ApiException catch (exception) {
      if (!mounted) return;
      if (exception.statusCode == 404) {
        // 会话的 jsonl 已经不在了：界面列表和磁盘不同步。
        // 直接把两边拉齐，比抛一句"会话不存在"让用户卡住更有用。
        await _recoverFromMissingSession(sessionId);
      } else {
        _toast(exception.message);
      }
    } finally {
      // 用 finally 兜底：任何异常都不能让"切换中"卡住，否则后面点谁都点不动。
      if (mounted) setState(() => _switchingSessionId = null);
    }
  }

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

    try {
      await appState.client.deleteSession(widget.agentId, session.id);
      await _reload();
    } on ApiException catch (exception) {
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
                activeSessionId: _activeSessionId,
                loading: _sessionsLoading,
                busy: false,
                onNew: _newSession,
                onRefresh: _reload,
                onActivate: _activate,
                onDelete: _deleteSession,
                pendingSessionId: _switchingSessionId,
              ),
              const HairLine(vertical: true),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    ChatPanel(
                      key: ValueKey('${agent.id}:${_activeSessionId ?? '-'}'),
                      agent: agent,
                      // 只有"状态确实属于目标会话"时才当种子用：
                      // 首次进入时两者都是 null，不能把空状态当种子，否则不会拉取消息。
                      initialState:
                          _activeSessionId != null &&
                              _state.sessionId == _activeSessionId
                          ? _state
                          : null,
                      onState: _onChatActivity,
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
