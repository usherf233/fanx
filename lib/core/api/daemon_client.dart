import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// daemon 的 HTTP + SSE 客户端。默认连本机 4317，可用 --dart-define=DAEMON_URL 覆盖。
/// `httpClient` 只为测试注入，生产走默认实现。
class DaemonClient {
  DaemonClient({Uri? base, http.Client? httpClient})
    : base =
          base ??
          Uri.parse(
            const String.fromEnvironment(
              'DAEMON_URL',
              defaultValue: 'http://127.0.0.1:4317',
            ),
          ),
      _client = httpClient ?? http.Client();

  final Uri base;
  final http.Client _client;

  Uri _resolve(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$base$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = http.Request(method, _resolve(path, query));
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    late final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw ApiException('连接 daemon 超时，确认服务已启动：$base');
    } catch (error) {
      throw ApiException('无法连接 daemon（$base）：$error');
    }

    final text = await response.stream.bytesToString();
    if (response.statusCode >= 400) {
      var message = '请求失败（${response.statusCode}）';
      try {
        final parsed = jsonDecode(text);
        if (parsed is Map && parsed['error'] is String) {
          message = parsed['error'] as String;
        }
      } catch (_) {
        // 保留默认信息
      }
      throw ApiException(message, statusCode: response.statusCode);
    }

    if (text.trim().isEmpty) return null;
    return jsonDecode(text);
  }

  Future<Map<String, dynamic>> _map(
    String method,
    String path, {
    Object? body,
  }) async {
    final result = await _request(method, path, body: body);
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  Future<bool> health() async {
    try {
      final result = await _map('GET', '/api/health');
      return result['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Agent>> listAgents() async {
    final result = await _map('GET', '/api/agents');
    final raw = result['agents'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Agent.fromJson)
        .toList(growable: false);
  }

  Future<Agent> createAgent({
    required String name,
    String? id,
    String? description,
    String? configDir,
    String? cwd,
    String? systemPrompt,
    String? cloneFrom,
  }) async {
    final result = await _map(
      'POST',
      '/api/agents',
      body: {
        'name': name,
        if (id != null && id.isNotEmpty) 'id': id,
        'description': ?description,
        if (configDir != null && configDir.isNotEmpty) 'configDir': configDir,
        if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          'systemPrompt': systemPrompt,
        if (cloneFrom != null && cloneFrom.isNotEmpty) 'cloneFrom': cloneFrom,
      },
    );
    final agent = result['agent'];
    if (agent is! Map<String, dynamic>) {
      throw ApiException('daemon 返回的 Agent 数据不完整');
    }
    return Agent.fromJson(agent);
  }

  Future<void> deleteAgent(String id, {bool deleteDir = false}) async {
    await _request(
      'DELETE',
      '/api/agents/$id',
      query: {'deleteDir': deleteDir.toString()},
    );
  }

  Future<AgentConfig> getConfig(String id) async {
    final result = await _map('GET', '/api/agents/$id/config');
    return AgentConfig.fromJson(result);
  }

  Future<void> saveSystemPrompt(String id, String systemPrompt) async {
    await _request(
      'PUT',
      '/api/agents/$id/config',
      body: {'systemPrompt': systemPrompt},
    );
  }

  Future<ResourceSnapshot> getResources(String id) async {
    final result = await _map('GET', '/api/agents/$id/resources');
    return ResourceSnapshot.fromJson(result);
  }

  /// 读取单个资源的完整内容：SKILL.md、文件树、扩展注册的工具与命令。
  Future<ResourceDetail> getResourceDetail(
    String id, {
    required String type,
    required String name,
  }) async {
    final result = await _request(
      'GET',
      '/api/agents/$id/resources/item',
      query: {'type': type, 'name': name},
    );
    if (result is! Map<String, dynamic>) {
      throw ApiException('daemon 返回的资源详情为空');
    }
    return ResourceDetail.fromJson(result);
  }

  Future<ResourceSnapshot> toggleResource(
    String id, {
    required String type,
    required String name,
    required bool enabled,
  }) async {
    final result = await _map(
      'POST',
      '/api/agents/$id/resources/toggle',
      body: {'type': type, 'name': name, 'enabled': enabled},
    );
    return _snapshotFrom(result);
  }

  /// 批量启停：按当前过滤结果一次操作，返回更新后的快照。
  Future<ResourceSnapshot> batchToggleResources(
    String id, {
    required String type,
    required List<String> names,
    required bool enabled,
  }) async {
    final result = await _map(
      'POST',
      '/api/agents/$id/resources/batch',
      body: {'type': type, 'names': names, 'enabled': enabled},
    );
    return _snapshotFrom(result);
  }

  /// 从本机路径导入：目录→技能，单文件→扩展/模板/单文件技能。
  Future<ResourceSnapshot> importResource(
    String id, {
    required String type,
    required String source,
    String? name,
    bool overwrite = false,
  }) async {
    final result = await _map(
      'POST',
      '/api/agents/$id/resources/import',
      body: {
        'type': type,
        'source': source,
        'name': ?name,
        'overwrite': overwrite,
      },
    );
    return _snapshotFrom(result);
  }

  /// 新建技能骨架（含 SKILL.md 模板）。
  Future<ResourceSnapshot> createSkill(
    String id, {
    required String name,
    required String description,
  }) async {
    final result = await _map(
      'POST',
      '/api/agents/$id/resources/create',
      body: {'type': 'skills', 'name': name, 'description': description},
    );
    return _snapshotFrom(result);
  }

  Future<ResourceSnapshot> deleteResource(
    String id, {
    required String type,
    required String name,
  }) async {
    final result = await _request(
      'DELETE',
      '/api/agents/$id/resources/item',
      query: {'type': type, 'name': name},
    );
    return _snapshotFrom(
      result is Map<String, dynamic> ? result : <String, dynamic>{},
    );
  }

  ResourceSnapshot _snapshotFrom(Map<String, dynamic> result) {
    final resources = result['resources'];
    if (resources is! Map<String, dynamic>) {
      return const ResourceSnapshot(skills: [], extensions: [], prompts: []);
    }
    return ResourceSnapshot.fromJson(resources);
  }

  /// 跨 Agent 的能力总账：同一份资源装给了谁、谁停着、谁没有。
  Future<LibrarySnapshot> getLibrary() async {
    final result = await _map('GET', '/api/library');
    return LibrarySnapshot.fromJson(result);
  }

  /// 把某个 Agent 的资源复制给另一个 Agent，源 Agent 不受影响。
  Future<void> copyResource({
    required String sourceAgentId,
    required String targetAgentId,
    required String type,
    required String name,
  }) async {
    await _request(
      'POST',
      '/api/library/copy',
      body: {
        'sourceAgentId': sourceAgentId,
        'targetAgentId': targetAgentId,
        'type': type,
        'name': name,
      },
    );
  }

  Future<AgentState> getState(String id) async {
    final result = await _map('GET', '/api/agents/$id/state');
    return AgentState.fromJson(result);
  }

  Future<AgentModels> getModels(String id) async {
    final result = await _map('GET', '/api/agents/$id/models');
    return AgentModels.fromJson(result);
  }

  /// 只探测端点上有哪些模型，不写入任何文件。
  Future<List<ProbedModel>> probeModels(
    String id, {
    required String baseUrl,
    String apiKey = '',
  }) async {
    final result = await _map(
      'POST',
      '/api/agents/$id/models/probe',
      body: {'baseUrl': baseUrl, 'apiKey': apiKey},
    );
    final raw = result['models'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ProbedModel.fromJson)
        .toList(growable: false);
  }

  /// 把端点写进该 Agent 的 models.json，并设定默认模型。
  Future<void> saveModels(
    String id, {
    required String providerId,
    required String name,
    required String baseUrl,
    required String apiKey,
    String api = 'openai-completions',
    String? model,
    List<String>? models,
  }) async {
    await _request(
      'PUT',
      '/api/agents/$id/models',
      body: {
        'providerId': providerId,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'api': api,
        'model': ?model,
        'models': ?models,
      },
    );
  }

  Future<List<AgentSession>> listSessions(String id) async {
    final result = await _map('GET', '/api/agents/$id/sessions');
    final raw = result['sessions'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(AgentSession.fromJson)
        .toList(growable: false);
  }

  Future<void> createSession(String id) async {
    await _request('POST', '/api/agents/$id/sessions');
  }

  /// 只读预览某个会话的历史：不切换后端当前会话。
  /// 点侧栏「看看」走这条，只有发消息时才走 [activateSession]。
  Future<AgentState?> sessionState(String id, String sessionId) async {
    final result = await _request(
      'GET',
      '/api/agents/$id/sessions/$sessionId/state',
    );
    if (result is! Map<String, dynamic>) return null;
    return AgentState.fromJson(result);
  }

  /// 切换当前会话。daemon 会把切换后的完整状态一起返回，
  /// 所以调用方不需要再补一次 getState。
  Future<AgentState?> activateSession(String id, String sessionId) async {
    final result = await _request(
      'POST',
      '/api/agents/$id/sessions/$sessionId/activate',
    );
    if (result is Map<String, dynamic>) {
      final state = result['state'];
      if (state is Map<String, dynamic>) return AgentState.fromJson(state);
    }
    return null;
  }

  Future<void> deleteSession(String id, String sessionId) async {
    await _request('DELETE', '/api/agents/$id/sessions/$sessionId');
  }

  /// 切换当前默认模型；Agent 已启动时会同步切换运行时。
  Future<void> selectModel(
    String id, {
    required String provider,
    required String model,
  }) async {
    await _request(
      'PUT',
      '/api/agents/$id/model',
      body: {'provider': provider, 'model': model},
    );
  }

  Future<void> sendMessage(String id, String message) async {
    await _request('POST', '/api/agents/$id/chat', body: {'message': message});
  }

  Future<void> runAction(String id, String action) async {
    await _request('POST', '/api/agents/$id/action', body: {'action': action});
  }

  /// 订阅某个 Agent 的事件流。调用方取消订阅时 Stream 结束。
  ///
  /// [sessionId] 是期望的会话号：乐观切换期间后端可能还停在旧会话，带上它
  /// 后 daemon 不会再推一份旧会话的全量初始快照过来。
  Stream<Map<String, dynamic>> events(String id, {String? sessionId}) async* {
    final request = http.Request(
      'GET',
      _resolve(
        '/api/agents/$id/events',
        sessionId == null ? null : {'session': sessionId},
      ),
    );
    request.headers['Accept'] = 'text/event-stream';
    final response = await _client.send(request);
    if (response.statusCode >= 400) {
      throw ApiException('事件流连接失败（${response.statusCode}）');
    }

    // 未闭合的半帧用 StringBuffer 暂存，避免 `+=` 反复复制整段缓冲；
    // 已收到的部分用游标扫描，一个 chunk 只做一次 toString。
    final pending = StringBuffer();
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      pending.write(chunk);
      final buffer = pending.toString();
      var cursor = 0;
      while (true) {
        final index = buffer.indexOf('\n\n', cursor);
        if (index == -1) break;
        final frame = buffer.substring(cursor, index);
        cursor = index + 2;
        for (final line in frame.split('\n')) {
          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty) continue;
          try {
            final decoded = jsonDecode(payload);
            if (decoded is! Map<String, dynamic>) continue;
            // 心跳与 SDK 原始事件前端不消费，不进上层分发。
            final type = decoded['type'];
            if (type == 'heartbeat' || type == 'session_event') continue;
            yield decoded;
          } catch (_) {
            // 单帧解析失败跳过，不影响后续
          }
        }
      }
      pending.clear();
      pending.write(buffer.substring(cursor));
    }
  }

  void dispose() {
    _client.close();
  }
}
