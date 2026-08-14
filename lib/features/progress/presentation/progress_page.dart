import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/duration_format.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../../shared/widgets/section_header.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';

/// 进度图表主绿（最深绿）：燃尽剩余线 / 热力图最深档 / 耗时图完成段共用。
const _progressGreen = Color(0xFF216E39);

/// 进度图表浅绿：热力图第一档 / 耗时图计划段共用。
const _progressGreenLight = Color(0xFF9BE9A8);

/// LeetCode 官方热力图色板（FR-7.2）。
///
/// 从无到多五档：空（浅灰）、1-3 项、4-6 项、7-9 项、10+ 项。
/// 色值取自 LeetCode 贡献图（#EBEDF0 → #216E39），克制且饱和度递增。
const _heatColors = <Color>[
  Color(0xFFEBEDF0),
  _progressGreenLight,
  Color(0xFF40C463),
  Color(0xFF30A14E),
  _progressGreen,
];

/// 复用单一 DateFormat 实例（Intl 格式化非 const 可构造，逐格/逐任务
/// 新建会引入不必要的日期符号与语言环境解析开销）。
final _ymd = DateFormat('yyyy-MM-dd');
final _md = DateFormat('M/d');
final _hm = DateFormat('HH:mm');

/// 进度页（M3）：基础统计、热力图与任务耗时图（FR-7.1 / FR-7.2 / FR-7.3 / FR-7.4）。
///
/// 结构（自上而下）：
/// 1. 今日概览：今日完成数/总数、今日已完成预估时长、目标剩余工作量；
/// 2. 燃尽趋势（FR-7.3）：最近 30 天「剩余预估时长」随日期的变化 + 理想
///    参考线（今日点 = 当前剩余；虚线按最晚截止日线性递减）；
/// 3. 热力图：按「完成日期」统计最近 26 周完成任务数量（LeetCode 配色，
///    tooltip 与图例文本，状态不只依赖颜色，NFR-4）；
/// 4. 任务耗时图（fl_chart，M7 迭代）：按周展示未来计划与已完成时长；
/// 5. FR-7.4 说明：无预估时长的任务只计入任务数。
/// 进度页各图表的数据聚合（P 优化）。
///
/// 旧版 ProgressPage 在 build 里 watch 4 个任务类 provider、四层嵌套 .when，
/// 任一 provider 变化（如勾选一个任务 → invalidateAppData 全量失效）都会
/// 整页重算全部聚合。现拆为独立 provider：
/// - [progressTasksProvider]：把「全部未完成 + 26 周完成」合并为一次就绪，
///   页面只剩 goals + tasks 两层加载门；
/// - 概览/热力图/燃尽/耗时图各 watch 自己依赖的子集，任一输入变化只重算
///   受影响区块（对应区块组件独立重建，互不连带）。
const _progressStats = StatisticsService();

/// 进度页任务数据：全部未完成 + 最近 26 周完成，一次就绪。
final progressTasksProvider = FutureProvider<({
  List<Task> todo,
  List<Task> completed,
})>((ref) async {
  // 并行发起两个查询（L38）：drift 查询各自在后台执行，避免串行等待。
  final todoFuture = ref.watch(allTodoTasksProvider.future);
  final completedFuture = ref.watch(completedTasksProvider.future);
  final todo = await todoFuture;
  final completed = await completedFuture;
  return (todo: todo, completed: completed);
});

/// 今日概览数据（FR-7.1）：仅依赖今日任务 + 进度任务。
final progressOverviewProvider = Provider<({
  DayCompletionStats stats,
  int remainingMinutes,
  bool hasAnyTask,
})?>((ref) {
  final todayStr = _ymd.format(ref.watch(clockProvider)());
  final todayTasks = ref.watch(tasksByDateProvider(todayStr)).valueOrNull;
  final tasks = ref.watch(progressTasksProvider).valueOrNull;
  if (todayTasks == null || tasks == null) return null;
  // 目标剩余工作量只统计进行中目标（2026-08-14 审查 #2，与今天页 L13
  // 口径一致）：已完成/放弃/归档目标的残留 todo 任务不再计入，避免
  // 两页显示不同数字。燃尽/甘特图仍为全局趋势（不在此过滤）。
  final activeGoalIds = {
    for (final g in ref.watch(goalListProvider).valueOrNull ?? const <Goal>[])
      if (g.status != GoalStatus.completed &&
          g.status != GoalStatus.abandoned &&
          g.status != GoalStatus.archived)
        g.id,
  };
  final activeTodo = tasks.todo
      .where((t) => activeGoalIds.contains(t.goalId))
      .toList();
  return (
    stats: _progressStats.completionStats(todayTasks),
    remainingMinutes: _progressStats.remainingMinutes(activeTodo),
    hasAnyTask: tasks.todo.isNotEmpty || tasks.completed.isNotEmpty,
  );
});

/// 热力图数据（FR-7.2）：仅依赖已完成任务。
final progressHeatmapProvider = Provider<({
  Map<String, int> counts,
  Map<String, List<Task>> byDate,
  List<DateTime> weekStarts,
})?>((ref) {
  final completed = ref.watch(progressTasksProvider).valueOrNull?.completed;
  if (completed == null) return null;
  final byDate = _progressStats.completedTasksByLocalDate(completed);
  return (
    counts: {for (final e in byDate.entries) e.key: e.value.length},
    byDate: byDate,
    weekStarts: StatisticsService.recentWeekStarts(
      ref.watch(clockProvider)(),
    ),
  );
});

/// 燃尽趋势数据（FR-7.3）：仅依赖未完成 + 已完成 + 最晚截止日。
final progressBurndownProvider = Provider<({
  List<BurndownPoint> points,
  int? currentRemaining,
  int doneMinutes,
  DateTime today,
})?>((ref) {
  final tasks = ref.watch(progressTasksProvider).valueOrNull;
  if (tasks == null) return null;
  final today = ref.watch(clockProvider)();
  final goals = ref.watch(goalListProvider).valueOrNull ?? const <Goal>[];
  final endDate = _latestDeadline(goals) ?? today;
  final hasMinutes =
      tasks.todo.any(
        (t) => t.status != 'done' && t.estimatedMinutes != null,
      ) ||
      tasks.completed.any((t) => t.estimatedMinutes != null);
  final points = hasMinutes
      ? StatisticsService.burndownSeries(
          todoTasks: tasks.todo,
          completedTasks: tasks.completed,
          today: today,
          endDate: endDate,
        )
      : const <BurndownPoint>[];
  return (
    points: points,
    currentRemaining: points.isEmpty ? null : points.last.remaining,
    doneMinutes: hasMinutes
        ? StatisticsService.burndownWindowDoneMinutes(
            completedTasks: tasks.completed,
            today: today,
          )
        : 0,
    today: today,
  );
});

/// 任务耗时图数据（FR-7.3 甘特窗口）：跨目标每周聚合在此完成一次，
/// 替代旧版 _GanttSection.build 每帧重算 rows × weekStarts。
final progressGanttProvider = Provider<({
  List<DateTime> weekStarts,
  Map<int, GoalGanttRow> data,
  List<Goal> rows,
  List<int> plannedPerWeek,
  List<int> completedPerWeek,
  bool hasAnyWeek,
})?>((ref) {
  final tasks = ref.watch(progressTasksProvider).valueOrNull;
  if (tasks == null) return null;
  final today = ref.watch(clockProvider)();
  final goals = ref.watch(goalListProvider).valueOrNull ?? const <Goal>[];
  final weekStarts = StatisticsService.ganttWeekStarts(today);
  final data = _progressStats.goalGanttData(
    todoTasks: tasks.todo,
    completedTasks: tasks.completed,
    weekStarts: weekStarts,
  );
  final rows = goals
      .where((g) => data[g.id]?.hasData ?? false)
      .toList();
  final plannedPerWeek = List.filled(weekStarts.length, 0);
  final completedPerWeek = List.filled(weekStarts.length, 0);
  for (final goal in rows) {
    final row = data[goal.id];
    if (row == null) continue;
    for (var i = 0; i < weekStarts.length; i++) {
      plannedPerWeek[i] += row.planned[i];
      completedPerWeek[i] += row.completed[i];
    }
  }
  var hasAnyWeek = false;
  for (var i = 0; i < weekStarts.length; i++) {
    if (plannedPerWeek[i] > 0 || completedPerWeek[i] > 0) {
      hasAnyWeek = true;
      break;
    }
  }
  return (
    weekStarts: weekStarts,
    data: data,
    rows: rows,
    plannedPerWeek: plannedPerWeek,
    completedPerWeek: completedPerWeek,
    hasAnyWeek: hasAnyWeek,
  );
});

/// 进行中目标的最晚截止日（yyyy-MM-dd 文本）；无进行中目标返回 null。
DateTime? _latestDeadline(List<Goal> goals) {
  DateTime? latest;
  for (final goal in goals) {
    if (goal.status == GoalStatus.completed ||
        goal.status == GoalStatus.abandoned ||
        goal.status == GoalStatus.archived) {
      continue;
    }
    final date = parseLocalDate(goal.deadlineDate);
    if (latest == null || date.isAfter(latest)) latest = date;
  }
  return latest;
}

class ProgressPage extends ConsumerWidget {
  const ProgressPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(goalListProvider);
    // 任务类数据合并为一次就绪（todo + completed），首载/出错整页占位；
    // 就绪后各图表区块各自 watch 自己的聚合 provider，互不连带重算。
    final tasksAsync = ref.watch(progressTasksProvider);

    return Scaffold(
      // 无 AppBar（与今天页一致，左上角干净）。
      body: goalsAsync.when(
        loading: () => PageSkeletons.progressPage(),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(goalListProvider),
        ),
        data: (_) => tasksAsync.when(
          loading: () => PageSkeletons.progressPage(),
          error: (error, _) => AppErrorView(
            error: error,
            onRetry: () {
              ref.invalidate(allTodoTasksProvider);
              ref.invalidate(completedTasksProvider);
            },
          ),
          data: (_) => _buildBody(context),
        ),
      ),
    );
  }

  /// 整页纵向滚动（概览 + 燃尽 + 热力图 + 任务耗时图 + 说明统一滚动）。
  ///
  /// 各图表区块为 const 构造、各自 watch 自己的聚合 provider：页面 build
  /// （仅由 goals/tasks 加载态驱动）重建时不连带重建区块；区块只在自身
  /// 依赖的 provider 变化时独立重算（旧版在 _buildBody 里全量聚合 + 整页
  /// 一次性构建全部区块）。
  Widget _buildBody(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 水平边距按容器宽度比例（约 5%，夹取 12~48px），其余交给内容铺满。
        final hPad = (constraints.maxWidth * 0.05).clamp(12.0, 48.0);

        return SingleChildScrollView(
          key: const ValueKey('progressPageScroll'),
          padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              // 计划偏好入口卡：偏好是解读进度（今日概览完成率/剩余工作量）
              // 的上下文，点击进入独立编辑页（设置页已移除该区块）。
              _PlanPreferenceEntryCard(),
              SizedBox(height: 12),
              _TodayOverviewCard(),
              SizedBox(height: 12),
              // 空态 CTA（无可归属目标时不显示按钮）：燃尽/耗时图需要
              // 「带预估时长」的数据，点「去设置预估时长」跳转到计划页排期，
              // 语义比「随便加个任务」更贴合图表；热力图无完成记录时
              // 渲染全灰网格，不放引导按钮。
              _BurndownSection(ctaLabel: '去设置预估时长'),
              SizedBox(height: 12),
              _HeatmapSection(),
              SizedBox(height: 12),
              _GanttSection(ctaLabel: '去设置预估时长'),
              SizedBox(height: 12),
              // 数据统计说明：默认折叠，点击展开（不霸占底部留白）。
              _StatNote(),
            ],
          ),
        );
      },
    );
  }
}

/// 折叠的数据统计说明（底部信息默认收起，避免大段低对比文字喧宾夺主）。
///
/// 一行「数据统计说明」+ 展开/收起 chevron，点击用 [AnimatedSize] 平滑
/// 展开全文；默认折叠。文案沿用原 FR-7.4 说明，不丢失信息。
class _StatNote extends StatefulWidget {
  const _StatNote();

  @override
  State<_StatNote> createState() => _StatNoteState();
}

class _StatNoteState extends State<_StatNote> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text(
                  '数据统计说明',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 16,
                  color: scheme.outline,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(left: 2, right: 2, top: 4),
                  child: Text(
                    '无预估时长的任务只计入任务数，不计入时长（FR-7.4）。'
                    '剩余工作量图展示还没做完的工作量随日期的变化（最右端=今天，'
                    '对应当前剩余），灰色虚线为按最晚截止日匀速消化的参考线；'
                    '热力图按任务完成日期统计；任务耗时图按周展示未来计划（浅色）'
                    '与已完成时长（深色）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 统一图例色块：圆角方块 12×12，可带描边（燃尽实际线保留白描边语义）。
class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, this.borderColor});

  final Color color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: 1.5),
      ),
    );
  }
}

/// 计划偏好入口卡。
///
/// 展示当前每日可用时长与每周可用日摘要；点击进入独立「计划偏好」页编辑
/// （计划偏好是负载计算规则，也是解读进度数据的上下文；编辑细节收敛到
/// 独立页，保持进度页视觉整洁）。
class _PlanPreferenceEntryCard extends ConsumerWidget {
  const _PlanPreferenceEntryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settingsAsync = ref.watch(settingsProvider);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: settingsAsync.when(
        loading: () =>
            const ListTile(title: Text('计划偏好'), subtitle: Text('加载中…')),
        error: (error, _) => ListTile(
          title: const Text('计划偏好'),
          subtitle: Text('加载失败：$error'),
        ),
        data: (settings) {
          final weekdays = SettingsRepository.decodeWeekdays(
            settings.availableWeekdays,
          );
          final weekdayText = weekdays.length == 7
              ? '每周 7 天'
              : '每周 ${weekdays.map(_weekdayShort).join('、')}';
          return InkWell(
            onTap: () => context.push('/plan-preference'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.tune,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '计划偏好',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '每日可用 ${DurationFormat.minutes(settings.dailyAvailableMinutes)} · $weekdayText',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _weekdayShort(int iso) {
    return switch (iso) {
      1 => '一',
      2 => '二',
      3 => '三',
      4 => '四',
      5 => '五',
      6 => '六',
      7 => '日',
      _ => '?',
    };
  }
}

/// 今日概览卡（FR-7.1）。
///
/// 展示今日完成数/总数、今日已完成预估时长与目标剩余工作量，
/// 数字 + 图标文本表达，不只依赖颜色。三项数据用 Wrap 排布：
/// 宽屏下三列并排撑满卡片宽度，窄屏下自动换行不挤压。
///
/// 无数据语义（与「计划已满但全部完成」区分，避免 0 误导）：
/// - 今日没有任务（totalCount==0）：已完成任务 → `-- / --`、已完成时长
///   → `-- 分`；
/// - 应用完全没有任务（[hasAnyTask] 为 false）：目标剩余工作量 → `-- 分`
///   （「今天本来就没有计划」而非「完美完成」）。
class _TodayOverviewCard extends ConsumerWidget {
  const _TodayOverviewCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todayStr = _ymd.format(ref.watch(clockProvider)());
    final todayAsync = ref.watch(tasksByDateProvider(todayStr));
    final data = ref.watch(progressOverviewProvider);
    if (data == null) {
      // 今日任务数据未就绪：首载由页面加载门处理；出错给局部重试，
      // 刷新间隙保留占位，不塌陷整页。
      if (todayAsync.hasError) {
        return AppErrorView(
          error: todayAsync.error!,
          onRetry: () => ref.invalidate(tasksByDateProvider),
        );
      }
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final stats = data.stats;
    final remainingMinutes = data.remainingMinutes;
    final hasAnyTask = data.hasAnyTask;

    final hasTodayTask = stats.totalCount > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(icon: Icons.insights, title: '今日概览'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                // 三项等宽 + 两项间距，恰好铺满卡片内容区。
                const spacing = 16.0;
                final itemWidth = (constraints.maxWidth - spacing * 2) / 3;
                return Wrap(
                  spacing: spacing,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: itemWidth,
                      child: _StatItem(
                        icon: Icons.check_circle_outline,
                        label: '已完成任务',
                        value: hasTodayTask
                            ? '${stats.doneCount}/${stats.totalCount}'
                            : '-- / --',
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: _StatItem(
                        icon: Icons.timer_outlined,
                        label: '已完成时长',
                        value: hasTodayTask
                            ? DurationFormat.minutes(stats.doneMinutes)
                            : '-- 分',
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: _StatItem(
                        icon: Icons.flag_outlined,
                        label: '目标剩余工作量',
                        value: hasAnyTask
                            ? DurationFormat.minutes(remainingMinutes)
                            : '-- 分',
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  height: 1.1,
                  fontSize: 22,
                ),
          ),
        ],
      ),
    );
  }
}

/// 燃尽趋势区（FR-7.3）：最近 [windowDays] 天「剩余预估时长」随日期的
/// 变化 + 理想参考线（fl_chart 图表，视觉重构增强）。
///
/// - 实际剩余（实线 + 面积填充）：今日点 = 当前剩余（与 FR-7.1 口径一致），
///   随日期往前回退，完成日期越晚的任务越晚被「消化」，剩余越多；
/// - 理想参考线（虚线）：从窗口起点的实际剩余按 [endDate]（最晚截止日）
///   线性递减到 0；
/// - Header 右侧展示「当前剩余」大字（燃尽核心信息）；标题与图例用白话
///   （剩余工作量趋势 / 匀速参考线），副标题为一句话结论（过去 N 天消化
///   了多少、还剩多少）；悬停 tooltip + 图例文本 + 整体读屏语义（NFR-4，
///   不只依赖颜色）。
class _BurndownSection extends ConsumerWidget {
  const _BurndownSection({this.ctaLabel = '去添加任务'});

  /// 空态按钮文案（默认「去添加任务」；燃尽/耗时图用「去设置预估时长」）。
  final String ctaLabel;

  /// 实际剩余线颜色（与热力图最深档 / 耗时图完成段共用主绿）。
  static const _remainingColor = _progressGreen;

  /// 面积填充渐变：从主绿淡出到透明。
  static const _areaGradient = [
    Color(0x47216E39), // 主绿 28% 透明度
    Color(0x00216E39), // 全透明
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 理想参考线用主题 outline：浅色浅灰、深色自动提亮（替代硬编码浅灰）。
    final idealColor = scheme.outline;
    // 节点/图例描边：浅色下白色，深色下用 surface 兜住绿色。
    final dotBorder = Theme.of(context).brightness == Brightness.dark
        ? scheme.surface
        : Colors.white;

    // 数据聚合由 progressBurndownProvider 完成（独立区块，输入变化只重算
    // 本区块）；空态 CTA 的目标归属列表同样自查，避免父级传参导致本区块
    // 被无关页面重建连带。
    final data = ref.watch(progressBurndownProvider);
    if (data == null) {
      return const SizedBox.shrink(); // 首载由页面加载门处理
    }
    final activeGoals = ref
            .watch(goalListProvider)
            .valueOrNull
            ?.where(
              (g) =>
                  g.status != GoalStatus.completed &&
                  g.status != GoalStatus.abandoned &&
                  g.status != GoalStatus.archived,
            )
            .toList() ??
        const <Goal>[];
    final onAddTask =
        activeGoals.isEmpty ? null : () => context.go('/plan');
    final today = data.today;
    final points = data.points;
    final currentRemaining = data.currentRemaining;
    final doneMinutes = data.doneMinutes;
    // provider 已按「是否有带时长数据」决定是否生成序列：有序列即有数据。
    final hasMinutes = points.isNotEmpty;

    // 结论句（白话，取代原 FR 术语副标题）：一句话说清这张图讲什么。
    // 拆成「消化了 X」（窗口内完成时长）+「还剩 Y」（当前剩余）两个数字，
    // 按四种状态组句，避免 0 值产生「消化了 0」这类怪话。
    final String summary;
    if (doneMinutes > 0 && (currentRemaining ?? 0) > 0) {
      summary =
          '过去 30 天消化了 ${DurationFormat.minutes(doneMinutes)}，'
          '还剩 ${DurationFormat.minutes(currentRemaining!)}';
    } else if (doneMinutes > 0) {
      summary =
          '过去 30 天消化了 ${DurationFormat.minutes(doneMinutes)}，'
          '带时长的任务已全部完成';
    } else if ((currentRemaining ?? 0) > 0) {
      summary =
          '过去 30 天还没有完成任务，'
          '还剩 ${DurationFormat.minutes(currentRemaining!)}';
    } else {
      summary = '当前没有剩余工作量';
    }

    return Card(
      // 底部留出额外空间：给 X 轴旋转 45° 后的日期标签与悬停 tooltip
      // 预留展示区域，避免贴到卡片边缘。
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              icon: Icons.trending_down,
              title: '剩余工作量趋势',
              subtitle: summary,
              // Header 右侧：当前剩余大字（燃尽核心信息直接呈现）。
              // 无带时长数据时显示灰色 `-- 分`（与顶部今日概览无数据语义一致），
              // 只有真有任务且剩余为 0（全部完成）才显示绿色完成状态。
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('当前剩余', style: Theme.of(context).textTheme.bodySmall),
                  Text(
                    currentRemaining == null
                        ? '-- 分'
                        : DurationFormat.minutes(currentRemaining),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: currentRemaining == null
                          ? scheme.outline
                          : currentRemaining == 0
                          ? scheme.primary
                          : scheme.onSurface,
                      fontWeight: currentRemaining == null
                          ? FontWeight.w400
                          : FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!hasMinutes)
              ChartEmptyState(
                icon: Icons.trending_down,
                title: '还没有可展示的剩余工作量数据',
                caption:
                    '给任务设置预估时长并开始完成后，'
                    '这里会展示剩余工作量随时间的变化',
                actionLabel: onAddTask == null ? null : ctaLabel,
                onAction: onAddTask,
              )
            else ...[
              // RepaintBoundary：fl_chart 每帧 repaint 开销大，隔离成独立
              // 图层，滚动经过时避免整页连带重绘。
              RepaintBoundary(child: _BurndownChart(points: points, today: today)),
              const SizedBox(height: 16),
              // Footer 图例：色块 + 文字（与其它图表统一；无数据时不渲染）。
              Row(
                children: [
                  _LegendDot(color: _remainingColor, borderColor: dotBorder),
                  const SizedBox(width: 8),
                  const Text('剩余工作量', style: TextStyle(fontSize: 10)),
                  const SizedBox(width: 16),
                  _LegendDot(color: idealColor),
                  const SizedBox(width: 8),
                  const Text('匀速参考线', style: TextStyle(fontSize: 10)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 燃尽折线图（fl_chart 重构）：实际剩余（平滑曲线 + 面积填充 + 白描边
/// 节点）+ 理想参考线（虚线）+ 浅色网格 + 日期轴（最右端标注「今天」）
/// + 悬停 tooltip。
///
/// 视觉重构（M7 迭代增强）：
/// - 面积填充：实际线下方 from 深绿 28% 到透明（belowBarData gradient）；
/// - 平滑曲线（isCurved）替代生硬折线；
/// - 节点白描边（FlDotCirclePainter strokeColor 白），图更精致；
/// - 理想线虚线（dashArray），浅灰；
/// - X/Y 轴每 25% 浅色虚线网格，增加参考感；
/// - 入场动画：TweenAnimationBuilder 高度 0→100% 从底部向上生长；
/// - 整体 Semantics（NFR-4）+ 悬停 tooltip（日期 + 剩余 + 理想）。
class _BurndownChart extends StatelessWidget {
  const _BurndownChart({required this.points, required this.today});

  final List<BurndownPoint> points;
  final DateTime today;

  static const _chartHeight = 220.0;

  /// 数据点最大值（Y 轴顶），0 时回退 1。
  int get _maxMinutes {
    var max = 0;
    for (final point in points) {
      if (point.remaining > max) max = point.remaining;
      if (point.ideal > max) max = point.ideal;
    }
    return max <= 0 ? 1 : max;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = points.first.date;
    // fl_chart X 轴用「距窗口起点的天数」而非绝对日期，便于 interval=1。
    double xOf(DateTime date) => date.difference(first).inDays.toDouble();

    final remainingSpots = [
      for (final p in points) FlSpot(xOf(p.date), p.remaining.toDouble()),
    ];
    final idealSpots = [
      for (final p in points) FlSpot(xOf(p.date), p.ideal.toDouble()),
    ];

    final axisStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontSize: 10, color: scheme.outline);

    // Y 轴最大值（含 10% 顶部余量）：gridData 水平间隔与刻度统一用它。
    final maxY = _maxMinutes * 1.1;

    // 图整体读屏语义（NFR-4）：状态不只依赖颜色，辅以文本说明。
    final semanticLabel = StringBuffer('剩余工作量趋势，最近 30 天剩余预估时长。');
    semanticLabel.write(
      '今日剩余 ${DurationFormat.minutes(points.last.remaining)}。',
    );
    final avgMinutes = points.isEmpty
        ? 0
        : points.map((p) => p.remaining).reduce((a, b) => a + b) ~/
              points.length;
    semanticLabel.write('近 30 天平均 ${DurationFormat.minutes(avgMinutes)}。');

    return Semantics(
      label: semanticLabel.toString(),
      child: SizedBox(
        height: _chartHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 旋转 45° 的日期标签水平投影约 30px；按图表实际宽度动态放大
            // 标签间隔，保证相邻标签中心距 ≥ 48px，窄窗不再互相覆盖。
            final perDayPx = constraints.maxWidth / (points.length - 1);
            const minLabelSpacing = 48.0;
            var labelInterval = 5;
            while (perDayPx * labelInterval < minLabelSpacing &&
                labelInterval < points.length) {
              labelInterval += 5;
            }
            return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          // 入场动画改用不裁剪的淡入 + 上移：ClipRect 会把浮出图表区域的
          // 悬停 tooltip 裁掉（问题 3），故取消裁剪。
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 24),
              child: child,
            ),
          ),
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (points.length - 1).toDouble(),
              minY: 0,
              // Y 轴顶留 10% 余量，避免文字贴顶。
              maxY: maxY,
              // 绘图区不裁剪：让 tooltip 可完整浮出图表边界（问题 3）。
              clipData: FlClipData.none(),
              // 淡虚线网格（水平 + 垂直）：用户可直观看出每天/每档的落差。
              // horizontalInterval 按 Y 轴最大值均分（4 档），verticalInterval
              // 与 X 轴标签同步（labelInterval 随宽度动态调整）。
              gridData: FlGridData(
                show: true,
                drawVerticalLine: true,
                drawHorizontalLine: true,
                horizontalInterval: maxY / 4,
                verticalInterval: labelInterval.toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                  strokeWidth: 1,
                  dashArray: [4, 4],
                ),
                getDrawingVerticalLine: (_) => FlLine(
                  color: scheme.outlineVariant.withValues(alpha: 0.3),
                  strokeWidth: 1,
                  dashArray: [4, 4],
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                // 左轴刻度：reservedSize 预留足够宽度把文字完全推出图表区，
                // SideTitleWidget.space 提供文字与绘图区之间的额外间隙，
                // 文本右对齐后与绿色填充区彻底分离。interval 显式设为
                // maxY/4（与水平网格线同步、均匀分布）——否则 fl_chart 自动
                // 刻度可能恰好落在数据点/曲线顶部高度，文字贴线重叠。
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 96,
                    interval: maxY / 4,
                    getTitlesWidget: (value, meta) {
                      final text = value == 0
                          ? '0'
                          : DurationFormat.minutes(value.round());
                      return SideTitleWidget(
                        meta: meta,
                        space: 12,
                        child: Align(
                          alignment: Alignment.centerRight,
                          // FittedBox 缩放长时长文本到槽位内，防溢出压线。
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(text, style: axisStyle),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // X 轴：interval 随宽度动态放大（labelInterval），
                // getTitlesWidget 内对非标签刻度返回空；最右端固定显示
                // 「今天」（水平不旋转，避免与紧邻斜标签叠压）。
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 56,
                    interval: labelInterval.toDouble(),
                    getTitlesWidget: (value, meta) {
                      final index = value.round();
                      // 最右端（今天）优先：即使日期恰好落在标签刻度上，
                      // 也标注「今天」而非日期。水平显示（不旋转），且
                      // 日期标签跳过与「今天」距离不足 labelInterval 的
                      // 紧邻项，避免两个标签挤在一起。
                      if (index == points.length - 1) {
                        return SideTitleWidget(
                          meta: meta,
                          space: 12,
                          child: Text('今天', style: axisStyle),
                        );
                      }
                      if (index <= 0 ||
                          index % labelInterval != 0 ||
                          points.length - 1 - index < labelInterval) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        space: 12,
                        child: Transform.rotate(
                          angle: -math.pi / 4, // -45°，向左下倾斜
                          child: Text(
                            _md.format(points[index].date),
                            style: axisStyle,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // 悬停 tooltip：Windows 桌面鼠标悬停触发。
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  // 关键：让 tooltip 绘制在图表盒区域之上，可完整浮出图表
                  // 边界（配合外层 Card clipBehavior: Clip.none 与
                  // clipData: FlClipData.none()，边缘数据点的气泡不再被截断）。
                  showOnTopOfTheChartBoxArea: true,
                  getTooltipColor: (_) => scheme.inverseSurface,
                  tooltipBorderRadius: BorderRadius.circular(8),
                  getTooltipItems: (touchedSpots) {
                    return touchedSpots.map((spot) {
                      final index = spot.x.round();
                      if (index < 0 || index >= points.length) {
                        return LineTooltipItem('', const TextStyle());
                      }
                      final point = points[index];
                      final isRemaining = spot.barIndex == 0;
                      final value = isRemaining ? point.remaining : point.ideal;
                      return LineTooltipItem(
                        '${_ymd.format(point.date)}\n'
                        '${isRemaining ? '剩余' : '理想'} '
                        '${DurationFormat.minutes(value)}',
                        TextStyle(
                          color: scheme.onInverseSurface,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    }).toList();
                  },
                ),
              ),
              lineBarsData: [
                // 实际剩余线：实线 + 面积填充 + 白描边节点。
                LineChartBarData(
                  spots: remainingSpots,
                  isCurved: true,
                  curveSmoothness: 0.3,
                  color: _BurndownSection._remainingColor,
                  barWidth: 2.5,
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      colors: _BurndownSection._areaGradient,
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  dotData: FlDotData(
                    show: true,
                    getDotPainter: (spot, percent, bar, index) =>
                        FlDotCirclePainter(
                          radius: 3.5,
                          color: _BurndownSection._remainingColor,
                          strokeWidth: 2,
                          // 描边：浅色下白色、深色下 surface，兜住绿色节点。
                          strokeColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? scheme.surface
                              : Colors.white,
                        ),
                  ),
                ),
                // 理想参考线：主题 outline 虚线（自动适配明暗）。
                LineChartBarData(
                  spots: idealSpots,
                  isCurved: true,
                  curveSmoothness: 0.3,
                  color: scheme.outline,
                  barWidth: 2,
                  dashArray: [6, 4],
                  dotData: const FlDotData(show: false),
                ),
              ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 热力图区（FR-7.2）：LeetCode 风格，最近 26 周，周一开头。
///
/// 配色使用 [LeetCode 官方色板]（_heatColors）；小圆角（3px）+ 色块间
/// 白色间距；悬停展示「yyyy-MM-dd：完成 N 项」；底部紧凑图例对应色块。
/// 无完成记录时网格照常渲染（全灰 0 档），把「还没开始」当作真实状态
/// 直观呈现，不放空态引导（与燃尽/耗时图的「去添加任务」空态区分）。
class _HeatmapSection extends ConsumerWidget {
  const _HeatmapSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 数据聚合由 progressHeatmapProvider 完成（独立区块，只随 completed 变化
    // 重算）；目标名映射在格子点击弹窗内自查，本区块不依赖 goals。
    final data = ref.watch(progressHeatmapProvider);
    if (data == null) {
      return const SizedBox.shrink(); // 首载由页面加载门处理
    }
    final today = ref.watch(clockProvider)();
    final todayStr = _ymd.format(today);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final weekStarts = data.weekStarts;
    final completedCounts = data.counts;
    final completedByDate = data.byDate;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              icon: Icons.local_fire_department_outlined,
              title: '完成热力图',
              subtitle: '最近 26 周，按完成日期统计完成任务数量',
            ),
            const SizedBox(height: 12),
            // RepaintBoundary：热力图区域相对独立，滚动经过时只重绘本层，
            // 不连带整页其它图表/列表一起 repaint（进度页整页单滚动视图）。
            RepaintBoundary(
              child: _HeatmapGrid(
                todayStr: todayStr,
                weekStarts: weekStarts,
                completedCounts: completedCounts,
                completedByDate: completedByDate,
                dark: dark,
              ),
            ),
            const SizedBox(height: 12),
            // 图例始终渲染：全灰网格需要「0」档色块解释（与有数据时一致，
            // 不再只在有数据时出现）。
            _CompactLegend(
              colors: _heatColors,
              labels: const ['0', '1-3', '4-6', '7-9', '10+'],
              dark: dark,
            ),
          ],
        ),
      ),
    );
  }
}

/// 紧凑图例：一行色块 + 对应分桶文本，直接对应上方图表颜色。
class _CompactLegend extends StatelessWidget {
  const _CompactLegend({
    required this.colors,
    required this.labels,
    required this.dark,
  });

  final List<Color> colors;
  final List<String> labels;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < colors.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _LegendDot(
            // 暗色主题下空档用深灰，其余色块保持 LeetCode 色板。
            color: i == 0 && dark ? const Color(0xFF3C4043) : colors[i],
          ),
          const SizedBox(width: 4),
          Text(labels[i], style: const TextStyle(fontSize: 10)),
        ],
      ],
    );
  }
}

/// LeetCode 风格热力图网格：小圆角 + 色块间白色间距 + 悬停 tooltip，
/// 点击色块查看当天完成的具体任务。
///
/// 用 LayoutBuilder 按父级宽度动态计算色块尺寸：26 周横向铺满卡片内容区
/// （宽屏下色块自动放大，消除右侧留白），窄窗口自动收缩并出现横向滚动。
class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({
    required this.todayStr,
    required this.weekStarts,
    required this.completedCounts,
    required this.completedByDate,
    required this.dark,
  });

  final String todayStr;
  final List<DateTime> weekStarts;
  final Map<String, int> completedCounts;
  final Map<String, List<Task>> completedByDate;
  final bool dark;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// 星期标签列宽、标签列与网格间距、周间距、色块上下间距、月份标签高。
  static const _labelColumnWidth = 14.0;
  static const _labelGap = 6.0;
  static const _weekGap = 3.0;
  static const _cellVTopGap = 2.0;
  static const _monthLabelHeight = 18.0;

  /// 色块行高 = 色块尺寸 + 上下间距（月份标签区同高，保持列对齐）。
  static double _cellRowHeight(double cellSize) => cellSize + _cellVTopGap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final daysInWeek = 7;
    final maxWeek = weekStarts.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 横向可用宽度 = 父级宽度 - 星期标签列 - 间距。
        final available = constraints.maxWidth - _labelColumnWidth - _labelGap;
        // 色块尺寸：26 周 + 周间距正好铺满剩余宽度（下限 6px 防极端窄窗）。
        final cellSize = (available - _weekGap * (maxWeek - 1)) / maxWeek;
        final size = cellSize < 6 ? 6.0 : cellSize;
        final rowHeight = _cellRowHeight(size);
        final weekColumnWidth = size + _weekGap;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 星期标签列。
              Column(
                children: [
                  const SizedBox(height: _monthLabelHeight),
                  for (var row = 0; row < daysInWeek; row++)
                    SizedBox(
                      height: rowHeight,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          _weekdayLabels[row],
                          style: TextStyle(fontSize: 9, color: scheme.outline),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: _labelGap),
              // 每周一列（列宽随色块尺寸变化，铺满时总宽 = 可用宽度）。
              Row(
                children: [
                  for (var week = 0; week < maxWeek; week++)
                    SizedBox(
                      width: weekColumnWidth,
                      child: Column(
                        children: [
                          _monthLabel(
                            weekStart: weekStarts[week],
                            labelStyle: TextStyle(
                              fontSize: 9,
                              color: scheme.outline,
                            ),
                          ),
                          for (var row = 0; row < daysInWeek; row++)
                            _buildCell(context, weekStarts[week], row, size),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _monthLabel({
    required DateTime weekStart,
    required TextStyle labelStyle,
  }) {
    final firstDay = weekStart;
    // 只在本周首日是一号，或与上一周跨月时显示月份。
    // 上一周用纯日历减法（date_text）：防 DST 切换日偏移导致跨月判断错位。
    if (firstDay.day != 1 &&
        weekStart.month ==
            addLocalDays(weekStart, -7).month) {
      return const SizedBox(height: _monthLabelHeight);
    }
    return SizedBox(
      height: _monthLabelHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        // FittedBox 缩放月份文本适配列宽（列宽可能仅 10px 左右，「10月」
        // 两个字符更宽），避免溢出盖到右侧格子。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('${firstDay.month}月', style: labelStyle),
        ),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    DateTime weekStart,
    int row,
    double size,
  ) {
    // 纯日历加法（date_text）：防 DST 切换日「加 row 天偏移一小时」导致
    // 日期错位（与 statistics_service 周窗口口径一致）。
    final date = addLocalDays(weekStart, row);
    final dateStr = _ymd.format(date);
    final count = completedCounts[dateStr] ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final isToday = dateStr == todayStr;
    final level = StatisticsService.heatLevel(count);

    final color = level == 0 && dark
        ? const Color(0xFF3C4043)
        : _heatColors[level];

    // 点击色块：查看当天完成的具体任务（含 0 档：弹窗内展示空提示）。
    // 已按日期预分桶，此处 O(1) 取当天任务，避免逐格全量扫描。
    final dayTasks = completedByDate[dateStr] ?? const <Task>[];

    return Tooltip(
      message: '$dateStr：完成 $count 项',
      child: Semantics(
        // 屏幕阅读器可读（NFR-4）：日期 + 完成项数，状态不只依赖颜色。
        label: '$dateStr：完成 $count 项',
        child: InkWell(
          onTap: () => _showDayTasks(context, dateStr: dateStr, tasks: dayTasks),
          borderRadius: BorderRadius.circular(3),
          child: Container(
            width: size,
            height: size,
            margin: const EdgeInsets.only(top: _cellVTopGap),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              border: isToday
                  ? Border.all(color: scheme.onSurface, width: 1.5)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// 弹窗展示 [dateStr] 当天完成的任务清单。
  void _showDayTasks(
    BuildContext context, {
    required String dateStr,
    required List<Task> tasks,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => _DayTasksDialog(dateStr: dateStr, tasks: tasks),
    );
  }
}

/// 热力图某天完成任务的查看对话框：当天完成的任务清单（标题、目标、
/// 科目、时长、完成时刻），以及完成数量的汇总文案。
class _DayTasksDialog extends ConsumerWidget {
  const _DayTasksDialog({required this.dateStr, required this.tasks});

  /// 当天日期（yyyy-MM-dd）。
  final String dateStr;

  /// 当天完成的任务（已完成且 completedAt 落于当天）。
  final List<Task> tasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 目标名映射在弹窗内自查（只在打开弹窗时计算，不参与热力图网格的
    // 常规构建路径）。
    final goalsById = {
      for (final g in ref.watch(goalListProvider).valueOrNull ?? const <Goal>[])
        g.id: g,
    };
    return AlertDialog(
      title: Text('$dateStr 完成的任务'),
      content: SizedBox(
        width: 420,
        child: tasks.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '这一天没有完成任务',
                    style: TextStyle(color: scheme.outline),
                  ),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: tasks.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _buildTaskTile(context, ref, tasks[index], goalsById),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildTaskTile(
    BuildContext context,
    WidgetRef ref,
    Task task,
    Map<int, Goal> goalsById,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final goal = goalsById[task.goalId];
    // 科目名经 subjectListProvider 自查（避免父级传参）。
    final subjectName = task.subjectId == null
        ? null
        : ref
            .watch(subjectListProvider(task.goalId))
            .valueOrNull
            ?.where((s) => s.id == task.subjectId)
            .map((s) => s.name)
            .firstOrNull;

    final completedAt = task.completedAt?.toLocal();
    final parts = <String>[
      ?goal?.title,
      ?subjectName,
      if (task.estimatedMinutes != null)
        DurationFormat.minutes(task.estimatedMinutes!),
      if (completedAt != null)
        '完成于 ${_hm.format(completedAt)}',
    ];

    return ListTile(
      dense: true,
      leading: Icon(Icons.check_circle, size: 20, color: scheme.primary),
      title: Text(task.title),
      subtitle: parts.isEmpty ? null : Text(parts.join(' · ')),
    );
  }
}

/// 任务耗时图区（M7 迭代增强，fl_chart 重构）。
///
/// 原「甘特图」实为按目标×周的周时长堆叠条形图（每格竖向条形=该周该
/// 目标时长），无任务时间跨度、非真正甘特图，名不符实；重构后以周为
/// 横轴（一维 fl_chart BarChart），跨目标合并为每周一根堆叠条——
/// 深色=已完成时长（底）、浅色=未来计划时长（上），保留时间趋势。
///
/// 数据聚合（目标×周 + 跨目标合并）由 [progressGanttProvider] 缓存完成，
/// 本区块只在聚合变化时重建——不再每帧重算 rows × weekStarts。
class _GanttSection extends ConsumerWidget {
  const _GanttSection({this.ctaLabel = '去添加任务'});

  /// 空态按钮文案（默认「去添加任务」；燃尽/耗时图用「去设置预估时长」）。
  final String ctaLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(progressGanttProvider);
    if (data == null) {
      return const SizedBox.shrink(); // 首载由页面加载门处理
    }
    final activeGoals = ref
            .watch(goalListProvider)
            .valueOrNull
            ?.where(
              (g) =>
                  g.status != GoalStatus.completed &&
                  g.status != GoalStatus.abandoned &&
                  g.status != GoalStatus.archived,
            )
            .toList() ??
        const <Goal>[];
    final onAddTask =
        activeGoals.isEmpty ? null : () => context.go('/plan');
    final weekStarts = data.weekStarts;
    final plannedPerWeek = data.plannedPerWeek;
    final completedPerWeek = data.completedPerWeek;
    final hasAnyWeek = data.hasAnyWeek;

    return Card(
      // 顶部加大留白：容纳 Y 轴 maxY 刻度的长文本（如「74 小时 10 分」），
      // 底部留白给 X 轴旋转 45° 后的斜日期标签与悬停 tooltip。
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              icon: Icons.bar_chart_outlined,
              title: '任务耗时图',
              subtitle: '按周展示未来计划与已完成时长（分钟）',
            ),
            const SizedBox(height: 12),
            if (!hasAnyWeek)
              ChartEmptyState(
                icon: Icons.bar_chart_outlined,
                title: '还没有带预估时长的任务安排',
                caption: '给任务设置预估时长后，这里会按周展示计划与完成进度',
                actionLabel: onAddTask == null ? null : ctaLabel,
                onAction: onAddTask,
              )
            else ...[
              // RepaintBoundary：fl_chart 每帧 repaint 开销大，隔离成独立
              // 图层，滚动经过时避免整页连带重绘。
              RepaintBoundary(
                child: _BarChart(
                  plannedPerWeek: plannedPerWeek,
                  completedPerWeek: completedPerWeek,
                  weekStarts: weekStarts,
                ),
              ),
              const SizedBox(height: 12),
              // 图例固定在卡片底部，不随图表横向滚动而移动；无数据时不渲染。
              const Row(
                children: [
                  _LegendDot(color: _progressGreenLight),
                  SizedBox(width: 8),
                  Text('计划', style: TextStyle(fontSize: 10)),
                  SizedBox(width: 16),
                  _LegendDot(color: _progressGreen),
                  SizedBox(width: 8),
                  Text('完成', style: TextStyle(fontSize: 10)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 任务耗时图（fl_chart BarChart）：以周为横轴，每周一根堆叠条。
///
/// - 深色段=已完成时长（底），浅色段=未来计划时长（上），仅当对应段 >0
///   时加入，杜绝 fromY==toY 的空段；
/// - X 轴每 3 周一个日期标签（M/d），Y 轴中文时长刻度（沿用燃尽图修复后
///   的 reservedSize/space 配置，杜绝文字压线）；
/// - 悬停 tooltip 按 group.x 反查闭包捕获的每周数据（fl_chart 的
///   getTooltipItem 拿不到被触发的 stack 段，用数据源重建）；
/// - 宽屏铺满，窄窗横向滚动；整体读屏语义（NFR-4）。
class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.plannedPerWeek,
    required this.completedPerWeek,
    required this.weekStarts,
  });

  final List<int> plannedPerWeek;
  final List<int> completedPerWeek;
  final List<DateTime> weekStarts;

  static const _chartHeight = 220.0;

  /// 每周堆叠条宽 + 组间距。
  static const _barWidth = 22.0;
  static const _groupSpace = 6.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weeks = weekStarts.length;

    // 每周总量 + 全局最大值（Y 轴顶）。
    final totals = List.generate(
      weeks,
      (i) => plannedPerWeek[i] + completedPerWeek[i],
    );
    var maxTotal = 1;
    for (final t in totals) {
      if (t > maxTotal) maxTotal = t;
    }
    // 顶部留 20% 余量：长刻度文本（如「74 小时 10 分」）不顶到卡片边缘。
    final maxY = maxTotal * 1.2;

    final axisStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontSize: 10, color: scheme.outline);

    final barGroups = <BarChartGroupData>[];
    for (var i = 0; i < weeks; i++) {
      final planned = plannedPerWeek[i];
      final completed = completedPerWeek[i];
      if (planned + completed <= 0) continue; // 无数据周跳过（x 位置固定）
      final stackItems = <BarChartRodStackItem>[
        if (completed > 0)
          BarChartRodStackItem(0, completed.toDouble(), _progressGreen),
        if (planned > 0)
          BarChartRodStackItem(
            completed.toDouble(),
            (completed + planned).toDouble(),
            _progressGreenLight,
          ),
      ];
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: (completed + planned).toDouble(),
              width: _barWidth,
              rodStackItems: stackItems,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
            ),
          ],
          barsSpace: _groupSpace,
        ),
      );
    }

    // 读屏语义（NFR-4）：状态不只依赖颜色，辅以文本。
    final plannedTotal = plannedPerWeek.fold<int>(0, (a, b) => a + b);
    final completedTotal = completedPerWeek.fold<int>(0, (a, b) => a + b);
    final semanticLabel = StringBuffer('任务耗时图，按周展示未来计划与已完成时长。')
      ..write('窗口内计划 ${DurationFormat.minutes(plannedTotal)}，')
      ..write('已完成 ${DurationFormat.minutes(completedTotal)}。');

    return Semantics(
      label: semanticLabel.toString(),
      child: SizedBox(
        height: _chartHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 最小条宽 = 每周 (barWidth + groupSpace)；宽屏铺满、窄窗横向滚动。
            final minChartWidth = weeks * (_barWidth + _groupSpace);
            final chartWidth = constraints.maxWidth > minChartWidth
                ? constraints.maxWidth
                : minChartWidth;
            // 旋转 45° 的日期标签水平投影约 30px；按图表实际宽度动态放大
            // 周间隔，保证相邻标签中心距 ≥ 40px（窄窗不再互相覆盖）。
            final perWeekPx = chartWidth / weeks;
            const minLabelSpacing = 40.0;
            var labelInterval = 3;
            while (perWeekPx * labelInterval < minLabelSpacing) {
              labelInterval += 1;
            }

            final chart = BarChart(
              BarChartData(
                minY: 0,
                maxY: maxY,
                barGroups: barGroups,
                alignment: BarChartAlignment.spaceAround,
                // 浅色虚线网格（水平 + 垂直），增强参考感。
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  drawHorizontalLine: true,
                  horizontalInterval: maxY / 4,
                  verticalInterval: 3,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.35),
                    strokeWidth: 1,
                    dashArray: [4, 4],
                  ),
                  getDrawingVerticalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.2),
                    strokeWidth: 1,
                    dashArray: [4, 4],
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      // 长中文文本（如「66 小时 40 分」）需足够槽位宽度，
                      // 否则溢出槽位压到柱状图；104 可容纳最长刻度。
                      reservedSize: 104,
                      // interval 显式设为 maxY/4（与水平网格线同步、均匀
                      // 分布）——否则 fl_chart 自动刻度可能恰好等于柱顶
                      // 高度，刻度文字与柱子最高/次高点贴线重叠。
                      interval: maxY / 4,
                      getTitlesWidget: (value, meta) {
                        final text = value == 0
                            ? '0'
                            : DurationFormat.minutes(value.round());
                        return SideTitleWidget(
                          meta: meta,
                          // 文本与绘图区之间的额外间隙，彻底脱离柱状图。
                          space: 14,
                          child: Align(
                            alignment: Alignment.centerRight,
                            // FittedBox 缩放长时长文本到槽位内，防溢出压线。
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(text, style: axisStyle),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      // 旋转 45° 后斜文字需要更高占位 + 底部留白
                      // （与燃尽图 56 统一，避免标签压到下方图例）。
                      reservedSize: 56,
                      interval: labelInterval.toDouble(),
                      getTitlesWidget: (value, meta) {
                        final index = value.round();
                        if (index < 0 ||
                            index >= weeks ||
                            index % labelInterval != 0) {
                          return const SizedBox.shrink();
                        }
                        return SideTitleWidget(
                          meta: meta,
                          space: 12,
                          child: Transform.rotate(
                            angle: -math.pi / 4, // -45°，向左下倾斜
                            child: Text(
                              _md.format(weekStarts[index]),
                              style: axisStyle,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // 悬停 tooltip：按 group.x 反查闭包捕获的每周数据重建文本。
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => scheme.inverseSurface,
                    tooltipBorderRadius: BorderRadius.circular(8),
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final weekIndex = group.x;
                      if (weekIndex < 0 || weekIndex >= weeks) return null;
                      final planned = plannedPerWeek[weekIndex];
                      final completed = completedPerWeek[weekIndex];
                      final parts = <String>[
                        if (planned > 0)
                          '计划 ${DurationFormat.minutes(planned)}',
                        if (completed > 0)
                          '完成 ${DurationFormat.minutes(completed)}',
                      ];
                      return BarTooltipItem(
                        '${_md.format(weekStarts[weekIndex])}'
                        ' 起一周\n${parts.join(' · ')}',
                        TextStyle(
                          color: scheme.onInverseSurface,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ),
              ),
            );

            if (constraints.maxWidth > minChartWidth) {
              return chart;
            }
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: chartWidth, child: chart),
            );
          },
        ),
      ),
    );
  }
}
