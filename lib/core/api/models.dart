// 与 daemon 通信的数据模型。字段全部做了容错，后端加字段不会让界面崩。
import 'dart:convert';

class Agent {
  const Agent({
    required this.id,
    required this.name,
    required this.description,
    required this.configDir,
    required this.cwd,
    required this.running,
    required this.skills,
    required this.extensions,
    required this.prompts,
  });

  final String id;
  final String name;
  final String description;
  final String configDir;
  final String cwd;
  final bool running;
  final int skills;
  final int extensions;
  final int prompts;

  int get resourceCount => skills + extensions + prompts;

  factory Agent.fromJson(Map<String, dynamic> json) {
    return Agent(
      id: _string(json['id']),
      name: _string(json['name']),
      description: _string(json['description']),
      configDir: _string(json['configDir']),
      cwd: _string(json['cwd']),
      running: json['running'] == true,
      skills: _int(json['skills']),
      extensions: _int(json['extensions']),
      prompts: _int(json['prompts']),
    );
  }
}

class ResourceItem {
  const ResourceItem({
    required this.name,
    required this.entry,
    required this.description,
    required this.path,
    required this.relPath,
    required this.kind,
    required this.enabled,
    required this.declaredName,
    required this.bytes,
    required this.files,
    required this.modified,
    required this.issues,
    required this.loaded,
  });

  /// 展示名：技能是目录名，扩展/模板是去掉扩展名的文件名。
  final String name;

  /// 磁盘上的真实名字（含扩展名），启停与删除都以它为准。
  final String entry;
  final String description;
  final String path;
  final String relPath;

  /// skill / extension / prompt
  final String kind;
  final bool enabled;
  final String? declaredName;
  final int bytes;
  final int files;
  final DateTime? modified;

  /// 会导致 pi 警告或直接不加载的问题。
  final List<String> issues;

  /// pi 是否真的加载了它。后端没有运行时会话时为 null（未知）。
  final bool? loaded;

  bool get hasIssues => issues.isNotEmpty;

  bool get isSkill => kind == 'skill';

  String get kindLabel => switch (kind) {
    'skill' => '技能',
    'extension' => '扩展',
    'prompt' => '模板',
    _ => kind,
  };

  /// 目录名与 SKILL.md 里声明的 name 不一致时，界面要给出提示。
  bool get nameMismatch =>
      isSkill &&
      declaredName != null &&
      declaredName!.isNotEmpty &&
      declaredName != name;

  String get sizeLabel => formatBytes(bytes);

  factory ResourceItem.fromJson(Map<String, dynamic> json) {
    final issues = json['issues'];
    final loaded = json['loaded'];
    return ResourceItem(
      name: _string(json['name']),
      entry: _string(json['entry']).isEmpty
          ? _string(json['name'])
          : _string(json['entry']),
      description: _string(json['description']),
      path: _string(json['path']),
      relPath: _string(json['relPath']),
      kind: _string(json['kind']).isEmpty ? 'skill' : _string(json['kind']),
      enabled: json['enabled'] == true,
      declaredName: json['declaredName'] is String
          ? json['declaredName'] as String
          : null,
      bytes: _int(json['bytes']),
      files: _int(json['files']),
      modified: DateTime.tryParse(_string(json['modified']))?.toLocal(),
      issues: issues is List
          ? issues.whereType<String>().toList(growable: false)
          : const [],
      loaded: loaded is bool ? loaded : null,
    );
  }
}

/// 检视面板里的文件树条目。
class ResourceFileEntry {
  const ResourceFileEntry({
    required this.path,
    required this.bytes,
    required this.dir,
  });

  final String path;
  final int bytes;
  final bool dir;

  /// 层级深度，用来做缩进。
  int get depth => '/'.allMatches(path).length;

  String get label => path.split('/').last;

  factory ResourceFileEntry.fromJson(Map<String, dynamic> json) {
    return ResourceFileEntry(
      path: _string(json['path']),
      bytes: _int(json['bytes']),
      dir: json['dir'] == true,
    );
  }
}

/// 单个资源的完整内容。
class ResourceDetail {
  const ResourceDetail({
    required this.item,
    required this.entryFile,
    required this.content,
    required this.frontmatter,
    required this.tools,
    required this.commands,
    required this.entries,
  });

  final ResourceItem item;
  final String entryFile;
  final String content;
  final Map<String, String> frontmatter;
  final List<String> tools;
  final List<String> commands;
  final List<ResourceFileEntry> entries;

  factory ResourceDetail.fromJson(Map<String, dynamic> json) {
    final item = json['item'];
    final map = item is Map<String, dynamic> ? item : <String, dynamic>{};
    final frontmatter = <String, String>{};
    final rawFrontmatter = map['frontmatter'];
    if (rawFrontmatter is Map) {
      rawFrontmatter.forEach((key, value) {
        if (value is String) frontmatter[key.toString()] = value;
      });
    }
    List<String> strings(Object? value) => value is List
        ? value.whereType<String>().toList(growable: false)
        : const [];
    final entries = map['entries'];

    return ResourceDetail(
      item: ResourceItem.fromJson(map),
      entryFile: _string(map['entryFile']),
      content: _string(map['content']),
      frontmatter: frontmatter,
      tools: strings(map['tools']),
      commands: strings(map['commands']),
      entries: entries is List
          ? entries
                .whereType<Map<String, dynamic>>()
                .map(ResourceFileEntry.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// 跨 Agent 总览：某份资源在某个 Agent 里的状态。
class LibraryPresence {
  const LibraryPresence({
    required this.agentId,
    required this.agentName,
    required this.enabled,
    required this.loaded,
    required this.entry,
  });

  final String agentId;
  final String agentName;
  final bool enabled;
  final bool? loaded;
  final String entry;

  factory LibraryPresence.fromJson(Map<String, dynamic> json) {
    final loaded = json['loaded'];
    return LibraryPresence(
      agentId: _string(json['agentId']),
      agentName: _string(json['agentName']),
      enabled: json['enabled'] == true,
      loaded: loaded is bool ? loaded : null,
      entry: _string(json['entry']),
    );
  }
}

/// 跨 Agent 总览的一行：同名同类型资源合并成一条，带各 Agent 的状态。
class LibraryItem {
  const LibraryItem({
    required this.key,
    required this.kind,
    required this.name,
    required this.description,
    required this.bytes,
    required this.files,
    required this.issues,
    required this.agents,
  });

  final String key;
  final String kind;
  final String name;
  final String description;
  final int bytes;
  final int files;
  final List<String> issues;
  final List<LibraryPresence> agents;

  bool get hasIssues => issues.isNotEmpty;

  String get kindLabel => switch (kind) {
    'skill' => '技能',
    'extension' => '扩展',
    'prompt' => '模板',
    _ => kind,
  };

  LibraryPresence? presenceFor(String agentId) {
    for (final item in agents) {
      if (item.agentId == agentId) return item;
    }
    return null;
  }

  factory LibraryItem.fromJson(Map<String, dynamic> json) {
    final issues = json['issues'];
    final agents = json['agents'];
    return LibraryItem(
      key: _string(json['key']),
      kind: _string(json['kind']),
      name: _string(json['name']),
      description: _string(json['description']),
      bytes: _int(json['bytes']),
      files: _int(json['files']),
      issues: issues is List
          ? issues.whereType<String>().toList(growable: false)
          : const [],
      agents: agents is List
          ? agents
                .whereType<Map<String, dynamic>>()
                .map(LibraryPresence.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// 全局面板的数据：所有 Agent + 合并后的资源行 + 顶部读数。
class LibrarySnapshot {
  const LibrarySnapshot({
    required this.agents,
    required this.items,
    required this.relations,
    required this.enabled,
    required this.issueCount,
  });

  final List<Agent> agents;
  final List<LibraryItem> items;

  /// 安装关系总数：一行资源装给几个 Agent 就算几条。
  final int relations;
  final int enabled;
  final int issueCount;

  bool get isEmpty => items.isEmpty;

  factory LibrarySnapshot.fromJson(Map<String, dynamic> json) {
    final agents = json['agents'];
    final items = json['items'];
    final stats = json['stats'];
    int pick(String key) => stats is Map ? _int(stats[key]) : 0;

    return LibrarySnapshot(
      agents: agents is List
          ? agents
                .whereType<Map<String, dynamic>>()
                .map(Agent.fromJson)
                .toList(growable: false)
          : const [],
      items: items is List
          ? items
                .whereType<Map<String, dynamic>>()
                .map(LibraryItem.fromJson)
                .toList(growable: false)
          : const [],
      relations: pick('relations'),
      enabled: pick('enabled'),
      issueCount: pick('issues'),
    );
  }
}

/// 把模型网关的原始报错归到可行动的几类。
///
/// 原则：先原样展示原始错误，再补一句人话——不要用"空回复"掩盖真实原因。
String? diagnoseModelError(String? message) {
  if (message == null || message.trim().isEmpty) return null;
  final lower = message.toLowerCase();

  if (lower.contains('10061') ||
      lower.contains('econnrefused') ||
      lower.contains('connection refused') ||
      lower.contains('connect failed') ||
      lower.contains('failed to connect')) {
    return '模型端点拒绝连接：本机代理 / 网关没启动，或 baseUrl 写错了。';
  }
  if (lower.contains('401') || lower.contains('unauthorized')) {
    return '鉴权失败：这个 Agent 的 API Key 无效或已过期。';
  }
  if (lower.contains('403') || lower.contains('forbidden')) {
    return '没有权限：当前 Key 不能访问这个模型。';
  }
  if (lower.contains('404') || lower.contains('not found')) {
    return '端点或模型不存在：检查 baseUrl 与模型 id。';
  }
  if (lower.contains('429') || lower.contains('rate limit')) {
    return '触发限流：稍后重试，或换一个模型。';
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return '请求超时：端点没有在时限内响应。';
  }
  if (lower.contains('context') && lower.contains('length')) {
    return '上下文超长：开个新会话，或让后端压缩历史。';
  }
  if (lower.contains('502') ||
      lower.contains('503') ||
      lower.contains('504') ||
      lower.contains('upstream')) {
    return '网关上游不可用：模型服务本身在报错，先确认代理进程正常。';
  }
  return null;
}

/// 人类可读的体积：界面上读数要短，不要 1234567 B 这种。
String formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1000) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

class ResourceSnapshot {
  const ResourceSnapshot({
    required this.skills,
    required this.extensions,
    required this.prompts,
  });

  final List<ResourceItem> skills;
  final List<ResourceItem> extensions;
  final List<ResourceItem> prompts;

  bool get isEmpty => skills.isEmpty && extensions.isEmpty && prompts.isEmpty;

  int get total => skills.length + extensions.length + prompts.length;

  int get enabledCount =>
      skills.where((item) => item.enabled).length +
      extensions.where((item) => item.enabled).length +
      prompts.where((item) => item.enabled).length;

  int get bytes =>
      skills.fold<int>(0, (sum, item) => sum + item.bytes) +
      extensions.fold<int>(0, (sum, item) => sum + item.bytes) +
      prompts.fold<int>(0, (sum, item) => sum + item.bytes);

  int get issueCount =>
      skills.where((item) => item.hasIssues).length +
      extensions.where((item) => item.hasIssues).length +
      prompts.where((item) => item.hasIssues).length;

  List<ResourceItem> of(String kind) => switch (kind) {
    'skills' => skills,
    'extensions' => extensions,
    'prompts' => prompts,
    _ => const [],
  };

  /// 平铺成一个列表，用于「全部」视图。
  List<ResourceItem> get all => [...skills, ...extensions, ...prompts];

  factory ResourceSnapshot.fromJson(Map<String, dynamic> json) {
    List<ResourceItem> parse(Object? value) {
      if (value is! List) return const [];
      return value
          .whereType<Map<String, dynamic>>()
          .map(ResourceItem.fromJson)
          .toList(growable: false);
    }

    return ResourceSnapshot(
      skills: parse(json['skills']),
      extensions: parse(json['extensions']),
      prompts: parse(json['prompts']),
    );
  }
}

class AgentConfig {
  const AgentConfig({
    required this.systemPrompt,
    required this.authProviders,
    required this.authConfigured,
    required this.configDir,
    required this.cwd,
    required this.settingsJson,
  });

  final String systemPrompt;
  final List<String> authProviders;
  final bool authConfigured;
  final String configDir;
  final String cwd;
  final String settingsJson;

  factory AgentConfig.fromJson(Map<String, dynamic> json) {
    final auth = json['auth'];
    final paths = json['paths'];
    final providers = <String>[];
    if (auth is Map && auth['providers'] is List) {
      for (final item in auth['providers'] as List) {
        if (item is String) providers.add(item);
      }
    }
    return AgentConfig(
      systemPrompt: _string(json['systemPrompt']),
      authProviders: providers,
      authConfigured: auth is Map && auth['configured'] == true,
      configDir: paths is Map ? _string(paths['configDir']) : '',
      cwd: paths is Map ? _string(paths['cwd']) : '',
      settingsJson: _prettyJson(json['settings']),
    );
  }
}

String _prettyJson(Object? value) {
  if (value == null) return '';
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    required this.pending,
    this.stopReason,
    this.errorMessage,
    this.provider,
    this.model,
    this.durationMs,
  });

  final String role;
  final String text;
  final bool pending;

  /// pi 的结束原因：stop / length / error / aborted…
  final String? stopReason;

  /// 模型调用失败时 pi 写在这里的原始错误（可能是 502、401、超时）。
  final String? errorMessage;

  final String? provider;
  final String? model;
  final int? durationMs;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  /// 这一轮没有拿到回复，且 pi 明确说了原因。
  bool get failed =>
      (errorMessage != null && errorMessage!.trim().isNotEmpty) ||
      stopReason == 'error';

  /// 失败时给用户看的诊断：把网关原始错误翻译成一句能行动的话。
  String? get errorHint => diagnoseModelError(errorMessage);

  static ChatMessage? fromJson(Map<String, dynamic> json) {
    final role = json['role'];
    if (role is! String) return null;
    if (role == 'system') return null;
    final error = json['errorMessage'];
    final stop = json['stopReason'];
    final duration = json['durationMs'];
    return ChatMessage(
      role: role,
      text: _contentText(json['content']),
      pending: false,
      stopReason: stop is String ? stop : null,
      errorMessage: error is String && error.trim().isNotEmpty
          ? error.trim()
          : null,
      provider: json['provider'] is String ? json['provider'] as String : null,
      model: json['model'] is String ? json['model'] as String : null,
      durationMs: duration is int ? duration : null,
    );
  }

  static String _contentText(Object? content) {
    if (content is String) return content.trim();
    if (content is! List) return '';
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is! Map) continue;
      final type = block['type'];
      if (type == 'text' && block['text'] is String) {
        buffer.write(block['text']);
      } else if (type == 'thinking' && block['thinking'] is String) {
        // 思考过程不直接展示，留个标记。
        continue;
      } else if (type == 'image') {
        buffer.write('\n[图片]');
      } else if (block['name'] is String) {
        buffer.write('\n[工具 ${block['name']}]');
      }
    }
    return buffer.toString().trim();
  }
}

class AgentState {
  const AgentState({
    required this.running,
    required this.busy,
    required this.messages,
    required this.modelLabel,
    required this.lastError,
    required this.sessionId,
  });

  final bool running;
  final bool busy;
  final List<ChatMessage> messages;
  final String? modelLabel;
  final String? lastError;
  final String? sessionId;

  static const AgentState empty = AgentState(
    running: false,
    busy: false,
    messages: [],
    modelLabel: null,
    lastError: null,
    sessionId: null,
  );

  factory AgentState.fromJson(Map<String, dynamic> json) {
    final messages = <ChatMessage>[];
    final raw = json['messages'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final message = ChatMessage.fromJson(item);
          if (message != null) messages.add(message);
        }
      }
    }
    final model = json['model'];
    String? label;
    if (model is Map) {
      final name = _string(model['name']);
      label = name.isNotEmpty ? name : _string(model['id']);
    }
    final lastError = json['lastError'];
    final sessionId = json['sessionId'];
    return AgentState(
      running: json['running'] == true,
      busy: json['busy'] == true,
      messages: messages,
      modelLabel: label,
      lastError: lastError is String ? lastError : null,
      sessionId: sessionId is String && sessionId.isNotEmpty ? sessionId : null,
    );
  }
}

/// 一个会话（sessions/ 下的一个 JSONL 文件）。
class AgentSession {
  const AgentSession({
    required this.id,
    required this.name,
    required this.preview,
    required this.modified,
    required this.messageCount,
    required this.active,
  });

  final String id;
  final String name;
  final String preview;
  final DateTime? modified;
  final int messageCount;
  final bool active;

  /// 列表里显示什么：有显式命名就用名字，否则用第一条消息当标题。
  String get title {
    if (name.trim().isNotEmpty) return name.trim();
    if (preview.trim().isNotEmpty) return preview.trim();
    return '新会话';
  }

  factory AgentSession.fromJson(Map<String, dynamic> json) {
    return AgentSession(
      id: _string(json['id']),
      name: _string(json['name']),
      preview: _string(json['firstMessage']),
      modified: DateTime.tryParse(_string(json['modified']))?.toLocal(),
      messageCount: _int(json['messageCount']),
      active: json['active'] == true,
    );
  }
}

String _string(Object? value) => value is String ? value : '';

int _int(Object? value) =>
    value is int ? value : (value is num ? value.toInt() : 0);

double _double(Object? value) => value is num
    ? value.toDouble()
    : (value is String ? double.tryParse(value) ?? 0 : 0);

/// 探测到的模型：来自端点 `/v1/models`，用于保存前的预览。
class ProbedModel {
  const ProbedModel({
    required this.id,
    required this.name,
    required this.reasoning,
    required this.toolCall,
    required this.input,
    required this.contextWindow,
    required this.maxTokens,
    required this.costInput,
    required this.costOutput,
  });

  final String id;
  final String name;
  final bool reasoning;
  final bool toolCall;
  final List<String> input;
  final int contextWindow;
  final int maxTokens;
  final double costInput;
  final double costOutput;

  bool get supportsImage => input.contains('image');

  factory ProbedModel.fromJson(Map<String, dynamic> json) {
    final cost = json['cost'];
    return ProbedModel(
      id: _string(json['id']),
      name: _string(json['name']),
      reasoning: json['reasoning'] == true,
      toolCall: json['toolCall'] == true,
      input: json['input'] is List
          ? (json['input'] as List).whereType<String>().toList(growable: false)
          : const ['text'],
      contextWindow: _int(json['contextWindow']),
      maxTokens: _int(json['maxTokens']),
      costInput: cost is Map ? _double(cost['input']) : 0,
      costOutput: cost is Map ? _double(cost['output']) : 0,
    );
  }
}

/// 已写入 models.json 的单个模型。
class ConfiguredModel {
  const ConfiguredModel({required this.id, required this.name});

  final String id;
  final String name;

  factory ConfiguredModel.fromJson(Map<String, dynamic> json) =>
      ConfiguredModel(id: _string(json['id']), name: _string(json['name']));
}

/// 已写入 models.json 的 provider（一个端点）。
class ConfiguredProvider {
  const ConfiguredProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.api,
    required this.models,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String api;
  final List<ConfiguredModel> models;

  factory ConfiguredProvider.fromJson(Map<String, dynamic> json) {
    final raw = json['models'];
    return ConfiguredProvider(
      id: _string(json['id']),
      name: _string(json['name']),
      baseUrl: _string(json['baseUrl']),
      api: _string(json['api']),
      models: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(ConfiguredModel.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// 某个 Agent 的模型配置全景。
class AgentModels {
  const AgentModels({
    required this.providers,
    required this.defaultProvider,
    required this.defaultModel,
    required this.activeProvider,
    required this.activeModel,
  });

  final List<ConfiguredProvider> providers;
  final String? defaultProvider;
  final String? defaultModel;
  final String? activeProvider;
  final String? activeModel;

  bool get isEmpty => providers.isEmpty;

  /// 当前生效的模型：优先取运行时实际加载的那个，其次是配置里的默认值。
  String? get currentLabel {
    final provider = activeProvider ?? defaultProvider;
    final model = activeModel ?? defaultModel;
    if (provider == null || model == null) return null;
    return '$provider / $model';
  }

  factory AgentModels.fromJson(Map<String, dynamic> json) {
    final raw = json['providers'];
    final active = json['active'];
    return AgentModels(
      providers: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(ConfiguredProvider.fromJson)
                .toList(growable: false)
          : const [],
      defaultProvider: json['defaultProvider'] is String
          ? json['defaultProvider'] as String
          : null,
      defaultModel: json['defaultModel'] is String
          ? json['defaultModel'] as String
          : null,
      activeProvider: active is Map && active['provider'] is String
          ? active['provider'] as String
          : null,
      activeModel: active is Map && active['id'] is String
          ? active['id'] as String
          : null,
    );
  }
}
