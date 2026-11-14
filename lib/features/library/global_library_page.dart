import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';

/// 全局资源库：不绑定某个 Agent，横向看「同一份能力装给了谁」。
///
/// 每行是一个技能/扩展/模板，右侧每个 Agent 一个状态块：
/// 已启用 → 点一下停用；已停用 → 点一下启用；未安装 → 点一下从别的 Agent 复制过来。
class GlobalLibraryPage extends StatefulWidget {
  const GlobalLibraryPage({super.key});

  @override
  State<GlobalLibraryPage> createState() => _GlobalLibraryPageState();
}

class _GlobalLibraryPageState extends State<GlobalLibraryPage> {
  LibrarySnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  String _kind = 'all';
  final _query = TextEditingController();

  /// `${agentId}:${kind}:${name}`，正在操作的格子。
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    if (appState.agents.isEmpty) appState.refresh();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await appState.client.getLibrary();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (exception) {
      if (!mounted) return;
      setState(() {
        _error = exception.message;
        _loading = false;
      });
    }
  }

  List<LibraryItem> get _visible {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    final keyword = _query.text.trim().toLowerCase();
    return snapshot.items
        .where((item) {
          if (_kind != 'all' && '${item.kind}s' != _kind) return false;
          if (keyword.isEmpty) return true;
          return item.name.toLowerCase().contains(keyword) ||
              item.description.toLowerCase().contains(keyword);
        })
        .toList(growable: false);
  }

  String _cellKey(String agentId, LibraryItem item) =>
      '$agentId:${item.kind}:${item.name}';

  Future<void> _toggle(LibraryItem item, LibraryPresence presence) async {
    final key = _cellKey(presence.agentId, item);
    if (_pending.contains(key)) return;
    setState(() => _pending.add(key));
    try {
      await appState.client.toggleResource(
        presence.agentId,
        type: '${item.kind}s',
        name: item.name,
        enabled: !presence.enabled,
      );
      await _load(silent: true);
      await appState.refresh();
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  /// 未安装的格子：从第一个拥有它的 Agent 复制过来。
  Future<void> _install(LibraryItem item, Agent target) async {
    final source = item.agents.isEmpty ? null : item.agents.first;
    if (source == null) return;

    final key = _cellKey(target.id, item);
    setState(() => _pending.add(key));
    try {
      await appState.client.copyResource(
        sourceAgentId: source.agentId,
        targetAgentId: target.id,
        type: '${item.kind}s',
        name: item.name,
      );
      await _load(silent: true);
      await appState.refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已把 ${item.name} 复制到 ${target.name}'),
          duration: const Duration(seconds: 3),
        ),
      );
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      body: GridBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(
                agentCount: _snapshot?.agents.length ?? appState.agents.length,
                loading: _loading,
                onBack: () => context.go('/'),
                onRefresh: () => _load(),
              ),
              HairLine(),
              Expanded(
                child: _loading
                    ? const LoadingBlock(label: 'reading library')
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          FanxSpace.xxl,
                          FanxSpace.xxl,
                          FanxSpace.xxl,
                          FanxSpace.xxl,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1120),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Reveal(index: 0, child: _headline()),
                                const SizedBox(height: FanxSpace.xl),
                                if (_snapshot != null)
                                  Reveal(
                                    index: 1,
                                    child: _Ledger(snapshot: _snapshot!),
                                  ),
                                const SizedBox(height: FanxSpace.xl),
                                Reveal(index: 2, child: _toolbar()),
                                if (_error != null) ...[
                                  const SizedBox(height: FanxSpace.md),
                                  InlineNotice(
                                    message: _error!,
                                    onDismiss: () =>
                                        setState(() => _error = null),
                                  ),
                                ],
                                const SizedBox(height: FanxSpace.md),
                                Reveal(index: 3, child: _table()),
                                const SizedBox(height: FanxSpace.md),
                                Text(
                                  '点 Agent 标签：已启用 → 停用；已停用 → 启用；未安装 → 从别的 Agent 复制一份。',
                                  style: context.texts.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: t.textFaint,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headline() {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '05',
              style: context.monoLabel(color: t.accent, size: 10, tracking: 2),
            ),
            const SizedBox(width: FanxSpace.sm),
            Container(width: 14, height: 1, color: t.borderStrong),
            const SizedBox(width: FanxSpace.sm),
            MetaTag('ALL AGENTS / LIBRARY', size: 9, tracking: 1.8),
          ],
        ),
        const SizedBox(height: FanxSpace.sm + 2),
        Text('统一资源库', style: context.cnDisplay(size: 32, height: 1.25)),
        const SizedBox(height: FanxSpace.xs + 2),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Text(
            '一个 Agent 一个目录，但能力应该一眼看全：哪些技能重复装了三份，哪些只装了一半，停在哪边。',
            style: context.texts.bodySmall?.copyWith(
              color: t.textMuted,
              height: 1.7,
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar() {
    final snapshot = _snapshot;
    final t = context.tokens;

    int countOf(String kind) {
      if (snapshot == null) return 0;
      if (kind == 'all') return snapshot.items.length;
      return snapshot.items.where((item) => '${item.kind}s' == kind).length;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final segments = Wrap(
          spacing: FanxSpace.xs + 2,
          runSpacing: FanxSpace.xs + 2,
          children: [
            for (final option in const [
              ('all', '全部'),
              ('skills', '技能'),
              ('extensions', '扩展'),
              ('prompts', '模板'),
            ])
              _Segment(
                label: option.$2,
                count: countOf(option.$1),
                selected: _kind == option.$1,
                onTap: () => setState(() => _kind = option.$1),
              ),
          ],
        );

        final search = SizedBox(
          height: 34,
          width: constraints.maxWidth < 840 ? double.infinity : 260,
          child: TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            style: context.texts.bodySmall?.copyWith(color: t.text),
            decoration: InputDecoration(
              hintText: '搜索能力名或描述',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: FanxSpace.sm,
                vertical: 0,
              ),
              prefixIcon: Icon(Icons.search, size: 14, color: t.textFaint),
              prefixIconConstraints: const BoxConstraints(minWidth: 30),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : InkWell(
                      onTap: () {
                        _query.clear();
                        setState(() {});
                      },
                      child: Icon(Icons.close, size: 13, color: t.textFaint),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 28),
            ),
          ),
        );

        if (constraints.maxWidth < 840) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              segments,
              const SizedBox(height: FanxSpace.sm),
              search,
            ],
          );
        }

        return Row(
          children: [
            segments,
            const SizedBox(width: FanxSpace.lg),
            search,
          ],
        );
      },
    );
  }

  Widget _table() {
    final snapshot = _snapshot;
    final t = context.tokens;

    if (snapshot == null || snapshot.agents.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(FanxSpace.xl),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(FanxRadius.lg),
          border: Border.all(color: t.border),
        ),
        child: const EmptyState(
          title: '还没有 Agent',
          hint: '先回启动页建一个 Agent，资源库才有东西可管。',
          icon: Icons.dashboard_customize_outlined,
        ),
      );
    }

    final items = _visible;
    final grouped = _kind == 'all';

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FanxRadius.lg),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            color: t.surfaceSunken,
            padding: const EdgeInsets.symmetric(horizontal: FanxSpace.lg),
            child: Row(
              children: [
                Expanded(
                  child: MetaTag(
                    items.isEmpty
                        ? '资源 / RESOURCE'
                        : '资源 / RESOURCE · ${items.length}',
                    size: 9,
                    tracking: 1.5,
                  ),
                ),
                const SizedBox(width: FanxSpace.md),
                MetaTag('分发到 / DISTRIBUTION', size: 9, tracking: 1.5),
                const SizedBox(width: FanxSpace.sm),
              ],
            ),
          ),
          HairLine(color: t.border),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(FanxSpace.xl),
              child: EmptyState(
                title: '没有匹配的资源',
                hint: '换个关键词，或把类型筛选放宽。',
                icon: Icons.search_off,
              ),
            )
          else
            ..._buildRows(items, grouped),
        ],
      ),
    );
  }

  List<Widget> _buildRows(List<LibraryItem> items, bool grouped) {
    if (!grouped) {
      return [_rows(items)];
    }
    const order = ['skill', 'extension', 'prompt'];
    const titles = {
      'skill': '技能 / SKILLS',
      'extension': '扩展 / EXTENSIONS',
      'prompt': '模板 / TEMPLATES',
    };
    final children = <Widget>[];
    for (final kind in order) {
      final group = items.where((item) => item.kind == kind).toList();
      if (group.isEmpty) continue;
      children
        ..add(_GroupHeader(title: titles[kind]!, count: group.length))
        ..add(_rows(group));
    }
    return children;
  }

  Widget _rows(List<LibraryItem> group) {
    return Column(
      children: [
        for (var index = 0; index < group.length; index++) ...[
          if (index > 0) HairLine(),
          _LibraryRow(
            key: ValueKey('lib-${group[index].key}'),
            item: group[index],
            agents: _snapshot?.agents ?? const [],
            pending: _pending,
            cellKey: _cellKey,
            onToggle: _toggle,
            onInstall: _install,
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 顶栏 / 读数 / 分段
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.agentCount,
    required this.loading,
    required this.onBack,
    required this.onRefresh,
  });

  final int agentCount;
  final bool loading;
  final VoidCallback onBack;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.lg,
        FanxSpace.md,
        FanxSpace.lg,
        FanxSpace.md,
      ),
      child: Row(
        children: [
          _BarAction(icon: Icons.arrow_back, label: 'AGENTS', onTap: onBack),
          const SizedBox(width: FanxSpace.md),
          Container(width: 9, height: 9, color: t.accent),
          const SizedBox(width: FanxSpace.sm),
          Text(
            'FANX',
            style: context.monoLabel(color: t.text, size: 12, tracking: 4),
          ),
          const SizedBox(width: FanxSpace.md),
          const MetaTag('LIBRARY', bracket: true, size: 9.5),
          const Spacer(),
          MetaTag('$agentCount AGENTS', size: 9, tracking: 1.4),
          const SizedBox(width: FanxSpace.sm),
          _BarAction(
            icon: Icons.refresh,
            label: loading ? 'READING' : 'REFRESH',
            onTap: loading ? null : onRefresh,
          ),
        ],
      ),
    );
  }
}

class _BarAction extends StatefulWidget {
  const _BarAction({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_BarAction> createState() => _BarActionState();
}

class _BarActionState extends State<_BarAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final disabled = widget.onTap == null;

    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: FanxSpace.md,
            vertical: FanxSpace.sm,
          ),
          decoration: BoxDecoration(
            color: _hover ? t.surfaceRaised : Colors.transparent,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
            border: Border.all(color: _hover ? t.borderStrong : t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 13, color: _hover ? t.text : t.textMuted),
              const SizedBox(width: FanxSpace.sm),
              Text(
                widget.label,
                style: context.monoLabel(
                  color: _hover ? t.text : t.textMuted,
                  size: 9.5,
                  tracking: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ledger extends StatelessWidget {
  const _Ledger({required this.snapshot});

  final LibrarySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Cell(
            label: 'RESOURCES',
            value: '${snapshot.items.length}',
            unit: '项',
            accent: true,
          ),
          _Cell(label: 'INSTALLED', value: '${snapshot.relations}', unit: '处'),
          _Cell(
            label: 'ENABLED',
            value: '${snapshot.enabled}',
            unit: '/ ${snapshot.relations}',
          ),
          _Cell(label: 'AGENTS', value: '${snapshot.agents.length}', unit: '个'),
          _Cell(
            label: 'ISSUES',
            value: '${snapshot.issueCount}',
            unit: '项',
            danger: snapshot.issueCount > 0,
            last: true,
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.value,
    required this.unit,
    this.accent = false,
    this.danger = false,
    this.last = false,
  });

  final String label;
  final String value;
  final String unit;
  final bool accent;
  final bool danger;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: EdgeInsets.fromLTRB(
        accent ? FanxSpace.md : FanxSpace.lg,
        FanxSpace.sm,
        FanxSpace.md,
        FanxSpace.sm,
      ),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: accent ? t.accent : t.border,
            width: accent ? 2 : 1,
          ),
          top: BorderSide(color: t.border),
          bottom: BorderSide(color: t.border),
          right: last ? BorderSide(color: t.border) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: context.monoLabel(
              color: accent ? t.accent : t.textFaint,
              size: 8.5,
              tracking: 1.5,
            ),
          ),
          const SizedBox(height: FanxSpace.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: context.mono(
                  size: value.length > 5 ? 15 : 20,
                  color: danger ? t.danger : t.text,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(unit, style: context.mono(size: 9.5, color: t.textFaint)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
          decoration: BoxDecoration(
            color: selected ? t.accentWash : Colors.transparent,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
            border: Border.all(color: selected ? t.accent : t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: context.texts.titleSmall?.copyWith(
                  fontSize: 12.5,
                  color: selected ? t.accent : t.textMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: FanxSpace.xs + 2),
              Text(
                '$count',
                style: context.mono(
                  size: 10,
                  color: selected ? t.accent : t.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: FanxSpace.lg),
      decoration: BoxDecoration(
        color: t.surfaceSunken.withValues(alpha: t.isDark ? 0.5 : 0.55),
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 2,
            height: 10,
            color: t.accent.withValues(alpha: 0.7),
          ),
          const SizedBox(width: FanxSpace.sm),
          MetaTag(title, size: 9, tracking: 1.6, color: t.textMuted),
          const Spacer(),
          Text('$count', style: context.mono(size: 9.5, color: t.textFaint)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 行 + Agent 状态块
// ---------------------------------------------------------------------------

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({
    super.key,
    required this.item,
    required this.agents,
    required this.pending,
    required this.cellKey,
    required this.onToggle,
    required this.onInstall,
  });

  final LibraryItem item;
  final List<Agent> agents;
  final Set<String> pending;
  final String Function(String agentId, LibraryItem item) cellKey;
  final Future<void> Function(LibraryItem item, LibraryPresence presence)
  onToggle;
  final Future<void> Function(LibraryItem item, Agent target) onInstall;

  @override
  Widget build(BuildContext context) {
    final info = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Glyph(kind: item.kind, issues: item.hasIssues),
        const SizedBox(width: FanxSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.titleSmall?.copyWith(fontSize: 13),
                    ),
                  ),
                  if (item.hasIssues) ...[
                    const SizedBox(width: FanxSpace.sm),
                    Tooltip(
                      message: item.issues.join('\n'),
                      child: Icon(
                        Icons.error_outline,
                        size: 13,
                        color: context.tokens.danger,
                      ),
                    ),
                  ],
                ],
              ),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  item.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall?.copyWith(fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final chips = Wrap(
      alignment: WrapAlignment.end,
      spacing: FanxSpace.xs + 2,
      runSpacing: FanxSpace.xs + 2,
      children: [
        for (final agent in agents)
          _AgentChip(
            agent: agent,
            presence: item.presenceFor(agent.id),
            busy: pending.contains(cellKey(agent.id, item)),
            onToggle: (presence) => onToggle(item, presence),
            onInstall: () => onInstall(item, agent),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;

        return Container(
          padding: const EdgeInsets.fromLTRB(
            FanxSpace.lg,
            FanxSpace.sm + 2,
            FanxSpace.md,
            FanxSpace.sm + 2,
          ),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    info,
                    const SizedBox(height: FanxSpace.sm),
                    chips,
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 5, child: info),
                    const SizedBox(width: FanxSpace.md),
                    Flexible(
                      flex: 6,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: chips,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.kind, required this.issues});

  final String kind;
  final bool issues;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final letter = switch (kind) {
      'skill' => 'S',
      'extension' => 'E',
      _ => 'P',
    };
    final color = issues ? t.danger : t.accent;

    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(FanxRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        letter,
        style: context.mono(size: 11, color: color, weight: FontWeight.w600),
      ),
    );
  }
}

/// 一个 Agent 在这条资源上的状态块。
class _AgentChip extends StatefulWidget {
  const _AgentChip({
    required this.agent,
    required this.presence,
    required this.busy,
    required this.onToggle,
    required this.onInstall,
  });

  final Agent agent;
  final LibraryPresence? presence;
  final bool busy;
  final ValueChanged<LibraryPresence> onToggle;
  final VoidCallback onInstall;

  @override
  State<_AgentChip> createState() => _AgentChipState();
}

class _AgentChipState extends State<_AgentChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final presence = widget.presence;

    final (
      Color color,
      String tooltip,
      IconData icon,
      Color? fill,
    ) = switch (presence) {
      null => (
        t.textFaint,
        '未安装到 ${widget.agent.name}，点击从已有副本复制过来',
        Icons.add,
        null,
      ),
      LibraryPresence(enabled: false) => (
        t.textMuted,
        '已停用，点击启用',
        Icons.toggle_off_outlined,
        null,
      ),
      LibraryPresence(loaded: false) => (
        t.warning,
        '已启用，但 pi 没加载（看告警）',
        Icons.error_outline,
        t.warning.withValues(alpha: 0.08),
      ),
      _ => (t.accent, '已启用并已加载，点击停用', Icons.check, t.accentWash),
    };

    final borderColor = _hover
        ? (presence == null ? t.borderStrong : color.withValues(alpha: 0.7))
        : (presence == null ? t.border : color.withValues(alpha: 0.38));

    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.busy
              ? null
              : () => presence == null
                    ? widget.onInstall()
                    : widget.onToggle(presence),
          child: AnimatedContainer(
            duration: FanxMotion.fast,
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: FanxSpace.sm),
            decoration: BoxDecoration(
              color: fill ?? (_hover ? t.surfaceRaised : Colors.transparent),
              borderRadius: BorderRadius.circular(FanxRadius.xs),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.busy)
                  const FanxSpinner(size: 11)
                else
                  Icon(icon, size: 11, color: color),
                const SizedBox(width: FanxSpace.xs + 1),
                Text(
                  widget.agent.name,
                  style: context.mono(
                    size: 10,
                    color: presence == null ? t.textFaint : color,
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
