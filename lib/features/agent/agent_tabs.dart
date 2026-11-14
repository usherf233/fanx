import 'package:flutter/material.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';

/// 配置页：系统提示词、凭据状态、路径、settings.json 预览。
class ConfigTab extends StatefulWidget {
  const ConfigTab({super.key, required this.agent});

  final Agent agent;

  @override
  State<ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends State<ConfigTab> {
  final _prompt = TextEditingController();
  AgentConfig? _config;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final config = await appState.client.getConfig(widget.agent.id);
      if (!mounted) return;
      setState(() {
        _config = config;
        _prompt.text = config.systemPrompt;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (exception) {
      if (mounted) {
        setState(() {
          _error = exception.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _notice = null;
      _error = null;
    });
    try {
      await appState.client.saveSystemPrompt(widget.agent.id, _prompt.text);
      if (mounted) setState(() => _notice = '已写入 AGENTS.md，新会话生效');
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingBlock(label: 'reading config');
    final config = _config;
    if (config == null) return Center(child: Text(_error ?? '配置读取失败'));

    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.xl,
        FanxSpace.lg,
        FanxSpace.xl,
        FanxSpace.xxl,
      ),
      children: [
        const PageHeader(
          index: '03',
          kicker: 'Config',
          title: '配置',
          subtitle: '提示词决定这个 Agent 的人格，路径决定它能看到什么。改动只影响它自己。',
        ),
        _SectionCard(
          title: '系统提示词',
          subtitle: '写入 AGENTS.md，作为这个 Agent 的长期人格。只影响它自己。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _prompt,
                minLines: 10,
                maxLines: 22,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: FanxFonts.mono,
                  fontFamilyFallback: FanxFonts.monoFallback,
                  height: 1.6,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '# 角色\n\n你是一个……',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? FanxSpinner(size: 14, color: context.tokens.onAccent)
                        : const Icon(Icons.save_outlined, size: 16),
                    label: const Text('保存'),
                  ),
                  const SizedBox(width: 12),
                  if (_notice != null)
                    Text(
                      _notice!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  if (_error != null)
                    Expanded(
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: '模型与凭据',
          subtitle: '凭据存在 ${config.configDir}\\auth.json，不会展示在界面里。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    config.authConfigured
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: config.authConfigured
                        ? const Color(0xFF16A34A)
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    config.authConfigured
                        ? '已配置：${config.authProviders.join('、')}'
                        : '未在 auth.json 里配置凭据',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '模型端点在「模型」页配置，密钥写在该 Agent 自己的 models.json 里，不与其它 Agent 共享。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: '路径',
          subtitle: '配置与工作目录分离，是这个 Agent 与其它 Agent 互不干扰的基础。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PathRow(label: '配置目录', value: config.configDir),
              const SizedBox(height: 8),
              _PathRow(label: '工作目录', value: config.cwd),
            ],
          ),
        ),
        if (config.settingsJson.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: 'settings.json',
            subtitle: '只读预览，改动请直接编辑文件。',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                config.settingsJson,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: FanxFonts.mono,
                  fontFamilyFallback: FanxFonts.monoFallback,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: FanxFonts.mono,
              fontFamilyFallback: FanxFonts.monoFallback,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SectionCard(title: title, subtitle: subtitle, child: child);
  }
}
