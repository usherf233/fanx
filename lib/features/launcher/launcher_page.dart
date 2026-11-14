import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';
import '../agents/create_agent_dialog.dart';

/// 启动页：先选 Agent 再进工作区。
/// 视觉上是一块"仪表盘首页"：品牌条 + 读数 + 编号卡片网格。
class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  @override
  void initState() {
    super.initState();
    appState.refresh();
  }

  Future<void> _create() async {
    final agent = await CreateAgentDialog.show(context);
    if (agent != null && mounted) context.go('/a/${agent.id}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GridBackdrop(
        child: SafeArea(
          child: AnimatedBuilder(
            animation: appState,
            builder: (context, _) {
              if (appState.offline) {
                return _OfflineView(onRetry: appState.refresh);
              }

              return Column(
                children: [
                  const _BrandBar(),
                  const HairLine(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FanxSpace.xxl,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1120),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: FanxSpace.giant),
                              Reveal(
                                index: 0,
                                child: _Headline(count: appState.agents.length),
                              ),
                              const SizedBox(height: FanxSpace.xxl),
                              if (appState.loading && appState.agents.isEmpty)
                                const _LoadingRack()
                              else
                                _AgentGrid(onCreate: _create),
                              const SizedBox(height: FanxSpace.xxl),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 刻度条贴住窗口底部，让页面有"仪表盘底边"，不在内容后悬空。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FanxSpace.xxl,
                      0,
                      FanxSpace.xxl,
                      FanxSpace.md,
                    ),
                    child: _Footer(total: appState.agents.length),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 品牌条
// ---------------------------------------------------------------------------

class _BrandBar extends StatelessWidget {
  const _BrandBar();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xxl,
        FanxSpace.md,
        FanxSpace.lg,
        FanxSpace.md,
      ),
      child: Row(
        children: [
          // 品牌标记：一个琥珀方块 + 字标，全站唯一的高饱和色块。
          Container(width: 9, height: 9, color: t.accent),
          const SizedBox(width: FanxSpace.sm),
          Text(
            'FANX',
            style: context.monoLabel(color: t.text, size: 12, tracking: 4),
          ),
          const SizedBox(width: FanxSpace.md),
          MetaTag('LOCAL AGENT CONSOLE', bracket: true, size: 9.5),
          const Spacer(),
          _GhostAction(
            icon: Icons.inventory_2_outlined,
            label: 'LIBRARY',
            onTap: () => context.go('/library'),
          ),
          const SizedBox(width: FanxSpace.sm),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeController,
            builder: (context, mode, _) {
              return Tooltip(
                message: '${themeModeLabel(mode)}（点击切换）',
                child: _GhostAction(
                  icon: themeModeIcon(mode),
                  label: mode == ThemeMode.dark
                      ? 'DARK'
                      : (mode == ThemeMode.light ? 'LIGHT' : 'AUTO'),
                  onTap: cycleThemeMode,
                ),
              );
            },
          ),
          const SizedBox(width: FanxSpace.sm),
          _GhostAction(
            icon: Icons.refresh,
            label: 'REFRESH',
            onTap: appState.loading ? null : appState.refresh,
          ),
        ],
      ),
    );
  }
}

class _GhostAction extends StatefulWidget {
  const _GhostAction({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_GhostAction> createState() => _GhostActionState();
}

class _GhostActionState extends State<_GhostAction> {
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
              AnimatedRotation(
                duration: FanxMotion.slow,
                turns: _hover ? 0.5 : 0,
                child: Icon(
                  widget.icon,
                  size: 13,
                  color: _hover ? t.text : t.textMuted,
                ),
              ),
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

// ---------------------------------------------------------------------------
// 标题 + 读数
// ---------------------------------------------------------------------------

class _Headline extends StatelessWidget {
  const _Headline({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final running = appState.agents.where((agent) => agent.running).length;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MetaTag(
                'SECTION 01 — SELECT',
                color: t.accent,
                size: 10,
                tracking: 2.2,
              ),
              const SizedBox(height: FanxSpace.md),
              Text(
                '选择一个 Agent',
                style: context.cnDisplay(size: 40, height: 1.16),
              ),
              const SizedBox(height: FanxSpace.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  '每个 Agent 拥有独立的技能、提示词、模型凭据与会话历史。'
                  '配置目录与工作目录分离，互不污染。',
                  style: context.texts.bodyMedium?.copyWith(
                    color: t.textMuted,
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: FanxSpace.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _Readout(value: '$count', label: 'AGENTS', padded: true),
            const SizedBox(width: FanxSpace.lg),
            _Readout(
              value: '$running',
              label: 'RUNNING',
              padded: true,
              accent: running > 0,
            ),
            const SizedBox(width: FanxSpace.lg),
            _Readout(value: 'OK', label: 'DAEMON', ok: true),
          ],
        ),
      ],
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.value,
    required this.label,
    this.accent = false,
    this.ok = false,
    this.padded = false,
  });

  final String value;
  final String label;
  final bool accent;
  final bool ok;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final display = padded && int.tryParse(value) != null
        ? value.padLeft(2, '0')
        : value;
    final color = accent ? t.accent : (ok ? t.success : t.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ok) ...[
              StatusDot(color: t.success, pulsing: true),
              const SizedBox(width: FanxSpace.sm),
            ],
            Text(
              display,
              style: TextStyle(
                fontFamily: FanxFonts.display,
                fontSize: 26,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.8,
                height: 1,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: FanxSpace.xs + 2),
        Container(width: 26, height: 2, color: color.withValues(alpha: 0.5)),
        const SizedBox(height: FanxSpace.xs + 2),
        MetaTag(label, size: 9, tracking: 1.8),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 卡片网格
// ---------------------------------------------------------------------------

class _AgentGrid extends StatelessWidget {
  const _AgentGrid({required this.onCreate});

  final Future<void> Function() onCreate;

  @override
  Widget build(BuildContext context) {
    final agents = appState.agents;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 980
            ? 3
            : constraints.maxWidth >= 640
            ? 2
            : 1;
        const spacing = FanxSpace.md + 2;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < agents.length; i++)
              SizedBox(
                width: width,
                child: Reveal(
                  index: (i + 1).clamp(0, 5),
                  child: _AgentCard(agent: agents[i], index: i + 1),
                ),
              ),
            SizedBox(
              width: width,
              child: Reveal(
                index: (agents.length + 1).clamp(0, 5),
                child: _CreateCard(onTap: onCreate),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AgentCard extends StatefulWidget {
  const _AgentCard({required this.agent, required this.index});

  final Agent agent;
  final int index;

  @override
  State<_AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<_AgentCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final agent = widget.agent;
    final radius = BorderRadius.circular(FanxRadius.md);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => context.go('/a/${agent.id}'),
        child: AnimatedContainer(
          duration: FanxMotion.base,
          curve: FanxMotion.out,
          height: 178,
          transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
          decoration: BoxDecoration(
            color: _hover ? t.surfaceRaised : t.surface,
            borderRadius: radius,
            border: Border.all(color: _hover ? t.borderStrong : t.border),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                // 悬停时左侧浮出琥珀竖条，作为"被选中"的机械反馈。
                AnimatedPositioned(
                  duration: FanxMotion.base,
                  curve: FanxMotion.out,
                  left: 0,
                  top: _hover ? 0 : 24,
                  bottom: _hover ? 0 : 24,
                  child: AnimatedContainer(
                    duration: FanxMotion.base,
                    width: 2,
                    color: _hover ? t.accent : Colors.transparent,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FanxSpace.lg,
                    FanxSpace.md + 2,
                    FanxSpace.md,
                    FanxSpace.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          MetaTag(
                            '${widget.index}'.padLeft(2, '0'),
                            color: _hover ? t.accent : t.textFaint,
                            size: 10,
                            tracking: 2,
                          ),
                          const SizedBox(width: FanxSpace.sm),
                          HairLine(color: t.border).withWidth(18),
                          const Spacer(),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusDot(
                                color: agent.running ? t.success : t.textFaint,
                                pulsing: agent.running,
                              ),
                              const SizedBox(width: FanxSpace.xs + 2),
                              MetaTag(
                                agent.running ? 'RUNNING' : 'IDLE',
                                color: agent.running ? t.success : t.textFaint,
                                size: 9,
                                tracking: 1.6,
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: FanxSpace.md + 2),
                      Text(
                        agent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleLarge?.copyWith(
                          fontFamilyFallback: FanxFonts.fallback,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: FanxSpace.xs),
                      Text(
                        agent.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.mono(size: 11, color: t.textFaint),
                      ),
                      const SizedBox(height: FanxSpace.sm + 2),
                      Expanded(
                        child: Text(
                          agent.description.isEmpty
                              ? '未填写描述'
                              : agent.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall?.copyWith(
                            color: agent.description.isEmpty
                                ? t.textFaint
                                : t.textMuted,
                            height: 1.55,
                          ),
                        ),
                      ),
                      HairLine(color: _hover ? t.borderStrong : t.border),
                      const SizedBox(height: FanxSpace.sm + 2),
                      Row(
                        children: [
                          _Metric(value: agent.skills, label: 'SKILL'),
                          const SizedBox(width: FanxSpace.md),
                          _Metric(value: agent.extensions, label: 'EXT'),
                          const SizedBox(width: FanxSpace.md),
                          _Metric(value: agent.prompts, label: 'PROMPT'),
                          const Spacer(),
                          AnimatedSlide(
                            duration: FanxMotion.base,
                            curve: FanxMotion.out,
                            offset: Offset(_hover ? 0 : -0.4, 0),
                            child: AnimatedOpacity(
                              duration: FanxMotion.fast,
                              opacity: _hover ? 1 : 0,
                              child: Icon(
                                Icons.arrow_forward,
                                size: 14,
                                color: t.accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$value'.padLeft(2, '0'),
          style: context.mono(size: 12, color: t.text),
        ),
        const SizedBox(width: 3),
        MetaTag(label, size: 8.5, tracking: 1.2),
      ],
    );
  }
}

class _CreateCard extends StatefulWidget {
  const _CreateCard({required this.onTap});

  final Future<void> Function() onTap;

  @override
  State<_CreateCard> createState() => _CreateCardState();
}

class _CreateCardState extends State<_CreateCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.onTap(),
        // 虚线框表示"这里是一个空槽"，与实心的已有 Agent 卡片形成层级差异。
        child: DashedBox(
          color: _hover ? t.accent : t.borderStrong,
          fill: _hover ? t.accentWash : Colors.transparent,
          child: SizedBox(
            height: 178,
            width: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _hover ? t.accent : t.borderStrong,
                    ),
                    borderRadius: BorderRadius.circular(FanxRadius.sm),
                  ),
                  child: Icon(
                    Icons.add,
                    size: 16,
                    color: _hover ? t.accent : t.textMuted,
                  ),
                ),
                const SizedBox(height: FanxSpace.md),
                Text(
                  '新建 Agent',
                  style: context.texts.titleMedium?.copyWith(
                    color: _hover ? t.text : t.textMuted,
                  ),
                ),
                const SizedBox(height: FanxSpace.xs + 2),
                MetaTag(
                  'INDEPENDENT CONFIG + WORKSPACE',
                  size: 9,
                  tracking: 1.4,
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
// 加载 / 页脚
// ---------------------------------------------------------------------------

class _LoadingRack extends StatelessWidget {
  const _LoadingRack();

  @override
  Widget build(BuildContext context) {
    // 列宽与 _AgentGrid 完全一致：加载完成时卡片不会跳位置。
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 980
            ? 3
            : constraints.maxWidth >= 640
            ? 2
            : 1;
        const spacing = FanxSpace.md + 2;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < 3; i++)
              SkeletonBox(
                width: width,
                height: 178,
                radius: FanxRadius.md,
                delay: Duration(milliseconds: i * 140),
              ),
          ],
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.total});

  /// 必须由外部传入：const 实例在 Element 复用时会被跳过重建，
  /// 内部读全局状态会永远停留在首帧的 0。
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TickStrip(count: 64, color: t.border),
        const SizedBox(height: FanxSpace.sm + 2),
        Row(
          children: [
            StatusDot(color: t.success),
            const SizedBox(width: FanxSpace.sm),
            Text(
              '已连接 daemon · $total 个 Agent',
              style: context.mono(size: 11, color: t.textMuted),
            ),
            const Spacer(),
            MetaTag('FANX v1.0.0', size: 9.5, tracking: 1.6),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 离线态
// ---------------------------------------------------------------------------

class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MetaTag(
              'CONNECTION / LOST',
              color: t.danger,
              size: 10,
              tracking: 2.2,
            ),
            const SizedBox(height: FanxSpace.lg),
            Text('连不上 daemon', style: context.cnDisplay(size: 28)),
            const SizedBox(height: FanxSpace.md),
            Text(
              appState.error ?? '请先启动后端服务。',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall?.copyWith(color: t.textMuted),
            ),
            const SizedBox(height: FanxSpace.lg),
            EmptyState(
              title: '启动命令',
              code: 'cd daemon && bun run dev',
              hint: '服务起来后点重试即可，不需要重启界面。',
              action: FilledButton.icon(
                onPressed: () => onRetry(),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('重新连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _HairLineWidth on Widget {
  Widget withWidth(double width) => SizedBox(width: width, child: this);
}
