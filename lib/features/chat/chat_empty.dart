import 'package:flutter/material.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';

/// 空会话：一张「运行配置铭牌」，而不是三条示例提示。
///
/// 之前这里写死显示「未选模型」——后端在没有 runtime 时（首次进入、只读预览）
/// 返回的 state 不带 model 字段，前端就误判成没配置。模型其实一直写在
/// models.json 里。所以这里直接读 getModels() / getResources() 的真实配置，
/// 把模型、技能、扩展、模板的具体名字列出来，模型行本身也是切换入口。
///
/// 视觉延续全站的工业仪表盘语言：等宽读数、发丝线分组、左窄右宽的非对称
/// 清单。只有一个强调色（accent），只留给当前模型与可点动作。
class ChatEmptyState extends StatefulWidget {
  const ChatEmptyState({
    super.key,
    required this.agent,
    this.runtimeModelLabel,
    this.onOpenModels,
  });

  final Agent agent;
  final String? runtimeModelLabel;
  final VoidCallback? onOpenModels;

  @override
  State<ChatEmptyState> createState() => _ChatEmptyStateState();
}

class _ChatEmptyStateState extends State<ChatEmptyState>
    with SingleTickerProviderStateMixin {
  AgentModels? _models;
  ResourceSnapshot? _resources;
  bool _loading = true;
  bool _switching = false;
  String? _notice;
  final Set<String> _expanded = <String>{};

  /// 一次编排好的入场序列：单个 controller，5 组错峰，不常驻、不 repeat。
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  late final List<CurvedAnimation> _stages = List<CurvedAnimation>.generate(
    5,
    (index) {
      final start = (index * 0.11).clamp(0.0, 0.46);
      return CurvedAnimation(
        parent: _intro,
        curve: Interval(
          start,
          (start + 0.54).clamp(0.0, 1.0),
          curve: FanxMotion.out,
        ),
      );
    },
    growable: false,
  );
  bool _introStarted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_introStarted) return;
    _introStarted = true;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _intro.value = 1;
    } else {
      _intro.forward();
    }
  }

  @override
  void didUpdateWidget(covariant ChatEmptyState oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换 Agent 时整块配置都要重读，不能把上一个 Agent 的技能名单留着。
    if (oldWidget.agent.id != widget.agent.id) {
      _models = null;
      _resources = null;
      _expanded.clear();
      _notice = null;
      _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    for (final stage in _stages) {
      stage.dispose();
    }
    _intro.dispose();
    super.dispose();
  }

  /// 模型配置与资源快照互不依赖，并行取；接口不可用时降级成计数读数。
  Future<void> _load() async {
    late final AgentModels models;
    late final ResourceSnapshot resources;
    try {
      await Future.wait<void>([
        appState.client
            .getModels(widget.agent.id)
            .then((value) => models = value),
        appState.client
            .getResources(widget.agent.id)
            .then((value) => resources = value),
      ]);
    } on ApiException {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _models = models;
      _resources = resources;
      _loading = false;
    });
  }

  String get _modelLabel =>
      _models?.currentLabel ?? widget.runtimeModelLabel ?? '';

  List<({String provider, String model, String label})> get _options => [
    for (final provider in _models?.providers ?? const <ConfiguredProvider>[])
      for (final model in provider.models)
        (
          provider: provider.id,
          model: model.id,
          label: '${provider.id} / ${model.id}',
        ),
  ];

  Future<void> _onSelected(String value) async {
    if (value == '__manage__') {
      widget.onOpenModels?.call();
      return;
    }
    final parts = value.split('\u0000');
    if (parts.length != 2) return;
    setState(() {
      _switching = true;
      _notice = null;
    });
    try {
      await appState.client.selectModel(
        widget.agent.id,
        provider: parts[0],
        model: parts[1],
      );
      await _load();
      if (!mounted) return;
      setState(() {
        _switching = false;
        _notice = '已切换到 ${parts[0]} / ${parts[1]}';
      });
    } on ApiException catch (exception) {
      if (!mounted) return;
      setState(() {
        _switching = false;
        _notice = exception.message;
      });
    }
  }

  Widget _stage(int index, Widget child) {
    final animation = _stages[index.clamp(0, _stages.length - 1)];
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final resources = _resources;
    final groups = <_Group>[
      _Group(
        key: 'skills',
        en: 'SKILLS',
        cn: '技能',
        items: resources?.skills ?? const <ResourceItem>[],
      ),
      _Group(
        key: 'extensions',
        en: 'EXTENSIONS',
        cn: '扩展 / 插件',
        items: resources?.extensions ?? const <ResourceItem>[],
      ),
      _Group(
        key: 'prompts',
        en: 'PROMPTS',
        cn: '提示词模板',
        items: resources?.prompts ?? const <ResourceItem>[],
      ),
    ];
    final total = groups.fold<int>(0, (sum, group) => sum + group.items.length);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: FanxSpace.xxl,
          vertical: FanxSpace.xl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _stage(0, _Header(agent: widget.agent)),
              const SizedBox(height: FanxSpace.xl),
              _stage(
                1,
                Column(
                  children: [
                    _ModelSection(
                      loading: _loading,
                      label: _modelLabel,
                      runtimeLoaded: widget.runtimeModelLabel != null,
                      switching: _switching,
                      notice: _notice,
                      options: _options,
                      currentModel:
                          _models?.activeModel ?? _models?.defaultModel,
                      onOpenModels: widget.onOpenModels,
                      onSelected: _onSelected,
                    ),
                    _rule(t),
                  ],
                ),
              ),
              for (var i = 0; i < groups.length; i++)
                _stage(
                  2 + i,
                  Column(
                    children: [
                      _ResourceSection(
                        group: groups[i],
                        loading: _loading,
                        expanded: _expanded.contains(groups[i].key),
                        onToggle: () {
                          setState(() {
                            final key = groups[i].key;
                            if (!_expanded.remove(key)) _expanded.add(key);
                          });
                        },
                        fallbackCount: switch (groups[i].key) {
                          'skills' => widget.agent.skills,
                          'extensions' => widget.agent.extensions,
                          _ => widget.agent.prompts,
                        },
                      ),
                      if (i < groups.length - 1) _rule(t),
                    ],
                  ),
                ),
              const SizedBox(height: FanxSpace.md),
              _Footer(
                cwd: widget.agent.cwd,
                total: total,
                degraded: resources == null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _rule(FanxTokens t) => Padding(
  padding: const EdgeInsets.symmetric(vertical: FanxSpace.md),
  child: HairLine(color: t.border),
);

String _pad(int value) => value.toString().padLeft(2, '0');

// ---------------------------------------------------------------------------
// 头部：左标识 / 右铭牌，非对称
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.agent});

  final Agent agent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final initial = agent.name.isEmpty ? '?' : agent.name.characters.first;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.accent,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
          ),
          child: Text(
            initial,
            style: TextStyle(
              fontFamilyFallback: FanxFonts.fallback,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: t.onAccent,
            ),
          ),
        ),
        const SizedBox(width: FanxSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                agent.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.cnDisplay(size: 23, height: 1.12),
              ),
              const SizedBox(height: 2),
              Text(
                agent.description.isEmpty ? '空会话' : agent.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall?.copyWith(
                  fontSize: 11.5,
                  color: t.textMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: FanxSpace.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            MetaTag('AGENT / ${agent.id.toUpperCase()}', size: 9, tracking: 1.5),
            const SizedBox(height: FanxSpace.xs + 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 14, height: 1, color: t.accent),
                const SizedBox(width: FanxSpace.xs + 2),
                Text(
                  'SESSION 00',
                  style: context.mono(size: 10, color: t.textMuted),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 模型：可点切换
// ---------------------------------------------------------------------------

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.loading,
    required this.label,
    required this.runtimeLoaded,
    required this.switching,
    required this.notice,
    required this.options,
    required this.currentModel,
    required this.onOpenModels,
    required this.onSelected,
  });

  final bool loading;
  final String label;
  final bool runtimeLoaded;
  final bool switching;
  final String? notice;
  final List<({String provider, String model, String label})> options;
  final String? currentModel;
  final VoidCallback? onOpenModels;
  final Future<void> Function(String value) onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final empty = label.isEmpty;
    final text = loading
        ? '读取模型配置…'
        : empty
        ? '尚未配置模型'
        : label;
    final hint = notice != null
        ? notice!
        : empty
        ? '到「模型」标签页添加端点与模型'
        : runtimeLoaded
        ? '运行时已加载 · 点击切换'
        : '配置已就绪 · 发送首条消息时加载 · 点击切换';

    return SizedBox(
      width: double.infinity,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        tooltip: '',
        enabled: !switching && !loading,
        color: t.surfaceRaised,
        elevation: 0,
        offset: const Offset(0, 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FanxRadius.md),
          side: BorderSide(color: t.borderStrong),
        ),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final option in options)
            PopupMenuItem<String>(
              value: '${option.provider}\u0000${option.model}',
              height: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    child: option.model == currentModel
                        ? Icon(Icons.check, size: 13, color: t.accent)
                        : null,
                  ),
                  const SizedBox(width: FanxSpace.sm),
                  Expanded(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.mono(size: 11.5, color: t.text),
                    ),
                  ),
                ],
              ),
            ),
          if (onOpenModels != null) ...[
            const PopupMenuDivider(height: 1),
            PopupMenuItem<String>(
              value: '__manage__',
              height: 38,
              child: Text(
                '管理模型 / 端点…',
                style: context.texts.bodySmall?.copyWith(
                  fontSize: 11.5,
                  color: t.textMuted,
                ),
              ),
            ),
          ],
        ],
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(
              en: 'MODEL',
              cn: '当前模型',
              accent: true,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.mono(
                            size: 14,
                            weight: FontWeight.w600,
                            color: empty && !loading ? t.textMuted : t.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: FanxSpace.sm),
                      if (switching)
                        FanxSpinner(size: 11, color: t.accent)
                      else
                        Icon(
                          Icons.expand_more,
                          size: 14,
                          color: t.textFaint,
                        ),
                    ],
                  ),
                  const SizedBox(height: FanxSpace.xs + 1),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall?.copyWith(
                      fontSize: 10.5,
                      color: notice != null ? t.accent : t.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 资源组：具体名字，而不是「2 技能」这种计数
// ---------------------------------------------------------------------------

class _Group {
  const _Group({
    required this.key,
    required this.en,
    required this.cn,
    required this.items,
  });

  final String key;
  final String en;
  final String cn;
  final List<ResourceItem> items;
}

class _ResourceSection extends StatelessWidget {
  const _ResourceSection({
    required this.group,
    required this.loading,
    required this.expanded,
    required this.onToggle,
    required this.fallbackCount,
  });

  final _Group group;
  final bool loading;
  final bool expanded;
  final VoidCallback onToggle;
  final int fallbackCount;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final items = group.items;
    // 配置太多时先收着，避免空态变成一屏滚动列表。
    const int previewCount = 5;
    final visible = expanded || items.length <= previewCount
        ? items
        : items.sublist(0, previewCount);

    return SizedBox(
      width: double.infinity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(
            en: '${group.en}  ${_pad(items.length)}',
            cn: group.cn,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (items.isEmpty)
                  Text(
                    loading
                        ? '读取中…'
                        : fallbackCount > 0
                        ? '$fallbackCount 项已安装 · 详情见「资源库」'
                        : '未安装 · 到「资源库」添加',
                    style: context.texts.bodySmall?.copyWith(
                      fontSize: 11,
                      color: t.textFaint,
                    ),
                  ),
                for (var i = 0; i < visible.length; i++)
                  _ResourceLine(index: i, item: visible[i]),
                if (items.length > previewCount)
                  GestureDetector(
                    onTap: onToggle,
                    child: Padding(
                      padding: const EdgeInsets.only(top: FanxSpace.xs),
                      child: Text(
                        expanded
                            ? '收起'
                            : '+ ${items.length - previewCount} 项 · 展开全部',
                        style: context.mono(size: 10, color: t.accent),
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

class _ResourceLine extends StatelessWidget {
  const _ResourceLine({required this.index, required this.item});

  final int index;
  final ResourceItem item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final dimmed = !item.enabled;

    return Padding(
      padding: const EdgeInsets.only(bottom: FanxSpace.xs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              _pad(index + 1),
              style: context.mono(size: 10, color: t.textFaint),
            ),
          ),
          Flexible(
            flex: 3,
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.mono(
                size: 11.5,
                color: dimmed ? t.textFaint : t.text,
              ),
            ),
          ),
          const SizedBox(width: FanxSpace.sm),
          Expanded(
            flex: 4,
            child: Text(
              item.description.isEmpty ? item.relPath : item.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall?.copyWith(
                fontSize: 10.5,
                color: t.textFaint,
              ),
            ),
          ),
          if (dimmed)
            _Marker(label: '停用', color: t.textFaint)
          else if (item.loaded == false)
            _Marker(label: '未加载', color: t.warning),
        ],
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: FanxSpace.sm),
      child: Text(
        label,
        style: context.mono(size: 9.5, color: color),
      ),
    );
  }
}

/// 左列：等宽类别 + 中文名 + 计数，右列内容对齐同一条竖线。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.en,
    required this.cn,
    this.accent = false,
  });

  final String en;
  final String cn;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetaTag(
            en,
            size: 9.5,
            tracking: 1.6,
            color: accent ? t.accent : t.textMuted,
          ),
          const SizedBox(height: FanxSpace.xs + 1),
          Text(
            cn,
            style: context.texts.bodySmall?.copyWith(
              fontSize: 11,
              color: t.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 底部铭牌
// ---------------------------------------------------------------------------

class _Footer extends StatelessWidget {
  const _Footer({
    required this.cwd,
    required this.total,
    required this.degraded,
  });

  final String cwd;
  final int total;
  final bool degraded;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        Expanded(
          child: Text(
            cwd.isEmpty ? '工作目录未设置' : cwd,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.mono(size: 9.5, color: t.textFaint),
          ),
        ),
        const SizedBox(width: FanxSpace.md),
        Text(
          degraded ? '配置读取失败 · 显示概要' : '$total 项配置已就绪',
          style: context.mono(size: 9.5, color: t.textFaint),
        ),
      ],
    );
  }
}
