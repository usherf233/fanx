import 'package:flutter/material.dart';

import '../../core/api/daemon_client.dart';
import '../../core/api/models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/fanx_kit.dart';
import '../../state/app_state.dart';

/// 模型配置：看当前用哪个模型、切模型、接入新的 OpenAI 兼容端点。
class ModelsTab extends StatefulWidget {
  const ModelsTab({super.key, required this.agent, this.onChanged});

  final Agent agent;
  final VoidCallback? onChanged;

  @override
  State<ModelsTab> createState() => _ModelsTabState();
}

class _ModelsTabState extends State<ModelsTab> {
  AgentModels? _models;
  bool _loading = true;
  String? _error;
  String? _notice;
  String? _switchingModel;

  // 接入新端点的表单
  final _providerId = TextEditingController(text: 'local');
  final _endpointName = TextEditingController(text: '本机路由');
  final _baseUrl = TextEditingController(text: 'http://127.0.0.1:3425/v1');
  final _apiKey = TextEditingController();
  final _filter = TextEditingController();

  List<ProbedModel>? _probed;
  final Set<String> _picked = {};
  String? _defaultPick;
  bool _probing = false;
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _load();
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _providerId.dispose();
    _endpointName.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final models = await appState.client.getModels(widget.agent.id);
      if (!mounted) return;
      setState(() {
        _models = models;
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

  Future<void> _select(String provider, String model) async {
    setState(() {
      _switchingModel = model;
      _error = null;
      _notice = null;
    });
    try {
      await appState.client.selectModel(
        widget.agent.id,
        provider: provider,
        model: model,
      );
      await _load();
      if (mounted) setState(() => _notice = '已切换到 $model');
      widget.onChanged?.call();
    } on ApiException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } finally {
      if (mounted) setState(() => _switchingModel = null);
    }
  }

  Future<void> _probe() async {
    final baseUrl = _baseUrl.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _formError = 'baseUrl 不能为空');
      return;
    }
    setState(() {
      _probing = true;
      _formError = null;
      _probed = null;
      _picked.clear();
      _defaultPick = null;
    });
    try {
      final models = await appState.client.probeModels(
        widget.agent.id,
        baseUrl: baseUrl,
        apiKey: _apiKey.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _probed = models;
        // 默认全选：多数场景就是"这个端点上的模型都留着"。
        _picked.addAll(models.map((item) => item.id));
        _defaultPick = models
            .where((item) => item.toolCall)
            .map((item) => item.id)
            .firstOrNull;
        _defaultPick ??= models.isEmpty ? null : models.first.id;
        if (models.isEmpty) _formError = '端点没有返回任何模型';
      });
    } on ApiException catch (exception) {
      if (mounted) setState(() => _formError = exception.message);
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _save() async {
    final providerId = _providerId.text.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(providerId)) {
      setState(() => _formError = 'providerId 只能用小写字母、数字和连字符');
      return;
    }
    if (_picked.isEmpty) {
      setState(() => _formError = '至少选择一个模型');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await appState.client.saveModels(
        widget.agent.id,
        providerId: providerId,
        name: _endpointName.text.trim().isEmpty
            ? providerId
            : _endpointName.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _defaultPick,
        models: _picked.toList(growable: false),
      );
      await _load();
      if (mounted) {
        setState(() {
          _notice = '已写入 models.json，默认模型 ${_defaultPick ?? '（未设置）'}';
          _probed = null;
          _picked.clear();
        });
      }
      widget.onChanged?.call();
    } on ApiException catch (exception) {
      if (mounted) setState(() => _formError = exception.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingBlock(label: 'reading models');
    final models = _models;
    if (models == null) return Center(child: Text(_error ?? '模型配置读取失败'));

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
          index: '02',
          kicker: 'Models',
          title: '模型',
          subtitle: '任何 OpenAI 兼容端点都能接。切换立即生效，配置写在当前 Agent 自己的 models.json 里。',
        ),
        if (_error != null) ...[
          InlineNotice(
            message: _error!,
            onDismiss: () => setState(() => _error = null),
          ),
          const SizedBox(height: FanxSpace.md),
        ],
        if (_notice != null) ...[
          InlineNotice(
            message: _notice!,
            tone: NoticeTone.success,
            onDismiss: () => setState(() => _notice = null),
          ),
          const SizedBox(height: FanxSpace.md),
        ],
        _currentCard(theme, models),
        const SizedBox(height: FanxSpace.md),
        ..._providerCards(theme, models),
        const SizedBox(height: FanxSpace.md),
        _connectCard(theme),
      ],
    );
  }

  Widget _currentCard(ThemeData theme, AgentModels models) {
    final label = models.currentLabel;
    final running = models.activeProvider != null;

    return _Card(
      title: '当前模型',
      subtitle: running ? '会话正在使用，切换立即生效。' : '下次对话启动时加载。',
      child: Row(
        children: [
          Icon(
            label == null ? Icons.error_outline : Icons.memory_outlined,
            size: 18,
            color: label == null
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label ?? '还没有配置模型 —— 下面接入一个端点即可',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: FanxFonts.mono,
                fontFamilyFallback: FanxFonts.monoFallback,
                fontWeight: label == null ? FontWeight.normal : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _providerCards(ThemeData theme, AgentModels models) {
    if (models.isEmpty) return const [];

    return [
      for (final provider in models.providers) ...[
        _Card(
          title: provider.name,
          subtitle:
              '${provider.baseUrl} · ${provider.models.length} 个模型 · ${provider.api}',
          child: Column(
            children: [
              for (final model in provider.models)
                _ModelRow(
                  model: model,
                  selected:
                      models.defaultProvider == provider.id &&
                      models.defaultModel == model.id,
                  busy: _switchingModel == model.id,
                  onTap: () => _select(provider.id, model.id),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    ];
  }

  Widget _connectCard(ThemeData theme) {
    final probed = _probed;
    final keyword = _filter.text.trim().toLowerCase();
    final visible = probed == null
        ? const <ProbedModel>[]
        : probed
              .where(
                (item) =>
                    keyword.isEmpty ||
                    item.id.toLowerCase().contains(keyword) ||
                    item.name.toLowerCase().contains(keyword),
              )
              .toList(growable: false);

    return _Card(
      title: '接入端点',
      subtitle: '任何 OpenAI 兼容端点（本机路由、LM Studio、vLLM、网关）都能接。先探测，再保存。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _providerId,
                  decoration: const InputDecoration(
                    labelText: 'providerId',
                    helperText: '写进 models.json 的键名，ASCII',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _endpointName,
                  decoration: const InputDecoration(
                    labelText: '显示名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'baseUrl',
              helperText: '例如 http://127.0.0.1:3425/v1 ；不带 /v1 会自动补',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'apiKey',
              helperText: '明文写进该 Agent 自己的 models.json，不影响其它 Agent',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _probing ? null : _probe,
                icon: _probing
                    ? const FanxSpinner(size: 14)
                    : const Icon(Icons.radar_outlined, size: 16),
                label: const Text('探测模型'),
              ),
              const SizedBox(width: 12),
              if (probed != null)
                Text(
                  '探测到 ${probed.length} 个，已选 ${_picked.length} 个',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (probed != null && probed.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filter,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: '过滤模型',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () => setState(() {
                    if (_picked.length == probed.length) {
                      _picked.clear();
                    } else {
                      _picked.addAll(probed.map((item) => item.id));
                    }
                  }),
                  child: Text(_picked.length == probed.length ? '全不选' : '全选'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final model = visible[index];
                  return _ProbedRow(
                    model: model,
                    picked: _picked.contains(model.id),
                    isDefault: _defaultPick == model.id,
                    onPick: (value) => setState(() {
                      if (value == true) {
                        _picked.add(model.id);
                        _defaultPick ??= model.id;
                      } else {
                        _picked.remove(model.id);
                        if (_defaultPick == model.id) {
                          _defaultPick = _picked.firstOrNull;
                        }
                      }
                    }),
                    onDefault: () => setState(() => _defaultPick = model.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? FanxSpinner(size: 14, color: context.tokens.onAccent)
                      : const Icon(Icons.save_outlined, size: 16),
                  label: const Text('保存到该 Agent'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _defaultPick == null ? '未指定默认模型' : '默认模型：$_defaultPick',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: FanxFonts.mono,
                      fontFamilyFallback: FanxFonts.monoFallback,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final ConfiguredModel model;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                model.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (busy)
              const FanxSpinner(size: 14)
            else
              Text(
                model.id,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: FanxFonts.mono,
                  fontFamilyFallback: FanxFonts.monoFallback,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProbedRow extends StatelessWidget {
  const _ProbedRow({
    required this.model,
    required this.picked,
    required this.isDefault,
    required this.onPick,
    required this.onDefault,
  });

  final ProbedModel model;
  final bool picked;
  final bool isDefault;
  final ValueChanged<bool?> onPick;
  final VoidCallback onDefault;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => onPick(!picked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 10, 2),
        child: Row(
          children: [
            Checkbox(
              value: picked,
              onChanged: onPick,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    '${model.id} · ctx ${_compact(model.contextWindow)}'
                    '${model.toolCall ? '' : ' · 不支持工具'}'
                    '${model.reasoning ? ' · 推理' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: FanxFonts.mono,
                      fontFamilyFallback: FanxFonts.monoFallback,
                      fontSize: 11,
                      color: model.toolCall
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: picked ? onDefault : null,
              child: Text(
                isDefault ? '默认' : '设为默认',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isDefault ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _compact(int value) {
    if (value >= 1000) {
      final k = value / 1000;
      return '${k.toStringAsFixed(k >= 100 ? 0 : 1)}K';
    }
    return '$value';
  }
}

class _Card extends StatelessWidget {
  const _Card({
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
