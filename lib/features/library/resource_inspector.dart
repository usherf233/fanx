import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';

/// 检视面板：把一条资源彻底摊开——内容、结构、磁盘读数、真实加载状态。
///
/// 同一套内容既放在右栏，也放进窄窗口下的弹窗，所以不自己带外边框。
class ResourceInspector extends StatelessWidget {
  const ResourceInspector({
    super.key,
    required this.detail,
    required this.loading,
    required this.error,
    required this.fallback,
    required this.pending,
    required this.onToggle,
    required this.onDelete,
    this.onClose,
  });

  final ResourceDetail? detail;
  final bool loading;
  final String? error;

  /// 详情还没到手时先用列表里的条目撑住骨架，避免面板忽然空掉。
  final ResourceItem fallback;
  final bool pending;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback? onClose;

  ResourceItem get _item => detail?.item ?? fallback;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final item = _item;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FanxSpace.xl,
            FanxSpace.lg,
            FanxSpace.md,
            FanxSpace.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MetaTag(
                    '${item.kind.toUpperCase()} / INSPECTOR',
                    size: 8.5,
                    tracking: 1.6,
                    color: t.accent,
                  ),
                  const Spacer(),
                  if (onClose != null)
                    IconButton(
                      onPressed: onClose,
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: 15),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(26, 26),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: FanxSpace.sm),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.cnDisplay(size: 19, height: 1.35),
              ),
              const SizedBox(height: FanxSpace.xs + 2),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.relPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.mono(size: 10.5, color: t.textFaint),
                    ),
                  ),
                  const SizedBox(width: FanxSpace.xs),
                  _TinyAction(
                    tooltip: '复制相对路径',
                    icon: Icons.copy_all_outlined,
                    onTap: () => _copy(context, item.relPath),
                  ),
                ],
              ),
              const SizedBox(height: FanxSpace.md),
              Row(
                children: [
                  SizedBox(
                    height: 26,
                    child: Transform.scale(
                      scale: 0.66,
                      child: Switch(
                        value: item.enabled,
                        onChanged: pending ? null : onToggle,
                      ),
                    ),
                  ),
                  const SizedBox(width: FanxSpace.xs),
                  Text(
                    item.enabled ? '已启用' : '已停用',
                    style: context.texts.bodySmall?.copyWith(
                      fontSize: 12,
                      color: item.enabled ? t.text : t.textMuted,
                    ),
                  ),
                  if (pending) ...[
                    const SizedBox(width: FanxSpace.sm),
                    const FanxSpinner(size: 14),
                  ],
                  const Spacer(),
                  _TinyAction(
                    tooltip: '删除（不可恢复）',
                    icon: Icons.delete_outline,
                    danger: true,
                    onTap: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
        HairLine(color: t.border),
        Expanded(
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(FanxSpace.xl),
                  child: _InspectorSkeleton(),
                )
              : error != null
              ? Padding(
                  padding: const EdgeInsets.all(FanxSpace.lg),
                  child: InlineNotice(message: error!),
                )
              : detail == null
              ? const Padding(
                  padding: EdgeInsets.all(FanxSpace.xl),
                  child: _InspectorSkeleton(),
                )
              : _InspectorBody(item: item, detail: detail!),
        ),
      ],
    );
  }

  static Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 2)),
    );
  }
}

class _InspectorBody extends StatelessWidget {
  const _InspectorBody({required this.item, required this.detail});

  final ResourceItem item;
  final ResourceDetail detail;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final frontmatter = Map<String, String>.from(detail.frontmatter)
      ..remove('name')
      ..remove('description');

    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          FanxSpace.xl,
          FanxSpace.lg,
          FanxSpace.xl,
          FanxSpace.xl,
        ),
        children: [
          _LoadBanner(item: item),
          if (item.description.isNotEmpty) ...[
            const SizedBox(height: FanxSpace.lg),
            Text(
              item.description,
              style: context.texts.bodySmall?.copyWith(
                color: t.text,
                height: 1.75,
                fontSize: 12.5,
              ),
            ),
          ],
          if (item.issues.isNotEmpty) ...[
            const SizedBox(height: FanxSpace.lg),
            Container(
              padding: const EdgeInsets.fromLTRB(
                FanxSpace.md,
                FanxSpace.sm + 2,
                FanxSpace.md,
                FanxSpace.sm + 2,
              ),
              decoration: BoxDecoration(
                color: t.danger.withValues(alpha: 0.07),
                border: Border(left: BorderSide(color: t.danger, width: 2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MetaTag('PI 会报错', size: 8.5, tracking: 1.4, color: t.danger),
                  const SizedBox(height: FanxSpace.xs + 2),
                  for (final issue in item.issues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '· $issue',
                        style: context.texts.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: t.text,
                          height: 1.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: FanxSpace.xl),
          _SectionTitle(label: '读 数 / METRICS'),
          const SizedBox(height: FanxSpace.sm),
          _MetaRow(label: '类型', value: item.kindLabel),
          _MetaRow(label: '体积', value: item.sizeLabel),
          _MetaRow(label: '文件', value: '${item.files}'),
          _MetaRow(
            label: '修改',
            value: item.modified == null ? '—' : _formatTime(item.modified!),
          ),
          _MetaRow(
            label: '入口',
            value: detail.entryFile.isEmpty ? '—' : detail.entryFile,
          ),
          if (item.declaredName != null && item.declaredName!.isNotEmpty)
            _MetaRow(
              label: '声明名',
              value: item.declaredName!,
              warn: item.nameMismatch,
            ),
          _MetaRow(label: '绝对路径', value: item.path, monoSmall: true),
          if (frontmatter.isNotEmpty) ...[
            const SizedBox(height: FanxSpace.lg),
            _SectionTitle(label: 'FRONTMATTER'),
            const SizedBox(height: FanxSpace.sm),
            Wrap(
              spacing: FanxSpace.xs + 2,
              runSpacing: FanxSpace.xs + 2,
              children: [
                for (final entry in frontmatter.entries)
                  _KeyChip(label: entry.key, value: entry.value),
              ],
            ),
          ],
          if (detail.tools.isNotEmpty || detail.commands.isNotEmpty) ...[
            const SizedBox(height: FanxSpace.lg),
            _SectionTitle(label: '注册的能力 / REGISTRY'),
            const SizedBox(height: FanxSpace.sm),
            if (detail.tools.isNotEmpty) ...[
              Text('工具', style: context.monoLabel(size: 9, tracking: 1.4)),
              const SizedBox(height: FanxSpace.xs),
              Wrap(
                spacing: FanxSpace.xs + 2,
                runSpacing: FanxSpace.xs + 2,
                children: [
                  for (final tool in detail.tools)
                    _PlainChip(text: tool, accent: true),
                ],
              ),
              const SizedBox(height: FanxSpace.sm),
            ],
            if (detail.commands.isNotEmpty) ...[
              Text('命令', style: context.monoLabel(size: 9, tracking: 1.4)),
              const SizedBox(height: FanxSpace.xs),
              Wrap(
                spacing: FanxSpace.xs + 2,
                runSpacing: FanxSpace.xs + 2,
                children: [
                  for (final command in detail.commands)
                    _PlainChip(text: '/$command'),
                ],
              ),
            ],
          ],
          const SizedBox(height: FanxSpace.xl),
          _SectionTitle(
            label: '文件结构 / FILES',
            trailing: '${detail.entries.length}',
          ),
          const SizedBox(height: FanxSpace.sm),
          _FileTree(entries: detail.entries),
          const SizedBox(height: FanxSpace.xl),
          _SectionTitle(
            label: detail.entryFile.toUpperCase(),
            trailing: '${detail.content.length} 字符',
          ),
          const SizedBox(height: FanxSpace.sm),
          _CodePanel(filename: detail.entryFile, content: detail.content),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

/// 真实加载状态：这是整个面板最重要的一行字。
class _LoadBanner extends StatelessWidget {
  const _LoadBanner({required this.item});

  final ResourceItem item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final (color, title, hint) = switch ((item.enabled, item.loaded)) {
      (false, _) => (t.textFaint, '已停用', '文件在 *.disabled/ 里，pi 完全看不到它。'),
      (true, true) => (t.success, 'pi 已加载', '下次对话时它就在系统提示的可调用清单里。'),
      (true, false) => (
        t.warning,
        '已启用，但 pi 没加载',
        '检查上面的告警；缺 description 的 SKILL.md 会被静默跳过。',
      ),
      (true, null) => (t.accent, '已启用', '该 Agent 会话未运行，重新对话后会重新扫描。'),
    };

    return Container(
      padding: const EdgeInsets.all(FanxSpace.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: t.isDark ? 0.10 : 0.07),
        borderRadius: BorderRadius.circular(FanxRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: StatusDot(color: color, size: 6),
          ),
          const SizedBox(width: FanxSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.texts.titleSmall?.copyWith(
                    fontSize: 12,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: context.texts.bodySmall?.copyWith(
                    fontSize: 11,
                    height: 1.5,
                    color: t.textMuted,
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Row(
      children: [
        Text(label, style: context.monoLabel(size: 8.5, tracking: 1.7)),
        const SizedBox(width: FanxSpace.sm),
        Expanded(child: Container(height: 1, color: t.border)),
        if (trailing != null) ...[
          const SizedBox(width: FanxSpace.sm),
          Text(trailing!, style: context.mono(size: 9.5, color: t.textFaint)),
        ],
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.label,
    required this.value,
    this.warn = false,
    this.monoSmall = false,
  });

  final String label;
  final String value;
  final bool warn;
  final bool monoSmall;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: context.texts.bodySmall?.copyWith(
                fontSize: 11,
                color: t.textFaint,
                height: 1.5,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: context.mono(
                size: monoSmall ? 9.5 : 11,
                color: warn ? t.warning : t.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FanxSpace.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: t.surfaceSunken,
        borderRadius: BorderRadius.circular(FanxRadius.xs),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: context.mono(size: 9.5, color: t.textFaint)),
          const SizedBox(width: FanxSpace.xs + 1),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.mono(size: 10, color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlainChip extends StatelessWidget {
  const _PlainChip({required this.text, this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FanxSpace.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: accent ? t.accentWash : t.surfaceSunken,
        borderRadius: BorderRadius.circular(FanxRadius.xs),
        border: Border.all(
          color: accent ? t.accent.withValues(alpha: 0.4) : t.border,
        ),
      ),
      child: Text(
        text,
        style: context.mono(size: 10, color: accent ? t.accent : t.textMuted),
      ),
    );
  }
}

class _FileTree extends StatelessWidget {
  const _FileTree({required this.entries});

  final List<ResourceFileEntry> entries;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (entries.isEmpty) {
      return Text(
        '读不到目录内容',
        style: context.texts.bodySmall?.copyWith(fontSize: 11),
      );
    }

    final shown = entries.take(40).toList();
    final rest = entries.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in shown)
          Padding(
            padding: EdgeInsets.only(left: entry.depth * 12, bottom: 3),
            child: Row(
              children: [
                Icon(
                  entry.dir
                      ? Icons.folder_outlined
                      : Icons.description_outlined,
                  size: 11,
                  color: entry.dir
                      ? t.accent.withValues(alpha: 0.7)
                      : t.textFaint,
                ),
                const SizedBox(width: FanxSpace.xs + 1),
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.mono(
                      size: 10.5,
                      color: entry.dir ? t.textMuted : t.text,
                    ),
                  ),
                ),
                if (!entry.dir)
                  Text(
                    formatBytes(entry.bytes),
                    style: context.mono(size: 9, color: t.textFaint),
                  ),
              ],
            ),
          ),
        if (rest > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '还有 $rest 项…',
              style: context.mono(size: 9.5, color: t.textFaint),
            ),
          ),
      ],
    );
  }
}

/// 内容预览：默认裁到 220px，长文件不把整页撑爆。
class _CodePanel extends StatefulWidget {
  const _CodePanel({required this.filename, required this.content});

  final String filename;
  final String content;

  @override
  State<_CodePanel> createState() => _CodePanelState();
}

class _CodePanelState extends State<_CodePanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = widget.content.isEmpty ? '（空文件）' : widget.content;
    final long = widget.content.length > 1400;

    final body = SelectableText(
      text,
      style: context
          .mono(size: 10.5, color: t.text, weight: FontWeight.w400)
          .copyWith(height: 1.75),
    );

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
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: FanxSpace.sm),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Text(
                  widget.filename,
                  style: context.mono(size: 9, color: t.textFaint),
                ),
                const Spacer(),
                _TinyAction(
                  tooltip: '复制内容',
                  icon: Icons.content_copy,
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: widget.content),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('内容已复制'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          if (!_expanded && long)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(FanxSpace.md),
                    child: body,
                  ),
                ),
              ),
            )
          else
            Padding(padding: const EdgeInsets.all(FanxSpace.md), child: body),
          if (long) ...[
            HairLine(color: t.border),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _expanded ? '收起' : '展开全文',
                      style: context.mono(size: 9.5, color: t.accent),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 13,
                      color: t.accent,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TinyAction extends StatefulWidget {
  const _TinyAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_TinyAction> createState() => _TinyActionState();
}

class _TinyActionState extends State<_TinyAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = widget.danger ? t.danger : t.textMuted;

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
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? (widget.danger ? t.danger : t.surfaceRaised).withValues(
                      alpha: 0.12,
                    )
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(FanxRadius.xs),
            ),
            child: Icon(
              widget.icon,
              size: 13,
              color: _hover ? base : base.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

class _InspectorSkeleton extends StatelessWidget {
  const _InspectorSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonBox(height: 54),
        const SizedBox(height: FanxSpace.lg),
        const SkeletonBox(
          height: 10,
          width: 90,
          delay: Duration(milliseconds: 80),
        ),
        const SizedBox(height: FanxSpace.sm),
        for (var index = 0; index < 5; index++) ...[
          SkeletonBox(
            height: 8,
            width: 200.0 - index * 12,
            delay: Duration(milliseconds: 120 + index * 60),
          ),
          const SizedBox(height: FanxSpace.sm),
        ],
        const SizedBox(height: FanxSpace.lg),
        const SkeletonBox(height: 160, delay: Duration(milliseconds: 400)),
      ],
    );
  }
}
