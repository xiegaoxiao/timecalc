import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/goals/presentation/goal_detail_page.dart';
import '../../features/plan/presentation/plan_page.dart';
import '../../features/progress/presentation/progress_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/tasks/data/recurrence_repository_provider.dart';
import '../../features/tasks/presentation/subject_task_page.dart';
import '../../features/today/presentation/today_page.dart';

/// 主导航目的地（PRD §7 信息架构：今天 / 计划 / 进度 / 设置）。
enum AppDestination {
  today(label: '今天', icon: Icons.today_outlined),
  plan(label: '计划', icon: Icons.calendar_month_outlined),
  progress(label: '进度', icon: Icons.insights_outlined),
  settings(label: '设置', icon: Icons.settings_outlined);

  const AppDestination({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/today',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/today',
              name: 'today',
              builder: (context, state) => const TodayPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/plan',
              name: 'plan',
              builder: (context, state) => const PlanPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/progress',
              name: 'progress',
              builder: (context, state) => const ProgressPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              name: 'settings',
              builder: (context, state) => const SettingsPage(),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/goals/:goalId',
        name: 'goalDetail',
        // 防御外部深链/拼写错误：非数字参数重定向到首页，避免 build 中
        // 抛 FormatException 红屏（P2-8）。
        redirect: _redirectOnInvalidInt(['goalId']),
        builder: (context, state) =>
            GoalDetailPage(goalId: state.pathParameters['goalId']!),
      ),
      GoRoute(
        path: '/goals/:goalId/subjects/:subjectId',
        name: 'subjectTasks',
        redirect: _redirectOnInvalidInt(['goalId', 'subjectId']),
        builder: (context, state) => SubjectTaskPage(
          goalId: int.parse(state.pathParameters['goalId']!),
          subjectId: int.parse(state.pathParameters['subjectId']!),
        ),
      ),
    ],
  );
});

/// 构造 redirect：任一 [keys] 对应的路径参数不是合法整数时，重定向到首页。
///
/// 配套用法：redirect 通过后，builder 内可直接 `int.parse` 路径参数
/// （已保证合法）。
GoRouterRedirect _redirectOnInvalidInt(List<String> keys) {
  return (context, state) {
    for (final key in keys) {
      final raw = state.pathParameters[key];
      if (raw == null || int.tryParse(raw) == null) return '/today';
    }
    return null; // 合法，继续导航
  };
}

/// 主导航 Shell：底部导航承载四个一级入口。
///
/// 首帧触发重复任务滚动生成（FR-4.3：应用打开即补齐未来 30 天窗口内
/// 缺失实例）；无 active 模板时为空操作。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 触发一次滚动生成；结果不用于渲染。
    ref.watch(recurrenceBootstrapProvider);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: [
          for (final destination in AppDestination.values)
            NavigationDestination(
              icon: Icon(destination.icon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}
