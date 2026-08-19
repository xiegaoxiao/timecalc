import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/backup/presentation/archived_tasks_page.dart';
import '../../features/backup/presentation/backup_page.dart';
import '../../features/goals/presentation/goal_detail_page.dart';
import '../../features/goals/presentation/goal_list_page.dart';
import '../../features/goals/presentation/goal_milestones_page.dart';
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
import '../../features/tasks/presentation/goal_tasks_page.dart';
import '../../features/tasks/presentation/subject_task_page.dart';
import '../../features/today/presentation/today_page.dart';
import '../providers/clock_provider.dart';
import '../theme/app_tokens.dart';

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
        // 详情页用 150ms 淡入轻过渡（默认 MaterialPage 过渡 300ms 且带
        // 位移动画，桌面端叠加骨架屏时观感明显卡顿）；配合卡片点击侧
        // 「数据先到再导航」，进入即内容。
        pageBuilder: (context, state) => CustomTransitionPage(
          transitionDuration: const Duration(milliseconds: 150),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: GoalDetailPage(goalId: state.pathParameters['goalId']!),
        ),
      ),
      GoRoute(
        path: '/goals/:goalId/subjects/:subjectId',
        name: 'subjectTasks',
        redirect: _redirectOnInvalidInt(['goalId', 'subjectId']),
        pageBuilder: (context, state) => CustomTransitionPage(
          transitionDuration: const Duration(milliseconds: 150),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: SubjectTaskPage(
            goalId: int.parse(state.pathParameters['goalId']!),
            subjectId: int.parse(state.pathParameters['subjectId']!),
          ),
        ),
      ),
      GoRoute(
        path: '/goals/:goalId/tasks',
        name: 'goalTasks',
        // 目标全部任务页：详情页任务区预览截断后的全量入口
        // （2026-08-18）。防御非法参数同详情页。
        redirect: _redirectOnInvalidInt(['goalId']),
        pageBuilder: (context, state) => CustomTransitionPage(
          transitionDuration: const Duration(milliseconds: 150),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: GoalTasksPage(
            goalId: int.parse(state.pathParameters['goalId']!),
          ),
        ),
      ),
      GoRoute(
        path: '/goals/:goalId/milestones',
        name: 'goalMilestones',
        // 目标全部里程碑页：详情页里程碑区预览截断后的全量入口
        // （2026-08-18）。防御非法参数同详情页。
        redirect: _redirectOnInvalidInt(['goalId']),
        pageBuilder: (context, state) => CustomTransitionPage(
          transitionDuration: const Duration(milliseconds: 150),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: GoalMilestonesPage(
            goalId: int.parse(state.pathParameters['goalId']!),
          ),
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
const double kDesktopNavigationBreakpoint = 720;

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// 跨午夜自动刷新定时器（M4）。
  Timer? _midnightTimer;

  @override
  void initState() {
    super.initState();
    _armMidnightTimer();
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  /// 桌面应用托盘常驻可能跨天运行：无任何午夜定时器时，「今天」页日期/
  /// 倒计时/逾期状态会停留在昨天（M4）。定时到下个本地午夜 +1s，届时
  /// 失效 [clockProvider]（各页 watch 后以新日期重建），并重新武装。
  void _armMidnightTimer() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1)
        .add(const Duration(seconds: 1));
    _midnightTimer = Timer(nextMidnight.difference(now), () {
      if (!mounted) return;
      ref.invalidate(clockProvider);
      _armMidnightTimer();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 首帧触发重复任务滚动生成（FR-4.3：应用打开即补齐未来 30 天窗口内
    // 缺失实例）；用 ref.listen 订阅而不 watch：生成完成/后续失效不再导致
    // 整个根壳重建（M3）。结果不用于渲染。
    ref.listen(recurrenceBootstrapProvider, (_, _) {});
    // 启动预热进度页的重数据源（26 周完成记录扫描 + 全部未完成任务）：
    // 用 listen 订阅而非 watch，使「每次任务变更 → invalidate
    // completedTasksProvider/allTodoTasksProvider」不再整壳重建（M3；
    // 此前 watch 会让每次勾选任务都重建根壳并重查 26 周）。同时订阅即
    // 触发查询：progressTasksProvider（进度页数据门）依赖这两个数据源，
    // 启动即预热后首次切到进度页数据已就绪，不再「切页 → 触发查询 →
    // 数据到达整页重建（含 3 个 fl_chart）」掉帧（性能复查）。
    ref.listen(completedTasksProvider, (_, _) {});
    ref.listen(allTodoTasksProvider, (_, _) {});

    void onDestinationSelected(int index) {
      widget.navigationShell.goBranch(
        index,
        initialLocation: index == widget.navigationShell.currentIndex,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // RepaintBoundary：分支切换/滚动时内容区独立重绘，隔离 NavigationRail
        // 或 NavigationBar 的重绘；IndexedStack 内各分支页面虽常驻 build，
        // raster 各自独立，切页不再连带整壳 repaint（切页掉帧优化）。
        final content = RepaintBoundary(
          key: const ValueKey('shell-content'),
          child: widget.navigationShell,
        );
        if (constraints.maxWidth >= kDesktopNavigationBreakpoint) {
          return _DesktopShell(
            navigationShell: widget.navigationShell,
            onDestinationSelected: onDestinationSelected,
            content: content,
          );
        }
        return Scaffold(
          body: content,
          bottomNavigationBar: NavigationBar(
            selectedIndex: widget.navigationShell.currentIndex,
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

/// 宽窗口桌面壳：侧栏（NavigationRail）+ 内容区。
///
/// 侧栏为 104px 导航面板（品牌标识由顶部自定义标题栏独家承担，侧栏不再
/// 重复 Logo）；底色统一承载 Rail，右侧细分隔线。NavigationRail 类型
/// 保留（test/shared/nav_helper.dart 依赖 find.byType 定位导航），选中态
/// 样式由 navigationRailTheme 提供（app_theme.dart）。
class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.navigationShell,
    required this.onDestinationSelected,
    required this.content,
  });

  final StatefulNavigationShell navigationShell;
  final ValueChanged<int> onDestinationSelected;

  /// 内容区（已包 RepaintBoundary，隔离侧栏重绘）。
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Row(
        children: [
          // 侧栏面板：NavigationRail；底色与右侧分隔线统一，
          // 与自定义标题栏构成同一「产品外壳」语言。
          Container(
            decoration: BoxDecoration(
              color: isDark ? scheme.surfaceContainerLow : scheme.surface,
              border: Border(
                right: BorderSide(
                  color: isDark
                      ? scheme.outlineVariant.withValues(alpha: 0.4)
                      : AppTokens.neutralBorderLight,
                ),
              ),
            ),
            child: NavigationRail(
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
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}
