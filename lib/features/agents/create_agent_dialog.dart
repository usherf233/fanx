import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';

/// 新建 Agent：身份（名称 / ID / 描述）+ 环境与人格（工作目录 / 系统提示词）。
///
/// 界面上把"后端会自动做什么"全部显式化：id 会怎么生成、配置目录落在哪、
/// 重名怎么处理。这些原本只有读了后端代码才知道，是表单最大的黑箱。
class CreateAgentDialog extends StatefulWidget {
  const CreateAgentDialog({super.key, this.cloneFrom});

  final String? cloneFrom;

  static Future<Agent?> show(BuildContext context, {String? cloneFrom}) {
    return showDialog<Agent>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CreateAgentDialog(cloneFrom: cloneFrom),
    );
  }

  @override
  State<CreateAgentDialog> createState() => _CreateAgentDialogState();
}

class _CreateAgentDialogState extends State<CreateAgentDialog> {
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _description = TextEditingController();
  final _cwd = TextEditingController();
  final _prompt = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 名称决定推导出的 id，id 决定底部路径预览，两者变了都要重算。
    _name.addListener(_rebuild);
    _id.addListener(_rebuild);
  }

  @override
  void dispose() {
    _name.removeListener(_rebuild);
    _id.removeListener(_rebuild);
    _name.dispose();
    _id.dispose();
    _description.dispose();
    _cwd.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------
  // 身份推导：与 daemon 的 slugify / uniqueAgentId 保持同一套规则，
  // 让界面显示的 id 就是最终落盘的目录名。
  // ---------------------------------------------------------------------

  static String _slugify(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.length > 48 ? slug.substring(0, 48) : slug;
  }

  String get _autoId {
    final base = _slugify(_name.text);
    final root = base.isEmpty ? 'agent' : base;
    final taken = {for (final agent in appState.agents) agent.id};
    if (!taken.contains(root)) return root;
    for (var index = 2; index < 1000; index++) {
      final candidate = '$root-$index';
      if (!taken.contains(candidate)) return candidate;
    }
    return '$root-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  }

  /// 本次实际会用的 id：手填优先，否则用推导值。
  String get _effectiveId {
    final typed = _id.text.trim();
    return typed.isEmpty ? _autoId : typed;
  }

  bool get _nameIsAsciiSafe => _slugify(_name.text).isNotEmpty;

  String? get _idProblem {
    final typed = _id.text.trim();
    if (typed.isEmpty) return null;
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(typed)) {
      return '只能用小写字母、数字和连字符，且不能以连字符开头';
    }
    if (appState.agents.any((agent) => agent.id == typed)) {
      return '这个 id 已被占用';
    }
    return null;
  }

  /// 配置目录的父级。从已有 Agent 反推，拿不到就退回约定路径。
  String? get _agentsRoot {
    final agents = appState.agents;
    if (agents.isEmpty) return null;
    final dir = agents.first.configDir;
    final cut = dir.lastIndexOf(RegExp(r'[\\/]'));
    return cut > 0 ? dir.substring(0, cut) : null;
  }

  String get _configDirPreview {
    final root = _agentsRoot ?? '~/.pi-manager/agents';
    return '$root/$_effectiveId';
  }

  // ---------------------------------------------------------------------

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_idProblem != null) {
      setState(() => _error = _idProblem);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final agent = await appState.create(
        name: _name.text.trim(),
        id: _id.text.trim().isEmpty ? null : _id.text.trim(),
        description: _description.text.trim(),
        cwd: _cwd.text.trim().isEmpty ? null : _cwd.text.trim(),
        systemPrompt: _prompt.text.trim().isEmpty ? null : _prompt.text.trim(),
        cloneFrom: widget.cloneFrom,
      );
      if (mounted) Navigator.of(context).pop(agent);
    } on ApiException catch (exception) {
      if (mounted) {
        setState(() {
          _error = exception.message;
          _submitting = false;
        });
      }
    }
  }

  void _useTemplate(String text) {
    _prompt.text = text;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final viewport = MediaQuery.sizeOf(context);
    final wide = viewport.width >= 860;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (!_submitting) _submit();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_submitting) Navigator.of(context).pop();
        },
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(FanxSpace.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 800,
            maxHeight: viewport.height - FanxSpace.huge,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(FanxRadius.lg),
              border: Border.all(color: t.borderStrong),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  cloneFrom: widget.cloneFrom,
                  onClose: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
                const HairLine(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      FanxSpace.xl,
                      FanxSpace.lg,
                      FanxSpace.xl,
                      FanxSpace.lg,
                    ),
                    child: Form(
                      key: _formKey,
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: _identityColumn(context),
                                ),
                                const SizedBox(width: FanxSpace.xl),
                                Container(width: 1, color: t.border),
                                const SizedBox(width: FanxSpace.xl),
                                Expanded(
                                  flex: 6,
                                  child: _contextColumn(context),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _identityColumn(context),
                                const SizedBox(height: FanxSpace.xl),
                                _contextColumn(context),
                              ],
                            ),
                    ),
                  ),
                ),
                const HairLine(),
                _Footer(
                  configDir: _configDirPreview,
                  submitting: _submitting,
                  onCancel: () => Navigator.of(context).pop(),
                  onCreate: _submit,
                  error: _error,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 左栏：身份
  // ---------------------------------------------------------------------

  Widget _identityColumn(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel(index: '01', title: '身份', hint: '界面上怎么称呼它'),
        const SizedBox(height: FanxSpace.lg),
        _Field(
          controller: _name,
          label: '名称',
          hint: '例如：编码 Agent',
          autofocus: true,
          trailing: MetaTag('必填', color: t.accent, size: 9, tracking: 1.2),
          validator: (value) =>
              (value == null || value.trim().isEmpty) ? '名称不能为空' : null,
        ),
        const SizedBox(height: FanxSpace.lg),
        _Field(
          controller: _id,
          label: 'ID',
          hint: _effectiveId,
          mono: true,
          // 灰字是"将会变成这个"，右侧 AUTO 说明它是推导出来的，不是用户填的。
          suffix: _id.text.trim().isEmpty && _idProblem == null
              ? MetaTag(
                  'AUTO',
                  color: context.tokens.accent,
                  size: 9,
                  tracking: 1.2,
                )
              : null,
          errorText: _idProblem,
          helper: _idHelper(context),
        ),
        const SizedBox(height: FanxSpace.lg),
        _Field(
          controller: _description,
          label: '描述',
          hint: '这个 Agent 负责什么',
          minLines: 3,
          maxLines: 4,
          alignLabelWithHint: true,
        ),
        const SizedBox(height: FanxSpace.lg),
        const _NextStepTip(),
      ],
    );
  }

  /// ID 下方的实时说明：讲清楚"不填会发生什么"。
  String? _idHelper(BuildContext context) {
    if (_id.text.trim().isNotEmpty) {
      return _idProblem == null ? '可用，将作为目录名与 URL 路径' : null;
    }
    if (!_nameIsAsciiSafe && _name.text.trim().isNotEmpty) {
      return '名称里没有 ASCII 字符，id 将回退为 $_autoId —— 建议手填一个';
    }
    return '留空则自动生成：$_autoId';
  }

  // ---------------------------------------------------------------------
  // 右栏：环境与人格
  // ---------------------------------------------------------------------

  Widget _contextColumn(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel(index: '02', title: '环境与人格', hint: '它在哪里干活、以什么身份'),
        const SizedBox(height: FanxSpace.lg),
        _Field(
          controller: _cwd,
          label: '工作目录',
          hint: _agentsRoot == null
              ? '留空则使用配置目录下的 workspace/'
              : '留空则用 <配置目录>/workspace',
          mono: true,
          helper: '它读写文件的范围，与其它 Agent 不共享',
        ),
        const SizedBox(height: FanxSpace.lg),
        _Field(
          controller: _prompt,
          label: '系统提示词',
          hint: '# 角色\n\n你是一个……',
          mono: true,
          minLines: 6,
          maxLines: 10,
          alignLabelWithHint: true,
          helper: '写入 AGENTS.md，只影响它自己 · Ctrl + Enter 创建',
        ),
        const SizedBox(height: FanxSpace.md),
        _TemplateRow(onPick: _useTemplate),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.onClose, this.cloneFrom});

  final VoidCallback? onClose;
  final String? cloneFrom;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final cloning = cloneFrom != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xl,
        FanxSpace.lg,
        FanxSpace.md,
        FanxSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 6, height: 6, color: t.accent),
                    const SizedBox(width: FanxSpace.sm),
                    MetaTag(
                      cloning ? 'CLONE AGENT' : 'NEW AGENT',
                      color: t.accent,
                      size: 9.5,
                      tracking: 2,
                    ),
                  ],
                ),
                const SizedBox(height: FanxSpace.sm + 2),
                Text(
                  cloning ? '克隆 Agent' : '新建 Agent',
                  style: context.cnDisplay(size: 23, height: 1.25),
                ),
                const SizedBox(height: FanxSpace.xs + 2),
                Text(
                  cloning
                      ? '复制 $cloneFrom 的配置目录，得到一套完全独立的副本。'
                      : '一套独立的配置目录与工作目录，技能、凭据、会话都不与其它 Agent 共享。',
                  style: context.texts.bodySmall?.copyWith(color: t.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭（Esc）',
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.index,
    required this.title,
    required this.hint,
  });

  final String index;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Row(
      children: [
        Text(
          index,
          style: context.monoLabel(color: t.accent, size: 10, tracking: 2),
        ),
        const SizedBox(width: FanxSpace.sm),
        Container(width: 14, height: 1, color: t.borderStrong),
        const SizedBox(width: FanxSpace.sm),
        Text(title, style: context.texts.titleSmall),
        const SizedBox(width: FanxSpace.sm),
        Flexible(
          child: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall?.copyWith(
              color: t.textFaint,
              fontSize: 11.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// 左栏底部的去向说明：表单填完之后去哪继续配置。
class _NextStepTip extends StatelessWidget {
  const _NextStepTip();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: const EdgeInsets.all(FanxSpace.md),
      decoration: BoxDecoration(
        color: t.surfaceSunken,
        borderRadius: BorderRadius.circular(FanxRadius.sm),
        border: Border.all(color: t.border),
      ),
      // 拆成三行固定短句：中文没有断词规则，长句必然被硬拆，
      // 与其让"资源"被劈成两行，不如按页签一行一条。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetaTag('创建之后', size: 9, tracking: 1.4),
          const SizedBox(height: FanxSpace.sm),
          for (final row in const [
            ('模型', '接端点、切模型'),
            ('配置', '改提示词与路径'),
            ('资源', '增删技能'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      row.$1,
                      style: context.texts.bodySmall?.copyWith(
                        color: t.text,
                        fontSize: 11.5,
                        height: 1.5,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: context.texts.bodySmall?.copyWith(
                        color: t.textMuted,
                        fontSize: 11.5,
                        height: 1.5,
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

/// 提示词起点。空白起步最容易让人卡住，这里给三个具体选择。
class _TemplateRow extends StatelessWidget {
  const _TemplateRow({required this.onPick});

  final ValueChanged<String> onPick;

  static const _templates = <String, String>{
    '空白': '',
    '编码助手':
        '# 角色\n\n你是一个严谨的工程师。改动前先读现有代码，遵循既有结构与风格。\n'
        '交付前用 analyze / test 验证，不要只描述方案。\n',
    '文档助手':
        '# 角色\n\n你负责把零散材料整理成结构清晰的文档。结论先行，'
        '论据克制，避免形容词堆砌。\n',
  };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MetaTag('提示词起点', size: 9, tracking: 1.4),
        const SizedBox(height: FanxSpace.sm),
        Wrap(
          spacing: FanxSpace.sm,
          runSpacing: FanxSpace.sm,
          children: [
            for (final entry in _templates.entries)
              _TemplateChip(
                label: entry.key,
                enabled: entry.value.isNotEmpty,
                onTap: entry.value.isEmpty
                    ? () => onPick('')
                    : () => onPick(entry.value),
                border: t.border,
              ),
          ],
        ),
      ],
    );
  }
}

class _TemplateChip extends StatefulWidget {
  const _TemplateChip({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.border,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color border;

  @override
  State<_TemplateChip> createState() => _TemplateChipState();
}

class _TemplateChipState extends State<_TemplateChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: FanxMotion.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: FanxSpace.md,
            vertical: FanxSpace.xs + 3,
          ),
          decoration: BoxDecoration(
            color: _hover ? t.accentWash : t.surfaceSunken,
            borderRadius: BorderRadius.circular(FanxRadius.sm),
            border: Border.all(color: _hover ? t.accent : widget.border),
          ),
          child: Text(
            widget.label,
            style: context.texts.bodySmall?.copyWith(
              fontSize: 12,
              color: _hover ? t.accent : t.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.configDir,
    required this.submitting,
    required this.onCancel,
    required this.onCreate,
    this.error,
  });

  final String configDir;
  final bool submitting;
  final VoidCallback onCancel;
  final VoidCallback onCreate;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xl,
        FanxSpace.md,
        FanxSpace.xl,
        FanxSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            InlineNotice(message: error!, tone: NoticeTone.danger),
            const SizedBox(height: FanxSpace.md),
          ],
          Row(
            children: [
              // 落盘位置提前给出来，避免创建完才发现目录名不是想要的。
              MetaTag('CONFIG DIR', size: 9, tracking: 1.4),
              const SizedBox(width: FanxSpace.sm),
              Expanded(
                child: Tooltip(
                  message: configDir,
                  child: Text(
                    configDir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.mono(size: 11, color: t.textMuted),
                  ),
                ),
              ),
              const SizedBox(width: FanxSpace.md),
              TextButton(
                onPressed: submitting ? null : onCancel,
                child: const Text('取消'),
              ),
              const SizedBox(width: FanxSpace.sm),
              FilledButton(
                onPressed: submitting ? null : onCreate,
                child: submitting
                    ? FanxSpinner(size: 14, color: context.tokens.onAccent)
                    : const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// 表单字段：标签在上、输入框在下，等宽字体用于路径与 ID。
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.mono = false,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.alignLabelWithHint = false,
    this.validator,
    this.errorText,
    this.trailing,
    this.suffix,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final bool mono;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final bool alignLabelWithHint;
  final String? Function(String?)? validator;
  final String? errorText;
  final Widget? trailing;

  /// 输入框内右侧的小标记，例如 ID 推导出来的 AUTO。
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: context.texts.labelLarge?.copyWith(
                color: t.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: FanxSpace.xs + 2),
        TextFormField(
          controller: controller,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          validator: validator,
          forceErrorText: errorText,
          style: mono
              ? context.mono(size: 12.5, color: t.text)
              : context.texts.bodyMedium,
          decoration: InputDecoration(
            hintText: hint,
            alignLabelWithHint: alignLabelWithHint,
            helperText: errorText == null ? helper : null,
            helperMaxLines: 2,
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}
