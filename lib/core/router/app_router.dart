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
import '../../features/timetable/presentation/timetable_page.dart';
import '../../features/today/presentation/today_page.dart';
import '../../shared/widgets/clash_tones.dart';
import '../providers/clock_provider.dart';
import '../providers/motion_provider.dart';
import '../theme/app_tokens.dart';

/// 主导航目的地（v1.18：今天 / 计划 / 课表 / 目标 / 进度 / 设置）。
enum AppDestination {
  today(label: '今天', icon: Icons.today_outlined, selectedIcon: Icons.today),
  plan(
    label: '计划',
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month,
  ),
  // 课表（FR-10）：外部给定的固定作息，与「计划」互补——计划回答「我打算
  // 做什么」，课表回答「我什么时候有课」。
  timetable(
    label: '课表',
    icon: Icons.calendar_view_week_outlined,
    selectedIcon: Icons.calendar_view_week,
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
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/today',
                name: 'today',
                builder: (context, state) => const TodayPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/plan',
                name: 'plan',
                builder: (context, state) => const PlanPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/timetable',
                name: 'timetable',
                builder: (context, state) => const TimetablePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/goals',
                name: 'goals',
                builder: (context, state) => const GoalListPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/progress',
                name: 'progress',
                builder: (context, state) => const ProgressPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                name: 'settings',
                builder: (context, state) => const SettingsPage(),
              ),
            ],
          ),
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
    final nextMidnight = DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).add(const Duration(seconds: 1));
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

/// 宽窗口桌面壳：撞色侧栏 + 内容区。
///
/// 侧栏为 [AppTokens.sidebarWidth]（208px）的**撞色导航面板**：顶部品牌区
/// （撞色渐变 Logo 块 + 名称 + 副标题）、中部六个导航项、底部暖×冷撞色
/// 装饰条。背景取 `scheme.surfaceContainerLow`（浅色=白、深色=卡面），
/// 右侧一条 `scheme.outlineVariant` 细边框与内容区分离——侧栏是全站
/// 「暖橙 × 冷藏青」撞色语言的第一印象。
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
    return Scaffold(
      body: Row(
        children: [
          Container(
            // key 供测试定位自定义侧栏导航项（nav_helper.dart）。
            key: const ValueKey('desktop-sidebar'),
            width: AppTokens.sidebarWidth,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border(
                right: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SidebarBrand(),
                // 导航列表：矮窗口下允许被裁切，但**不产生第二个 Scrollable**
                // ——桌面壳里必须只有页面内容区自己的 Scrollable，否则测试的
                // `scrollUntilVisible(find.byType(Scrollable))` 会因歧义抛
                // `Bad state: Too many elements`（跨页回归）。
                // OverflowBox 解除高度约束 ⇒ 不抛 RenderFlex overflow；
                // ClipRect 把超出部分裁掉（纯视觉保护，零副作用）。
                Expanded(
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      maxHeight: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.only(top: AppTokens.spaceSm),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ...List.generate(AppDestination.values.length, (
                              index,
                            ) {
                              final dest = AppDestination.values[index];
                              final isSelected =
                                  index == navigationShell.currentIndex;
                              return _NavItem(
                                destination: dest,
                                isSelected: isSelected,
                                onTap: () => onDestinationSelected(index),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // 底部暖×冷撞色装饰条：撞色语言的签名收尾（纯装饰，无文案）。
                const _SidebarClashBar(),
                const SizedBox(height: AppTokens.spaceMd),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// 侧栏品牌区：撞色渐变 Logo 方块 + 产品名 + 副标题。
///
/// 与导航列表之间用**暖调细边框**分隔（`ClashTone.warm.ink` 低透明度），
/// 让品牌区成为侧栏的第一眼撞色，又不与导航项的选中块抢权重。副标题取
/// 既有语义文案「时间计算器」（与 `app.dart` 的窗口标题同源，不新增文案）。
class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warm = ClashTones.of(context, ClashTone.warm);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg,
        AppTokens.spaceLg,
        AppTokens.spaceLg,
        AppTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: ClashTones.tint(warm.ink, alpha: 0.18)),
        ),
      ),
      child: Row(
        children: [
          // 品牌 Logo：暖×冷双撞色渐变 + 方块，全站品牌标识的最小单位
          // （标题栏小方块与之同源）。
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: ClashGradient.clash(context),
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            child: Icon(
              Icons.access_time_rounded,
              size: 20,
              color: warm.onFill,
            ),
          ),
          const SizedBox(width: AppTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TimeCalc',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '时间计算器',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 侧栏底部撞色装饰条：暖 × 冷双色渐变收束整块导航面板（纯装饰）。
class _SidebarClashBar extends StatelessWidget {
  const _SidebarClashBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
      child: ClipRRect(
        // 圆角被 4px 条高限制，取最小间距档的一半。
        borderRadius: BorderRadius.circular(AppTokens.spaceXs / 2),
        child: Container(
          height: 4,
          decoration: BoxDecoration(gradient: ClashGradient.clash(context)),
        ),
      ),
    );
  }
}

/// 侧栏单个导航项（2026-08-20 动效改造 / 撞色重构）。
///
/// 状态语言（状态不只靠颜色：图标切换 + 字重 + 竖条三重承载）：
/// - **选中**：撞色**实心块**（`ClashTones.fill`）圆角 [AppTokens.radiusMd]，
///   图标与文字用 `ClashTones.onFill`（白），字重 w700，并按撞色色相投影；
///   hover/pressed 时填充本身加深（`ClashTones.fillHover` / `fillPressed`），
///   投影叠加 = 「可交互」直接写在填充上，而不只是阴影变化；
/// - **hover（未选中）**：`ClashTones.tint(t.ink, alpha: 0.08)` 圆角底；
/// - **未选中**：图标/文字 `scheme.onSurfaceVariant`（中性灰）。
///
/// 微交互：hover/选中底 `AnimatedContainer` 过渡、图标 outlined↔filled
/// `AnimatedSwitcher` 淡切、选中竖条高度生长、文字字重动画。动画时长随
/// 「减少动画」开关归零（[motionControllerProvider]），反馈仍即时呈现。
class _NavItem extends ConsumerStatefulWidget {
  const _NavItem({
    required this.destination,
    required this.isSelected,
    required this.onTap,
  });

  final AppDestination destination;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  ConsumerState<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends ConsumerState<_NavItem> {
  bool _hovered = false;

  /// 指针按下态（由 InkWell 的 onTapDown/onTapUp/onTapCancel 驱动）。
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final motion = ref.watch(motionControllerProvider);
    final warm = ClashTones.of(context, ClashTone.warm);
    final dest = widget.destination;
    final isSelected = widget.isSelected;
    final icon = isSelected ? dest.selectedIcon : dest.icon;
    // 实心撞色块上必须用 onFill；未选中走中性灰，hover 时转暖色 ink，
    // 给「即将点中」的即时反馈（深色模式下 fill 与 ink 角色不同，不能混用）。
    final color = isSelected
        ? warm.onFill
        : (_hovered ? warm.ink : scheme.onSurfaceVariant);

    // 背景：选中＝撞色实心块，hover/pressed 用 fillHover/fillPressed 把反馈
    // 直接做在填充上（白字对比只增不减）；hover（未选中）＝撞色 8% 透明底。
    final background = isSelected
        ? (_pressed
              ? ClashTones.fillPressed(warm.fill)
              : (_hovered ? ClashTones.fillHover(warm.fill) : warm.fill))
        : (_hovered
              ? ClashTones.tint(warm.ink, alpha: 0.08)
              : Colors.transparent);
    // 选中块按撞色自身色相投影（hover/pressed 时抬升加强），叠加在填充加深之上。
    final shadows = isSelected
        ? AppTokens.shadowTinted(
            warm.fill,
            opacity: _pressed ? 0.36 : (_hovered ? 0.32 : 0.22),
          )
        : const <BoxShadow>[];

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: AppTokens.spaceXs,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            // 按下态：用 InkWell 自带的 tap 回调记录（不额外套手势层，
            // 避免与 InkWell 的手势竞技场抢事件）。
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: () {
              if (_pressed) setState(() => _pressed = false);
              widget.onTap();
            },
            child: AnimatedContainer(
              duration: motion.duration(AppTokens.motionFast),
              curve: motion.curve,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceMd,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                boxShadow: shadows,
              ),
              child: Row(
                children: [
                  // 选中竖条指示器：高度生长 + 淡入（未选中 0 高度不占位跳动）；
                  // 选中块内取 onFill，保证落在撞色实心底上仍可辨。
                  AnimatedContainer(
                    duration: motion.duration(AppTokens.motionFast),
                    curve: motion.curve,
                    width: 3,
                    height: isSelected ? 18 : 0,
                    margin: const EdgeInsets.only(right: AppTokens.spaceMd),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // 图标 outlined↔filled 切换：AnimatedSwitcher 淡入淡出，
                  // 外包 RepaintBoundary 隔离重绘（局部小 widget，不触整页合成）。
                  RepaintBoundary(
                    child: AnimatedSwitcher(
                      duration: motion.duration(
                        const Duration(milliseconds: 150),
                      ),
                      switchInCurve: motion.curve,
                      switchOutCurve: motion.curve,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Icon(
                        icon,
                        key: ValueKey(icon),
                        size: 20,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceMd),
                  AnimatedDefaultTextStyle(
                    duration: motion.duration(AppTokens.motionFast),
                    curve: motion.curve,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: color,
                    ),
                    child: Text(dest.label),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
