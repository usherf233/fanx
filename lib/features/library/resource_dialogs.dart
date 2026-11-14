import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';

/// 导入成功后的结果：新快照 + 刚导入的条目，调用方据此直接选中它。
class ResourceResult {
  const ResourceResult({
    required this.snapshot,
    required this.kind,
    required this.name,
  });

  final ResourceSnapshot snapshot;

  /// skills / extensions / prompts
  final String kind;
  final String name;
}

/// 从本机路径导入：目录→技能，单文件→扩展 / 模板 / 单文件技能。
class ImportResourceDialog extends StatefulWidget {
  const ImportResourceDialog({super.key, required this.agent});

  final Agent agent;

  static Future<ResourceResult?> show(
    BuildContext context, {
    required Agent agent,
  }) {
    return showDialog<ResourceResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => ImportResourceDialog(agent: agent),
    );
  }

  @override
  State<ImportResourceDialog> createState() => _ImportResourceDialogState();
}

class _ImportResourceDialogState extends State<ImportResourceDialog> {
  final _source = TextEditingController();
  final _name = TextEditingController();
  String _type = 'skills';
  bool _overwrite = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _source.dispose();
    _name.dispose();
    super.dispose();
  }

  String get _hint => switch (_type) {
    'skills' => '技能：含 SKILL.md 的目录，或带 frontmatter 的单个 .md',
    'extensions' => '扩展：单个 .ts / .js / .mts / .mjs 文件',
    _ => '模板：单个 .md 文件',
  };

  Future<void> _submit() async {
    final source = _source.text.trim();
    if (source.isEmpty) {
      setState(() => _error = '先填一个本机路径');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await appState.client.importResource(
        widget.agent.id,
        type: _type,
        source: source,
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        overwrite: _overwrite,
      );
      if (!mounted) return;
      final name = _name.text.trim().isEmpty
          ? _basename(source)
          : _name.text.trim();
      Navigator.of(context).pop(
        ResourceResult(snapshot: snapshot, kind: _type, name: _stripExt(name)),
      );
    } on ApiException catch (exception) {
      if (mounted) {
        setState(() {
          _error = exception.message;
          _busy = false;
        });
      }
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? path : parts.last;
  }

  static String _stripExt(String name) =>
      name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      kicker: 'IMPORT / LOCAL PATH',
      title: '导入资源',
      subtitle: '把本机已有的技能或扩展复制进这个 Agent 的目录，不影响原来的那份。',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TypePicker(
            value: _type,
            onChanged: (value) => setState(() => _type = value),
          ),
          const SizedBox(height: FanxSpace.lg),
          TextField(
            controller: _source,
            autofocus: true,
            style: context.mono(size: 12),
            decoration: const InputDecoration(
              labelText: '来源路径',
              hintText: r'C:\skills\pdf-tools 或 .\my-extension.ts',
            ),
          ),
          const SizedBox(height: FanxSpace.sm),
          Text(_hint, style: context.texts.bodySmall?.copyWith(fontSize: 11)),
          const SizedBox(height: FanxSpace.lg),
          TextField(
            controller: _name,
            style: context.mono(size: 12),
            decoration: const InputDecoration(
              labelText: '重命名（可选）',
              hintText: '留空则沿用目录名 / 文件名',
            ),
          ),
          const SizedBox(height: FanxSpace.md),
          _CheckLine(
            value: _overwrite,
            label: '目标已存在时覆盖',
            onChanged: (value) => setState(() => _overwrite = value),
          ),
          if (_error != null) ...[
            const SizedBox(height: FanxSpace.md),
            InlineNotice(message: _error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const FanxSpinner(size: 14, color: Colors.white)
              : const Icon(Icons.file_download_outlined, size: 15),
          label: const Text('导入'),
        ),
      ],
    );
  }
}

/// 新建技能：直接生成符合 Agent Skills 规范的 SKILL.md 骨架。
class CreateSkillDialog extends StatefulWidget {
  const CreateSkillDialog({super.key, required this.agent});

  final Agent agent;

  static Future<ResourceResult?> show(
    BuildContext context, {
    required Agent agent,
  }) {
    return showDialog<ResourceResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => CreateSkillDialog(agent: agent),
    );
  }

  @override
  State<CreateSkillDialog> createState() => _CreateSkillDialogState();
}

class _CreateSkillDialogState extends State<CreateSkillDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  bool _busy = false;
  String? _error;

  static final _nameRe = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  String? get _nameError {
    final value = _name.text.trim();
    if (value.isEmpty) return null;
    if (value.length > 64) return '最多 64 个字符';
    if (!_nameRe.hasMatch(value)) return '只能小写字母、数字、连字符，且不能首尾或连续连字符';
    return null;
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _nameError != null) {
      setState(() => _error = '先给技能一个合法的名字');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await appState.client.createSkill(
        widget.agent.id,
        name: name,
        description: _description.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(ResourceResult(snapshot: snapshot, kind: 'skills', name: name));
    } on ApiException catch (exception) {
      if (mounted) {
        setState(() {
          _error = exception.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return _DialogShell(
      kicker: 'NEW SKILL / SCAFFOLD',
      title: '新建技能',
      subtitle:
          '生成 SKILL.md、references/ 与 scripts/ 骨架。description 决定模型什么时候会用它。',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            style: context.mono(size: 12),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]')),
            ],
            decoration: InputDecoration(
              labelText: '技能名',
              hintText: 'pdf-tools',
              errorText: _nameError,
              helperText: '同时作为目录名，发布后改起来很麻烦，先想好。',
            ),
          ),
          const SizedBox(height: FanxSpace.lg),
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 5,
            maxLength: 1024,
            onChanged: (_) => setState(() {}),
            style: context.texts.bodySmall?.copyWith(
              color: t.text,
              height: 1.6,
            ),
            decoration: const InputDecoration(
              labelText: '描述（description）',
              hintText: '从 PDF 里抽取文字与表格、填写表单。处理 PDF 文档时使用。',
              alignLabelWithHint: true,
            ),
          ),
          if (_error != null) InlineNotice(message: _error!),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const FanxSpinner(size: 14, color: Colors.white)
              : const Icon(Icons.add, size: 15),
          label: const Text('创建'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 对话框外壳
// ---------------------------------------------------------------------------

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.kicker,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.actions,
  });

  final String kicker;
  final String title;
  final String subtitle;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(FanxSpace.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FanxSpace.xl,
                  FanxSpace.lg,
                  FanxSpace.xl,
                  FanxSpace.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MetaTag(kicker, size: 8.5, tracking: 1.7, color: t.accent),
                    const SizedBox(height: FanxSpace.sm),
                    Text(
                      title,
                      style: context.cnDisplay(size: 20, height: 1.3),
                    ),
                    const SizedBox(height: FanxSpace.xs + 2),
                    Text(
                      subtitle,
                      style: context.texts.bodySmall?.copyWith(
                        color: t.textMuted,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              HairLine(color: t.border),
              Padding(padding: const EdgeInsets.all(FanxSpace.xl), child: body),
              HairLine(color: t.border),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FanxSpace.lg,
                  vertical: FanxSpace.md,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var index = 0; index < actions.length; index++) ...[
                      if (index > 0) const SizedBox(width: FanxSpace.sm),
                      actions[index],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypePicker extends StatelessWidget {
  const _TypePicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    const options = [('skills', '技能'), ('extensions', '扩展'), ('prompts', '模板')];

    return Row(
      children: [
        for (final option in options) ...[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onChanged(option.$1),
              child: AnimatedContainer(
                duration: FanxMotion.fast,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: FanxSpace.md),
                decoration: BoxDecoration(
                  color: value == option.$1 ? t.accentWash : Colors.transparent,
                  borderRadius: BorderRadius.circular(FanxRadius.sm),
                  border: Border.all(
                    color: value == option.$1 ? t.accent : t.border,
                  ),
                ),
                child: Center(
                  child: Text(
                    option.$2,
                    style: context.texts.titleSmall?.copyWith(
                      fontSize: 12,
                      color: value == option.$1 ? t.accent : t.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: FanxSpace.sm),
        ],
      ],
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: (next) => onChanged(next ?? false),
              ),
            ),
            const SizedBox(width: FanxSpace.sm),
            Text(
              label,
              style: context.texts.bodySmall?.copyWith(color: t.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
