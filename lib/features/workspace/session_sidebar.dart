import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';

/// 删除条目的退场时长。父级等这段动画走完再刷新列表，避免条目瞬间跳没。
const Duration kSessionExitDuration = FanxMotion.base;

/// 左侧会话栏：这个 Agent 的全部历史会话。
/// 会话是 Agent 私有的，所以列表只服务当前这一个 Agent。
class SessionSidebar extends StatelessWidget {
  const SessionSidebar({
    super.key,
    required this.sessions,
    required this.activeSessionId,
    required this.loading,
    required this.busy,
    required this.onNew,
    required this.onRefresh,
    required this.onPreview,
    required this.onDelete,
    this.pendingSessionId,
    this.runningSessionId,
    this.deletingSessionIds = const <String>{},
    this.exitingSessionIds = const <String>{},
  });

  final List<AgentSession> sessions;

  /// 当前正在查看的会话（点击即高亮）。
  final String? activeSessionId;

  /// 后端真正激活的会话；与查看会话不同时在条目上标「预览」。
  final String? runningSessionId;
  final bool loading;
  final bool busy;
  final Future<void> Function() onNew;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onPreview;
  final Future<void> Function(AgentSession session) onDelete;

  /// 正在读盘取预览历史的会话：点击后立刻高亮并转圈，不用等接口返回。
  final String? pendingSessionId;

  /// 删除请求还在飞：条目变淡并显示转圈，覆盖住这段等待。
  final Set<String> deletingSessionIds;

  /// 删除已完成、正在播退场动画的条目。
  final Set<String> exitingSessionIds;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final items = _withActivePlaceholder();

    return SizedBox(
      width: 268,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FanxSpace.lg,
              FanxSpace.md,
              FanxSpace.sm,
              FanxSpace.md,
            ),
            child: Row(
              children: [
                Text('会话', style: context.texts.titleSmall),
                const SizedBox(width: FanxSpace.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: t.surfaceRaised,
                    borderRadius: BorderRadius.circular(FanxRadius.xs),
                    border: Border.all(color: t.border),
                  ),
                  child: Text(
                    '${items.length}'.padLeft(2, '0'),
                    style: context.mono(size: 10, color: t.textMuted),
                  ),
                ),
                const Spacer(),
                _BarButton(
                  tooltip: '刷新会话',
                  icon: Icons.refresh,
                  onTap: () => onRefresh(),
                ),
                const SizedBox(width: 2),
                _BarButton(
                  tooltip: '新建会话',
                  icon: Icons.add,
                  emphasized: true,
                  onTap: busy ? null : () => onNew(),
                ),
              ],
            ),
          ),
          const HairLine(),
          Expanded(
            child: loading && items.isEmpty
                ? _LoadingList()
                : items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(FanxSpace.lg),
                    child: EmptyState(
                      title: '还没有会话',
                      hint: '点右上角 + 新建一个，或者直接在右侧开始对话。',
                    ),
                  )
                : _SessionList(
                    items: items,
                    activeSessionId: activeSessionId,
                    runningSessionId: runningSessionId,
                    pendingSessionId: pendingSessionId,
                    deletingSessionIds: deletingSessionIds,
                    exitingSessionIds: exitingSessionIds,
                    busy: busy,
                    onPreview: onPreview,
                    onDelete: onDelete,
                  ),
          ),
        ],
      ),
    );
  }

  /// 刚新建、还没落盘的会话不会出现在历史列表里，这里补一条占位，避免"当前会话找不到"。
  List<AgentSession> _withActivePlaceholder() {
    final active = activeSessionId;
    if (active == null) return sessions;
    if (sessions.any((item) => item.id == active)) return sessions;
    return [
      AgentSession(
        id: active,
        name: '',
        preview: '',
        modified: DateTime.now(),
        messageCount: 0,
        active: true,
      ),
      ...sessions,
    ];
  }
}

class _LoadingList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(FanxSpace.sm + 2),
      itemCount: 5,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SkeletonBox(
          height: 44,
          width: double.infinity,
          delay: Duration(milliseconds: index * 90),
        ),
      ),
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({
    required this.items,
    required this.activeSessionId,
    required this.runningSessionId,
    required this.pendingSessionId,
    required this.deletingSessionIds,
    required this.exitingSessionIds,
    required this.busy,
    required this.onPreview,
    required this.onDelete,
  });

  final List<AgentSession> items;
  final String? activeSessionId;
  final String? runningSessionId;
  final String? pendingSessionId;
  final Set<String> deletingSessionIds;
  final Set<String> exitingSessionIds;
  final bool busy;
  final ValueChanged<String> onPreview;
  final Future<void> Function(AgentSession session) onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.sm + 2,
        FanxSpace.sm + 2,
        FanxSpace.sm + 2,
        FanxSpace.md,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final session = items[index];
        return _SessionTileExit(
          exiting: exitingSessionIds.contains(session.id),
          child: _SessionTile(
            session: session,
            index: index + 1,
            selected: session.id == activeSessionId,
            previewing:
                session.id == activeSessionId && session.id != runningSessionId,
            pending: session.id == pendingSessionId,
            deleting: deletingSessionIds.contains(session.id),
            disabled: busy,
            onTap: () => onPreview(session.id),
            onDelete: () => onDelete(session),
          ),
        );
      },
    );
  }
}

/// 删除完成后的退场：淡出 + 轻微左移 + 高度收起，下方条目跟着平滑上移。
/// 用隐式补间而不是 AnimationController，列表重建时不会留下未释放的控制器。
class _SessionTileExit extends StatelessWidget {
  const _SessionTileExit({required this.exiting, required this.child});

  final bool exiting;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: exiting ? 1 : 0),
      duration: exiting ? kSessionExitDuration : Duration.zero,
      curve: FanxMotion.out,
      child: child,
      builder: (context, value, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1 - value,
          child: Opacity(
            opacity: 1 - value,
            child: Transform.translate(
              offset: Offset(-18 * value, 0),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatefulWidget {
  const _SessionTile({
    required this.session,
    required this.index,
    required this.selected,
    required this.previewing,
    required this.pending,
    required this.deleting,
    required this.disabled,
    required this.onTap,
    required this.onDelete,
  });

  final AgentSession session;
  final int index;
  final bool selected;
  final bool previewing;
  final bool pending;
  final bool deleting;
  final bool disabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final session = widget.session;
    // 正在读预览的项按选中态渲染，用户点下去就能看到变化。
    final active = widget.selected || widget.pending;
    final disabled = widget.disabled || widget.deleting;

    return AnimatedOpacity(
      opacity: widget.deleting ? 0.55 : 1,
      duration: FanxMotion.fast,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: disabled ? null : widget.onTap,
          child: AnimatedContainer(
            duration: FanxMotion.fast,
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: active
                  ? t.accentWash
                  : (_hovering ? t.surfaceRaised : Colors.transparent),
              borderRadius: BorderRadius.circular(FanxRadius.sm),
              border: Border.all(
                color: active
                    ? t.accent.withValues(alpha: 0.34)
                    : (_hovering ? t.border : Colors.transparent),
              ),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 选中态左侧的琥珀竖条：仪表盘式的"当前通道"标记。
                  AnimatedContainer(
                    duration: FanxMotion.fast,
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    color: active ? t.accent : Colors.transparent,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FanxSpace.sm + 2,
                        FanxSpace.sm,
                        2,
                        FanxSpace.sm,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (active) ...[
                                MetaTag(
                                  '${widget.index}'.padLeft(2, '0'),
                                  color: t.accent,
                                  size: 9,
                                  tracking: 1.2,
                                ),
                                const SizedBox(width: FanxSpace.sm),
                              ],
                              Expanded(
                                child: Text(
                                  session.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.bodyMedium?.copyWith(
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: t.text,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.deleting
                                      ? '删除中…'
                                      : widget.previewing
                                      ? '预览 · ${_subtitle(session)}'
                                      : _subtitle(session),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.mono(
                                    size: 10.5,
                                    color: active ? t.textMuted : t.textFaint,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.deleting)
                    Padding(
                      padding: const EdgeInsets.only(right: FanxSpace.sm + 2),
                      child: FanxSpinner(size: 12, color: t.danger),
                    )
                  else if (widget.pending)
                    Padding(
                      padding: const EdgeInsets.only(right: FanxSpace.sm + 2),
                      child: FanxSpinner(size: 12, color: t.accent),
                    )
                  else if (_hovering && !disabled)
                    Padding(
                      padding: const EdgeInsets.only(right: FanxSpace.xs),
                      child: _BarButton(
                        tooltip: '删除会话',
                        icon: Icons.close,
                        onTap: widget.onDelete,
                        dense: true,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _subtitle(AgentSession session) {
    final modified = session.modified;
    final clock = modified == null
        ? ''
        : '${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}';
    final count = session.messageCount > 0
        ? '${session.messageCount} 条'
        : '空会话';
    return clock.isEmpty ? count : '$count · $clock';
  }
}

/// 侧栏里的小方按钮。悬停变实底，点击有 100ms 的缩放反馈。
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    this.onTap,
    this.emphasized = false,
    this.dense = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool emphasized;
  final bool dense;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = widget.dense ? 24.0 : 26.0;
    final disabled = widget.onTap == null;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: FanxMotion.fast,
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.emphasized
                  ? (_hover ? t.accent : t.surfaceRaised)
                  : (_hover ? t.surfaceRaised : Colors.transparent),
              borderRadius: BorderRadius.circular(FanxRadius.xs),
              border: Border.all(
                color: widget.emphasized && _hover
                    ? t.accent
                    : (_hover ? t.borderStrong : t.border),
              ),
            ),
            child: Icon(
              widget.icon,
              size: widget.dense ? 13 : 14,
              color: widget.emphasized && _hover
                  ? t.onAccent
                  : (disabled ? t.textFaint : (_hover ? t.text : t.textMuted)),
            ),
          ),
        ),
      ),
    );
  }
}
