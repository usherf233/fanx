import 'package:flutter/material.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';
import 'resource_dialogs.dart';
import 'resource_inspector.dart';

/// 状态过滤：磁盘上启用与否。
enum ResourceStatusFilter { all, enabled, disabled }

/// 资源库：技能 / 扩展 / 提示词模板的统一管理面。
///
/// 布局是「总账 + 检视」两栏：左边按类型分组列出全部能力，右边把选中项的
/// SKILL.md、文件结构、真实加载状态摊开——不用离开界面去开资源管理器。
class LibraryView extends StatefulWidget {
  const LibraryView({super.key, required this.agent});

  final Agent agent;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  ResourceSnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  String? _notice;

  String _type = 'all';
  ResourceStatusFilter _status = ResourceStatusFilter.all;

  String? _selectedKey;
  ResourceDetail? _detail;
  bool _detailLoading = false;
  String? _detailError;

  /// 正在切换的资源 key，用来在行上显示转圈而不是整页刷新。
  final Set<String> _pending = {};
  bool _batchBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.id != widget.agent.id) {
      _snapshot = null;
      _detail = null;
      _selectedKey = null;
      _load();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  String _keyOf(ResourceItem item) => '${item.kind}:${item.name}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await appState.client.getResources(widget.agent.id);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
      final visible = _visible(snapshot);
      if (visible.isNotEmpty) {
        _select(visible.first);
      }
    } on ApiException catch (exception) {
      if (!mounted) return;
      setState(() {
        _error = exception.message;
        _loading = false;
      });
    }
  }

  List<ResourceItem> _visible([ResourceSnapshot? source]) {
    final snapshot = source ?? _snapshot;
    if (snapshot == null) return const [];
    final items = _type == 'all' ? snapshot.all : snapshot.of(_type);
    final keyword = _query.text.trim().toLowerCase();

    return items
        .where((item) {
          if (_status == ResourceStatusFilter.enabled && !item.enabled) {
            return false;
          }
          if (_status == ResourceStatusFilter.disabled && item.enabled) {
            return false;
          }
          if (keyword.isEmpty) return true;
          return item.name.toLowerCase().contains(keyword) ||
              item.description.toLowerCase().contains(keyword) ||
              (item.declaredName ?? '').toLowerCase().contains(keyword);
        })
        .toList(growable: false);
  }

  Future<void> _select(ResourceItem item) async {
    final key = _keyOf(item);
    if (_selectedKey == key && _detail != null) return;
    setState(() {
      _selectedKey = key;
      _detail = null;
      _detailError = null;
      _detailLoading = true;
    });

    try {
      final detail = await appState.client.getResourceDetail(
        widget.agent.id,
        type: '${item.kind}s',
        name: item.name,
      );
      // 连点两条时，晚到的旧响应不能覆盖新的选择。
      if (!mounted || _selectedKey != key) return;
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
    } on ApiException catch (exception) {
      if (!mounted || _selectedKey != key) return;
      setState(() {
        _detailError = exception.message;
        _detailLoading = false;
      });
    }
  }

  void _applySnapshot(ResourceSnapshot snapshot, {String? selectKey}) {
    setState(() => _snapshot = snapshot);
    final items = _visible(snapshot);
    if (items.isEmpty) {
      setState(() {
        _selectedKey = null;
        _detail = null;
      });
      return;
    }
    final target = selectKey == null
        ? items.firstWhere(
            (item) => _keyOf(item) == _selectedKey,
            orElse: () => items.first,
          )
        : items.firstWhere(
            (item) => _keyOf(item) == selectKey,
            orElse: () => items.first,
          );
    // 选中项没变时只刷新详情（状态可能变了），不重置选择。
    if (_keyOf(target) == _selectedKey) {
      _reloadDetail(target);
    } else {
      _select(target);
    }
  }

  Future<void> _reloadDetail(ResourceItem item) async {
    final key = _keyOf(item);
    try {
      final detail = await appState.client.getResourceDetail(
        widget.agent.id,
        type: '${item.kind}s',
        name: item.name,
      );
      if (!mounted || _selectedKey != key) return;
      setState(() => _detail = detail);
    } on ApiException {
      // 详情刷新失败不该把列表也拖下水，保留旧内容即可。
    }
  }

  Future<void> _toggle(ResourceItem item, bool enabled) async {
    final key = _keyOf(item);
    setState(() {
      _pending.add(key);
      _notice = null;
    });
    try {
      final snapshot = await appState.client.toggleResource(
        widget.agent.id,
        type: '${item.kind}s',
        name: item.name,
        enabled: enabled,
      );
      if (!mounted) return;
      _applySnapshot(snapshot);
      await appState.refresh();
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  /// 批量启停：当前视图里所有可操作的条目，一次改到位。
  Future<void> _batch(bool enabled) async {
    final items = _visible().where((item) => item.enabled != enabled).toList();
    if (items.isEmpty || _batchBusy) return;

    setState(() {
      _batchBusy = true;
      _notice = null;
    });
    try {
      // 后端按类型批量处理；「全部」视图下按类型拆成几次调用。
      for (final kind in ['skills', 'extensions', 'prompts']) {
        final names = items
            .where((item) => '${item.kind}s' == kind)
            .map((item) => item.name)
            .toList();
        if (names.isEmpty) continue;
        final snapshot = await appState.client.batchToggleResources(
          widget.agent.id,
          type: kind,
          names: names,
          enabled: enabled,
        );
        if (!mounted) return;
        setState(() => _snapshot = snapshot);
      }
      final fresh = await appState.client.getResources(widget.agent.id);
      if (!mounted) return;
      _applySnapshot(fresh);
      setState(() => _notice = '已${enabled ? '启用' : '停用'} ${items.length} 项');
      await appState.refresh();
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _import() async {
    final result = await ImportResourceDialog.show(
      context,
      agent: widget.agent,
    );
    if (result == null || !mounted) return;
    // 导入的可能是被筛掉的那一类，先把视图放宽再选中它。
    setState(() {
      _type = result.kind;
      _status = ResourceStatusFilter.all;
      _query.clear();
    });
    _applySnapshot(result.snapshot, selectKey: '${result.kind}:${result.name}');
    setState(() => _notice = '已导入 ${result.name}');
    await appState.refresh();
  }

  Future<void> _createSkill() async {
    final result = await CreateSkillDialog.show(context, agent: widget.agent);
    if (result == null || !mounted) return;
    setState(() {
      _type = 'skills';
      _status = ResourceStatusFilter.all;
      _query.clear();
    });
    _applySnapshot(result.snapshot, selectKey: 'skills:${result.name}');
    setState(() => _notice = '已创建 ${result.name}');
    await appState.refresh();
  }

  Future<void> _delete(ResourceItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除${item.kindLabel}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「${item.name}」会从磁盘删除，无法撤销。'),
            const SizedBox(height: FanxSpace.md),
            Text(
              item.relPath,
              style: dialogContext.mono(
                size: 11.5,
                color: dialogContext.tokens.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.tokens.danger,
              foregroundColor: dialogContext.tokens.isDark
                  ? const Color(0xFF1A0505)
                  : Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _pending.add(_keyOf(item)));
    try {
      final snapshot = await appState.client.deleteResource(
        widget.agent.id,
        type: '${item.kind}s',
        name: item.name,
      );
      if (!mounted) return;
      setState(() {
        _selectedKey = null;
        _detail = null;
      });
      _applySnapshot(snapshot);
      setState(() => _notice = '已删除 ${item.name}');
      await appState.refresh();
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _pending.remove(_keyOf(item)));
    }
  }

  void _openDetailDialog(ResourceItem item) {
    _select(item);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(FanxSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: ResourceInspector(
            detail: _detail,
            loading: _detailLoading,
            error: _detailError,
            fallback: item,
            pending: _pending.contains(_keyOf(item)),
            onToggle: (enabled) => _toggle(item, enabled),
            onDelete: () {
              Navigator.of(dialogContext).pop();
              _delete(item);
            },
            onClose: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        final snapshot = _snapshot;

        return Container(
          color: t.bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FanxSpace.xl,
                  FanxSpace.lg,
                  FanxSpace.xl,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _LibraryHeader(snapshot: snapshot, compact: compact),
                    const SizedBox(height: FanxSpace.xl),
                    _Toolbar(
                      type: _type,
                      status: _status,
                      snapshot: snapshot,
                      query: _query,
                      queryFocus: _queryFocus,
                      batchBusy: _batchBusy,
                      onType: (value) {
                        setState(() {
                          _type = value;
                          _selectedKey = null;
                          _detail = null;
                        });
                        final items = _visible();
                        if (items.isNotEmpty) _select(items.first);
                      },
                      onStatus: (value) {
                        setState(() {
                          _status = value;
                          _selectedKey = null;
                          _detail = null;
                        });
                        final items = _visible();
                        if (items.isNotEmpty) _select(items.first);
                      },
                      onQuery: () => setState(() {}),
                      onBatch: _batch,
                      onImport: _import,
                      onCreate: _createSkill,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: FanxSpace.md),
                      InlineNotice(
                        message: _error!,
                        onDismiss: () => setState(() => _error = null),
                      ),
                    ],
                    if (_notice != null) ...[
                      const SizedBox(height: FanxSpace.md),
                      InlineNotice(
                        message: _notice!,
                        tone: NoticeTone.success,
                        onDismiss: () => setState(() => _notice = null),
                      ),
                    ],
                    const SizedBox(height: FanxSpace.md),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FanxSpace.xl,
                    0,
                    FanxSpace.xl,
                    FanxSpace.xl,
                  ),
                  child: _loading
                      ? const LoadingBlock(label: 'scanning resources')
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _ListPanel(
                                items: _visible(),
                                grouped: _type == 'all',
                                selectedKey: _selectedKey,
                                pending: _pending,
                                query: _query.text.trim(),
                                onSelect: compact
                                    ? _openDetailDialog
                                    : (item) => _select(item),
                                onToggle: _toggle,
                                onImport: _import,
                                onCreate: _createSkill,
                              ),
                            ),
                            if (!compact) ...[
                              const SizedBox(width: FanxSpace.md),
                              SizedBox(
                                width: 356,
                                child: _InspectorShell(
                                  child: _buildInspector(),
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInspector() {
    final key = _selectedKey;
    ResourceItem? fallback;
    if (key != null) {
      for (final item in _visible()) {
        if (_keyOf(item) == key) {
          fallback = item;
          break;
        }
      }
    }
    final item = _detail?.item ?? fallback;

    if (item == null) {
      return const _InspectorIdle();
    }

    return ResourceInspector(
      detail: _detail,
      loading: _detailLoading,
      error: _detailError,
      fallback: item,
      pending: _pending.contains(key),
      onToggle: (enabled) => _toggle(item, enabled),
      onDelete: () => _delete(item),
      onClose: null,
    );
  }
}

// ---------------------------------------------------------------------------
// 页头：标题 + 读数台账
// ---------------------------------------------------------------------------

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({required this.snapshot, required this.compact});

  final ResourceSnapshot? snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '04',
                    style: context.monoLabel(
                      color: t.accent,
                      size: 10,
                      tracking: 2,
                    ),
                  ),
                  const SizedBox(width: FanxSpace.sm),
                  Container(width: 14, height: 1, color: t.borderStrong),
                  const SizedBox(width: FanxSpace.sm),
                  MetaTag('LIBRARY', size: 9, tracking: 1.8),
                ],
              ),
              const SizedBox(height: FanxSpace.sm + 2),
              Text('资源库', style: context.cnDisplay(size: 26, height: 1.25)),
              const SizedBox(height: FanxSpace.xs + 2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Text(
                  '技能、扩展、提示词模板都来自这个 Agent 自己的目录。启用即挂上，停用即移出——模型下次对话就能感到差别。',
                  style: context.texts.bodySmall?.copyWith(
                    color: t.textMuted,
                    height: 1.65,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!compact && snapshot != null) ...[
          const SizedBox(width: FanxSpace.xl),
          _Ledger(snapshot: snapshot!),
        ],
      ],
    );
  }
}

/// 读数台账：四个格子，第一位带琥珀竖条。数字用等宽、大字号、tabular。
class _Ledger extends StatelessWidget {
  const _Ledger({required this.snapshot});

  final ResourceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LedgerCell(
            label: 'TOTAL',
            value: '${snapshot.total}',
            unit: '项',
            accent: true,
          ),
          _LedgerCell(
            label: 'ENABLED',
            value: '${snapshot.enabledCount}',
            unit: '/ ${snapshot.total}',
          ),
          _LedgerCell(
            label: 'ON DISK',
            value: formatBytes(snapshot.bytes),
            unit: '',
          ),
          _LedgerCell(
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

class _LedgerCell extends StatelessWidget {
  const _LedgerCell({
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
        FanxSpace.lg,
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
              tracking: 1.6,
            ),
          ),
          const SizedBox(height: FanxSpace.xs + 1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: context.mono(
                  size: value.length > 6 ? 15 : 21,
                  color: danger ? t.danger : t.text,
                  weight: FontWeight.w500,
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

// ---------------------------------------------------------------------------
// 工具条
// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.type,
    required this.status,
    required this.snapshot,
    required this.query,
    required this.queryFocus,
    required this.batchBusy,
    required this.onType,
    required this.onStatus,
    required this.onQuery,
    required this.onBatch,
    required this.onImport,
    required this.onCreate,
  });

  final String type;
  final ResourceStatusFilter status;
  final ResourceSnapshot? snapshot;
  final TextEditingController query;
  final FocusNode queryFocus;
  final bool batchBusy;
  final ValueChanged<String> onType;
  final ValueChanged<ResourceStatusFilter> onStatus;
  final VoidCallback onQuery;
  final Future<void> Function(bool enabled) onBatch;
  final VoidCallback onImport;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final counts = snapshot;

    final segments = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Segment(
          label: '全部',
          count: counts?.total,
          selected: type == 'all',
          onTap: () => onType('all'),
        ),
        const SizedBox(width: FanxSpace.xs + 2),
        _Segment(
          label: '技能',
          count: counts?.skills.length,
          selected: type == 'skills',
          onTap: () => onType('skills'),
        ),
        const SizedBox(width: FanxSpace.xs + 2),
        _Segment(
          label: '扩展',
          count: counts?.extensions.length,
          selected: type == 'extensions',
          onTap: () => onType('extensions'),
        ),
        const SizedBox(width: FanxSpace.xs + 2),
        _Segment(
          label: '模板',
          count: counts?.prompts.length,
          selected: type == 'prompts',
          onTap: () => onType('prompts'),
        ),
      ],
    );

    final search = SizedBox(
      height: 34,
      child: TextField(
        controller: query,
        focusNode: queryFocus,
        onChanged: (_) => onQuery(),
        style: context.texts.bodySmall?.copyWith(color: t.text),
        decoration: InputDecoration(
          hintText: '搜索名称或描述',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: FanxSpace.sm,
            vertical: 0,
          ),
          prefixIcon: Icon(Icons.search, size: 14, color: t.textFaint),
          prefixIconConstraints: const BoxConstraints(minWidth: 30),
          suffixIcon: query.text.isEmpty
              ? null
              : InkWell(
                  onTap: () {
                    query.clear();
                    onQuery();
                  },
                  child: Icon(Icons.close, size: 13, color: t.textFaint),
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 28),
        ),
      ),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusButton(status: status, onStatus: onStatus),
        const SizedBox(width: FanxSpace.sm),
        PopupMenuButton<bool>(
          tooltip: '批量启停当前筛选结果',
          enabled: !batchBusy,
          position: PopupMenuPosition.under,
          onSelected: onBatch,
          itemBuilder: (context) => [
            PopupMenuItem(
              value: true,
              height: 36,
              child: Row(
                children: [
                  Icon(Icons.toggle_on_outlined, size: 15, color: t.textMuted),
                  const SizedBox(width: FanxSpace.sm),
                  Text('全部启用', style: context.texts.bodyMedium),
                ],
              ),
            ),
            PopupMenuItem(
              value: false,
              height: 36,
              child: Row(
                children: [
                  Icon(Icons.toggle_off_outlined, size: 15, color: t.textMuted),
                  const SizedBox(width: FanxSpace.sm),
                  Text('全部停用', style: context.texts.bodyMedium),
                ],
              ),
            ),
          ],
          child: _GhostButton(
            icon: Icons.checklist_rtl,
            label: '批量',
            busy: batchBusy,
          ),
        ),
        const SizedBox(width: FanxSpace.sm),
        OutlinedButton.icon(
          onPressed: onImport,
          icon: const Icon(Icons.file_download_outlined, size: 15),
          label: const Text('导入'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
          ),
        ),
        const SizedBox(width: FanxSpace.sm),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add, size: 15),
          label: const Text('新建技能'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 840) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: segments,
              ),
              const SizedBox(height: FanxSpace.sm),
              Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: FanxSpace.sm),
                  actions,
                ],
              ),
            ],
          );
        }

        return Row(
          children: [
            segments,
            const SizedBox(width: FanxSpace.lg),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: 260, child: search),
              ),
            ),
            actions,
          ],
        );
      },
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
  final int? count;
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
              if (count != null) ...[
                const SizedBox(width: FanxSpace.xs + 2),
                Text(
                  '$count',
                  style: context.mono(
                    size: 10,
                    color: selected ? t.accent : t.textFaint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({required this.status, required this.onStatus});

  final ResourceStatusFilter status;
  final ValueChanged<ResourceStatusFilter> onStatus;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final label = switch (status) {
      ResourceStatusFilter.all => '全部状态',
      ResourceStatusFilter.enabled => '仅启用',
      ResourceStatusFilter.disabled => '仅停用',
    };

    return PopupMenuButton<ResourceStatusFilter>(
      tooltip: '按状态筛选',
      position: PopupMenuPosition.under,
      initialValue: status,
      onSelected: onStatus,
      itemBuilder: (context) => [
        for (final value in ResourceStatusFilter.values)
          PopupMenuItem(
            value: value,
            height: 36,
            child: Text(
              switch (value) {
                ResourceStatusFilter.all => '全部状态',
                ResourceStatusFilter.enabled => '仅启用',
                ResourceStatusFilter.disabled => '仅停用',
              },
              style: context.texts.bodyMedium?.copyWith(
                color: value == status ? t.accent : t.text,
              ),
            ),
          ),
      ],
      child: _GhostButton(
        icon: Icons.filter_list,
        label: label,
        active: status != ResourceStatusFilter.all,
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
      decoration: BoxDecoration(
        color: active ? t.accentWash : Colors.transparent,
        borderRadius: BorderRadius.circular(FanxRadius.sm),
        border: Border.all(color: active ? t.accent : t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const FanxSpinner(size: 13)
          else
            Icon(icon, size: 14, color: active ? t.accent : t.textMuted),
          const SizedBox(width: FanxSpace.xs + 2),
          Text(
            label,
            style: context.texts.bodySmall?.copyWith(
              fontSize: 12,
              color: active ? t.accent : t.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 列表
// ---------------------------------------------------------------------------

class _ListPanel extends StatelessWidget {
  const _ListPanel({
    required this.items,
    required this.grouped,
    required this.selectedKey,
    required this.pending,
    required this.query,
    required this.onSelect,
    required this.onToggle,
    required this.onImport,
    required this.onCreate,
  });

  final List<ResourceItem> items;
  final bool grouped;
  final String? selectedKey;
  final Set<String> pending;
  final String query;
  final ValueChanged<ResourceItem> onSelect;
  final Future<void> Function(ResourceItem item, bool enabled) onToggle;
  final VoidCallback onImport;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

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
                    query.isEmpty ? '资源 / RESOURCE' : '筛选结果 / FILTERED',
                    size: 9,
                    tracking: 1.5,
                  ),
                ),
                const SizedBox(width: 60),
                SizedBox(
                  width: 54,
                  child: MetaTag('SIZE', size: 9, tracking: 1.5),
                ),
                SizedBox(
                  width: 92,
                  child: MetaTag('STATUS', size: 9, tracking: 1.5),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
          HairLine(color: t.border),
          Expanded(
            child: items.isEmpty
                ? _EmptyLibrary(
                    query: query.isNotEmpty,
                    onImport: onImport,
                    onCreate: onCreate,
                  )
                : Scrollbar(
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: FanxSpace.lg),
                      children: _buildRows(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRows() {
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

  Widget _rows(List<ResourceItem> group) {
    return Column(
      children: [
        for (var index = 0; index < group.length; index++) ...[
          if (index > 0) HairLine(),
          _ResourceRow(
            key: ValueKey('res-${group[index].kind}:${group[index].name}'),
            item: group[index],
            selected:
                selectedKey == '${group[index].kind}:${group[index].name}',
            busy: pending.contains('${group[index].kind}:${group[index].name}'),
            onTap: () => onSelect(group[index]),
            onToggle: (enabled) => onToggle(group[index], enabled),
          ),
        ],
      ],
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

class _ResourceRow extends StatefulWidget {
  const _ResourceRow({
    super.key,
    required this.item,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onToggle,
  });

  final ResourceItem item;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  @override
  State<_ResourceRow> createState() => _ResourceRowState();
}

class _ResourceRowState extends State<_ResourceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final item = widget.item;
    final selected = widget.selected;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          decoration: BoxDecoration(
            color: selected
                ? t.accentWash
                : _hover
                ? t.surfaceRaised
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? t.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            FanxSpace.lg - 2,
            FanxSpace.sm + 2,
            FanxSpace.md,
            FanxSpace.sm + 2,
          ),
          child: Row(
            children: [
              _Glyph(kind: item.kind, enabled: item.enabled),
              const SizedBox(width: FanxSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.titleSmall?.copyWith(
                              fontSize: 13,
                              color: item.enabled ? t.text : t.textMuted,
                            ),
                          ),
                        ),
                        if (item.hasIssues) ...[
                          const SizedBox(width: FanxSpace.sm),
                          Tooltip(
                            message: item.issues.join('\n'),
                            child: Icon(
                              Icons.error_outline,
                              size: 13,
                              color: t.danger.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                        if (item.nameMismatch) ...[
                          const SizedBox(width: FanxSpace.sm),
                          Tooltip(
                            message: '目录名与 SKILL.md 里声明的 name 不一致',
                            child: MetaTag(
                              'ALIAS',
                              size: 8,
                              tracking: 1.2,
                              color: t.warning,
                              bracket: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.description.isEmpty
                          ? item.relPath
                          : item.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: t.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: FanxSpace.md),
              SizedBox(
                width: 60,
                child: Text(
                  item.sizeLabel,
                  textAlign: TextAlign.right,
                  style: context.mono(size: 10.5, color: t.textFaint),
                ),
              ),
              SizedBox(
                width: 92,
                child: Padding(
                  padding: const EdgeInsets.only(left: FanxSpace.md),
                  child: _StatusLabel(item: item),
                ),
              ),
              SizedBox(
                width: 44,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: widget.busy
                      ? const FanxSpinner(size: 16)
                      : Transform.scale(
                          scale: 0.72,
                          child: Switch(
                            value: item.enabled,
                            onChanged: widget.onToggle,
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
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.kind, required this.enabled});

  final String kind;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final letter = switch (kind) {
      'skill' => 'S',
      'extension' => 'E',
      _ => 'P',
    };
    final tint = enabled ? t.accent : t.textFaint;

    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled ? t.accentWash : t.surfaceSunken,
        borderRadius: BorderRadius.circular(FanxRadius.xs),
        border: Border.all(
          color: enabled ? t.accent.withValues(alpha: 0.45) : t.border,
        ),
      ),
      child: Text(
        letter,
        style: context.mono(size: 11, color: tint, weight: FontWeight.w600),
      ),
    );
  }
}

/// 三态读数：已加载 / 已启用但没进上下文 / 已停用。
class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.item});

  final ResourceItem item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final (color, text) = switch ((item.enabled, item.loaded)) {
      (false, _) => (t.textFaint, '已停用'),
      (true, true) => (t.success, '已加载'),
      (true, false) => (t.warning, '未加载'),
      (true, null) => (t.accent, '已启用'),
    };

    return Row(
      children: [
        StatusDot(color: color, size: 5),
        const SizedBox(width: FanxSpace.xs + 2),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.mono(size: 10, color: color),
          ),
        ),
      ],
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.query,
    required this.onImport,
    required this.onCreate,
  });

  final bool query;
  final VoidCallback onImport;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    if (query) {
      return const EmptyState(
        title: '没有匹配的资源',
        hint: '换个关键词，或把类型和状态筛选放宽。',
        icon: Icons.search_off,
      );
    }
    return EmptyState(
      title: '这个 Agent 还没有任何能力',
      hint: '放入一个含 SKILL.md 的目录，或从本机已有技能导入。也可以先建一个空技能，把内容补上。',
      icon: Icons.inventory_2_outlined,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_download_outlined, size: 15),
            label: const Text('导入'),
          ),
          const SizedBox(width: FanxSpace.sm),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 15),
            label: const Text('新建技能'),
          ),
        ],
      ),
    );
  }
}

class _InspectorShell extends StatelessWidget {
  const _InspectorShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FanxRadius.lg),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _InspectorIdle extends StatelessWidget {
  const _InspectorIdle();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.all(FanxSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetaTag('INSPECTOR', size: 9, tracking: 1.8),
          const SizedBox(height: FanxSpace.md),
          Text('选中左侧任意一条', style: context.cnDisplay(size: 17, height: 1.4)),
          const SizedBox(height: FanxSpace.sm),
          Text(
            '这里会摊开它的 SKILL.md、文件结构、磁盘大小，以及 pi 到底有没有把它装进上下文。',
            style: context.texts.bodySmall?.copyWith(
              color: t.textMuted,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}
