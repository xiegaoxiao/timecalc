import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/backup/presentation/archived_tasks_page.dart';
import '../../features/backup/presentation/backup_page.dart';
import '../../features/sync/presentation/sync_page.dart';
import '../../features/goals/presentation/goal_detail_page.dart';
import '../../features/goals/presentation/goal_list_page.dart';
import '../../features/plan/presentation/plan_page.dart';
import '../../features/progress/presentation/progress_page.dart';
import '../../features/settings/presentation/appearance_page.dart';
import '../../features/settings/presentation/close_behavior_page.dart';
import '../../features/settings/presentation/plan_preference_page.dart';
import '../../features/settings/presentation/reset_data_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/settings/presentation/shortcuts_page.dart';
import '../../features/tasks/data/recurrence_repository_provider.dart';
import '../../features/tasks/data/task_repository_provider.dart';
import '../../features/tasks/presentation/subject_task_page.dart';
import '../../features/today/presentation/today_page.dart';

/// 主导航目的地（v1.12：今天 / 计划 / 目标 / 进度 / 设置）。
enum AppDestination {
  today(label: '今天', icon: Icons.today_outlined, selectedIcon: Icons.today),
  plan(
    label: '计划',
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month,
  ),
  goal(label: '目标', icon: Icons.flag_outlined, selectedIcon: Icons.flag),
  progress(
    label: '进度',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
  ),
  settings(
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  );

  const AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;

  /// 选中态图标（实心），底部导航与侧栏 NavigationRail 共用。
  final IconData selectedIcon;
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
              path: '/goals',
              name: 'goals',
              builder: (context, state) => const GoalListPage(),
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
      // 计划偏好独立页（进度页入口卡 push 进入，设置页移除该区块）。
      GoRoute(
        path: '/plan-preference',
        name: 'planPreference',
        builder: (context, state) => const PlanPreferencePage(),
      ),
      // 设置页子页（整宽菜单 push 进入，均自带 Scaffold + AppBar，
      // 无路径参数，不需要 redirect helper）。
      GoRoute(
        path: CloseBehaviorPage.route,
        name: 'closeBehavior',
        builder: (context, state) => const CloseBehaviorPage(),
      ),
      GoRoute(
        path: BackupPage.route,
        name: 'backup',
        builder: (context, state) => const BackupPage(),
      ),
      GoRoute(
        path: SyncPage.route,
        name: 'sync',
        builder: (context, state) => const SyncPage(),
      ),
      GoRoute(
        path: ArchivedTasksPage.route,
        name: 'archivedTasks',
        builder: (context, state) => const ArchivedTasksPage(),
      ),
      GoRoute(
        path: AppearancePage.route,
        name: 'appearance',
        builder: (context, state) => const AppearancePage(),
      ),
      GoRoute(
        path: ShortcutsPage.route,
        name: 'shortcuts',
        builder: (context, state) => const ShortcutsPage(),
      ),
      GoRoute(
        path: ResetDataPage.route,
        name: 'resetData',
        builder: (context, state) => const ResetDataPage(),
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

/// 主导航 Shell：宽窗用左侧 NavigationRail（桌面观感），窄窗回退底部
/// NavigationBar（手机式布局）。
///
/// 断点 [kDesktopNavigationBreakpoint]：>= 该宽度走侧栏，否则底栏。
/// 借鉴 proxypin / flutter-folio 的自适应布局思路——同一个
/// [StatefulShellRoute.indexedStack] 承载页面状态，切换导航形态不丢页。
///
/// 首帧触发重复任务滚动生成（FR-4.3：应用打开即补齐未来 30 天窗口内
/// 缺失实例）；无 active 模板时为空操作。
const double kDesktopNavigationBreakpoint = 720;

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 触发一次滚动生成；结果不用于渲染。
    ref.watch(recurrenceBootstrapProvider);
    // 启动预热进度页的重数据源（26 周完成记录扫描）：
    // 首次切到「进度」页时数据已在后台 isolate 就绪，页面无需先等查询
    // 再整页构建（消除首次切换的 spinner 等待与二次构建）。
    ref.watch(completedTasksProvider);

    void onDestinationSelected(int index) {
      navigationShell.goBranch(
        index,
        initialLocation: index == navigationShell.currentIndex,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kDesktopNavigationBreakpoint) {
          return _DesktopShell(
            navigationShell: navigationShell,
            onDestinationSelected: onDestinationSelected,
          );
        }
        return Scaffold(
          body: navigationShell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: [
              for (final destination in AppDestination.values)
                NavigationDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: destination.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 宽窗口桌面壳：左侧 NavigationRail + 内容区。
///
/// 侧栏窄带（约 80px）+ 选中态指示器，与底部 NavigationBar 共用同一套
/// destination 定义与选中逻辑；Rail 与内容区之间以细分隔线隔开。
class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.navigationShell,
    required this.onDestinationSelected,
  });

  final StatefulNavigationShell navigationShell;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: onDestinationSelected,
            labelType: NavigationRailLabelType.all,
            groupAlignment: -0.9,
            destinations: [
              for (final destination in AppDestination.values)
                NavigationRailDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: Text(destination.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}
