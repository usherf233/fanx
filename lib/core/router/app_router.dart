import 'package:go_router/go_router.dart';

import '../../features/launcher/launcher_page.dart';
import '../../features/library/global_library_page.dart';
import '../../features/workspace/workspace_page.dart';

/// 两层结构：启动页选 Agent → 工作区（会话列表 + 功能小菜单）。
/// Agent 与选中状态都落在路径里，后续要做窗口多开或深链接不用改结构。
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const LauncherPage()),
    GoRoute(
      path: '/library',
      builder: (context, state) => const GlobalLibraryPage(),
    ),
    GoRoute(
      path: '/a/:id',
      builder: (context, state) =>
          WorkspacePage(agentId: state.pathParameters['id']!),
    ),
  ],
);
