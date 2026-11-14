import 'package:flutter/foundation.dart';

import '../core/api/daemon_client.dart';
import '../core/api/models.dart';

/// 全局应用状态：Agent 列表 + daemon 连接状态。
/// 规模还小，用 ChangeNotifier 足够；后续要接 Riverpod 也不用改调用方。
class AppState extends ChangeNotifier {
  AppState(this.client);

  final DaemonClient client;

  List<Agent> agents = const [];
  bool loading = true;
  bool offline = false;
  String? error;

  Agent? byId(String? id) {
    if (id == null) return null;
    for (final agent in agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      agents = await client.listAgents();
      offline = false;
      error = null;
    } on ApiException catch (exception) {
      offline = true;
      error = exception.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<Agent> create({
    required String name,
    String? id,
    String? description,
    String? cwd,
    String? configDir,
    String? systemPrompt,
    String? cloneFrom,
  }) async {
    final agent = await client.createAgent(
      name: name,
      id: id,
      description: description,
      cwd: cwd,
      configDir: configDir,
      systemPrompt: systemPrompt,
      cloneFrom: cloneFrom,
    );
    await refresh();
    return agent;
  }

  Future<void> remove(String id, {bool deleteDir = false}) async {
    await client.deleteAgent(id, deleteDir: deleteDir);
    await refresh();
  }
}

/// 全局单例。用 var 而非 final，是为了测试里能换成带 mock 传输层的实例。
AppState appState = AppState(DaemonClient());
