import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/duration_format.dart';
import '../../../services/statistics_service.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';

/// LeetCode 官方热力图色板（FR-7.2）。
///
/// 从无到多五档：空（浅灰）、1-3 项、4-6 项、7-9 项、10+ 项。
/// 色值取自 LeetCode 贡献图（#EBEDF0 → #216E39），克制且饱和度递增。
const _heatColors = <Color>[
  Color(0xFFEBEDF0),
  Color(0xFF9BE9A8),
  Color(0xFF40C463),
  Color(0xFF30A14E),
  Color(0xFF216E39),
];

/// 进度页（M3）：基础统计、热力图与甘特图（FR-7.1 / FR-7.2 / FR-7.4）。
///
/// 结构（自上而下）：
/// 1. 今日概览：今日完成数/总数、今日已完成预估时长、目标剩余工作量；
/// 2. 热力图：按「完成日期」统计最近 26 周完成任务数量（LeetCode 配色，
///    tooltip 与图例文本，状态不只依赖颜色，NFR-4）；
/// 3. 任务耗时甘特图：按目标分组，展示最近 26 周每周完成时长；
/// 4. FR-7.4 说明：无预估时长的任务只计入任务数。
class ProgressPage extends ConsumerWidget {
  const ProgressPage({super.key});

  static const _stats = StatisticsService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(clockProvider)();
    final todayStr = DateFormat('yyyy-MM-dd').format(today);

    final goalsAsync = ref.watch(goalListProvider);
    final todayTasksAsync = ref.watch(tasksByDateProvider(todayStr));
    final completedAsync = ref.watch(completedTasksProvider);
    final todoAsync = ref.watch(allTodoTasksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('进度')),
      body: goalsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (goals) => todayTasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('加载失败：$error')),
          data: (todayTasks) => completedAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('加载失败：$error')),
            data: (completed) => todoAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('加载失败：$error')),
              data: (todo) => _buildBody(
                context,
                goals: goals,
                today: today,
                todayTasks: todayTasks,
                completed: completed,
                todo: todo,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, {
    required List<Goal> goals,
    required DateTime today,
    required List<Task> todayTasks,
    required List<Task> completed,
    required List<Task> todo,
  }) {
    final todayStats = _stats.completionStats(todayTasks);
    final remainingMinutes = _stats.remainingMinutes(todo);
    final completedCounts = _stats.completedCountsByLocalDate(completed);
    final weekStarts = StatisticsService.recentWeekStarts(today);
    // 甘特图窗口更宽：过去 12 周 + 当前周 + 未来 13 周，能看到未来计划。
    final ganttStarts = StatisticsService.ganttWeekStarts(today);

    final style = Theme.of(context).textTheme.bodySmall;

    // 整页纵向滚动（ScrollView）：两个图表堆叠时小屏不挤压。
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _TodayOverviewCard(
          stats: todayStats,
          remainingMinutes: remainingMinutes,
        ),
        const SizedBox(height: 8),
        _HeatmapSection(
          today: today,
          weekStarts: weekStarts,
          completedCounts: completedCounts,
        ),
        const SizedBox(height: 8),
        _GanttSection(
          goals: goals,
          todoTasks: todo,
          completedTasks: completed,
          weekStarts: ganttStarts,
        ),
        const SizedBox(height: 8),
        Text(
          '说明：无预估时长的任务只计入任务数，不计入时长（FR-7.4）。'
          '热力图按任务完成日期统计；甘特图浅色为未来计划时长，'
          '深色为已完成时长。',
          style: style,
        ),
      ],
    );
  }
}

/// 今日概览卡（FR-7.1）。
///
/// 展示今日完成数/总数、今日已完成预估时长与目标剩余工作量，
/// 数字 + 图标文本表达，不只依赖颜色。
class _TodayOverviewCard extends StatelessWidget {
  const _TodayOverviewCard({
    required this.stats,
    required this.remainingMinutes,
  });

  final DayCompletionStats stats;
  final int remainingMinutes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日概览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatItem(
                  icon: Icons.task_alt,
                  label: '已完成任务',
                  value: '${stats.doneCount}/${stats.totalCount}',
                ),
                _StatItem(
                  icon: Icons.timer_outlined,
                  label: '已完成时长',
                  value: DurationFormat.minutes(stats.doneMinutes),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.flag_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '目标剩余工作量 ${DurationFormat.minutes(remainingMinutes)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
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
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 热力图区（FR-7.2）：LeetCode 风格，最近 26 周，周一开头。
///
/// 配色使用 [LeetCode 官方色板]（_heatColors）；小圆角（3px）+ 色块间
/// 白色间距；悬停展示「yyyy-MM-dd：完成 N 项」；底部紧凑图例对应色块。
class _HeatmapSection extends StatelessWidget {
  const _HeatmapSection({
    required this.today,
    required this.weekStarts,
    required this.completedCounts,
  });

  final DateTime today;
  final List<DateTime> weekStarts;
  final Map<String, int> completedCounts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final todayStr = DateFormat('yyyy-MM-dd').format(today);
    final hasAny = completedCounts.isNotEmpty;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('完成热力图', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '最近 26 周，按完成日期统计完成任务数量',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (!hasAny)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(Icons.local_fire_department_outlined,
                        size: 40, color: scheme.outline),
                    const SizedBox(height: 8),
                    const Text('还没有完成记录'),
                    const SizedBox(height: 4),
                    Text(
                      '完成任务后，这里会按日期点亮格子',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else
              _HeatmapGrid(
                todayStr: todayStr,
                weekStarts: weekStarts,
                completedCounts: completedCounts,
                dark: dark,
              ),
            const SizedBox(height: 12),
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
          if (i > 0) const SizedBox(width: 6),
          _swatch(colors[i], dark, i == 0),
          const SizedBox(width: 2),
          Text(labels[i], style: const TextStyle(fontSize: 10)),
        ],
      ],
    );
  }

  static Widget _swatch(Color color, bool dark, bool isZero) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        // 暗色主题下空档用深灰，其余色块保持 LeetCode 色板。
        color: isZero && dark ? const Color(0xFF3C4043) : color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// LeetCode 风格热力图网格：小圆角 + 色块间白色间距 + 悬停 tooltip。
class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({
    required this.todayStr,
    required this.weekStarts,
    required this.completedCounts,
    required this.dark,
  });

  final String todayStr;
  final List<DateTime> weekStarts;
  final Map<String, int> completedCounts;
  final bool dark;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final daysInWeek = 7;
    final maxWeek = weekStarts.length;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 星期标签列。
          Column(
            children: [
              const SizedBox(height: 18),
              for (var row = 0; row < daysInWeek; row++)
                SizedBox(
                  height: 17,
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
          const SizedBox(width: 6),
          // 每周一列。
          Row(
            children: [
              for (var week = 0; week < maxWeek; week++)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Column(
                    children: [
                      _monthLabel(weekStart: weekStarts[week]),
                      for (var row = 0; row < daysInWeek; row++)
                        _buildCell(context, weekStarts[week], row),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _monthLabel({required DateTime weekStart}) {
    final firstDay = weekStart;
    // 只在本周首日是一号，或与上一周跨月时显示月份。
    if (firstDay.day != 1 &&
        weekStart.month == weekStart.subtract(const Duration(days: 7)).month) {
      return const SizedBox(height: 18);
    }
    return SizedBox(
      height: 18,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '${firstDay.month}月',
          style: const TextStyle(fontSize: 9),
        ),
      ),
    );
  }

  Widget _buildCell(BuildContext context, DateTime weekStart, int row) {
    final date = weekStart.add(Duration(days: row));
    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final count = completedCounts[dateStr] ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final isToday = dateStr == todayStr;
    final level = StatisticsService.heatLevel(count);

    final color = level == 0 && dark
        ? const Color(0xFF3C4043)
        : _heatColors[level];

    return Tooltip(
      message: '$dateStr：完成 $count 项',
      child: Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: isToday ? Border.all(color: scheme.onSurface, width: 1.5) : null,
        ),
      ),
    );
  }
}

/// 任务耗时甘特图（M3 迭代）。
///
/// - X 轴：过去 12 周 + 当前周 + 未来 13 周（共 26 周），横向可拖拽滚动，
///   能看到之后的任务计划；
/// - Y 轴：当前录入的目标（有计划或完成记录者）；
/// - 条形：每个目标每周的时长分两段——浅色为未来计划时长（未完成任务按
///   计划日期归周），深色为已完成时长（按完成日期归周）；高度按全局最大
///   周时长归一化；
/// - 悬停展示「周起始 yyyy-MM-dd：计划 X · 完成 Y」。
class _GanttSection extends StatelessWidget {
  const _GanttSection({
    required this.goals,
    required this.todoTasks,
    required this.completedTasks,
    required this.weekStarts,
  });

  final List<Goal> goals;
  final List<Task> todoTasks;
  final List<Task> completedTasks;
  final List<DateTime> weekStarts;

  static const _stats = StatisticsService();

  /// 计划（未完成）条形颜色：浅绿。
  static const _plannedColor = Color(0xFF9BE9A8);

  /// 完成条形颜色：最深绿。
  static const _doneColor = Color(0xFF216E39);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final data = _stats.goalGanttData(
      todoTasks: todoTasks,
      completedTasks: completedTasks,
      weekStarts: weekStarts,
    );
    // 只保留有计划或完成记录的目标行。
    final rows = goals.where((g) => data[g.id]?.hasData ?? false).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('任务耗时甘特图', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '按目标分组，展示未来计划与已完成时长（分钟）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(Icons.bar_chart_outlined,
                        size: 40, color: scheme.outline),
                    const SizedBox(height: 8),
                    const Text('还没有带预估时长的任务安排'),
                    const SizedBox(height: 4),
                    Text(
                      '给任务设置预估时长后，这里会按目标展示计划与完成进度',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else
              _GanttGrid(
                rows: rows,
                data: data,
                weekStarts: weekStarts,
              ),
            const SizedBox(height: 12),
            const Row(
              children: [
                _LegendSwatch(color: _plannedColor),
                SizedBox(width: 2),
                Text('计划', style: TextStyle(fontSize: 10)),
                SizedBox(width: 12),
                _LegendSwatch(color: _doneColor),
                SizedBox(width: 2),
                Text('完成', style: TextStyle(fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 图例色块。
class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// 甘特图网格：左列目标名 + 右侧周列双段条形，横向可拖拽。
class _GanttGrid extends StatelessWidget {
  const _GanttGrid({
    required this.rows,
    required this.data,
    required this.weekStarts,
  });

  final List<Goal> rows;
  final Map<int, GoalGanttRow> data;
  final List<DateTime> weekStarts;

  static const _labelWidth = 96.0;
  static const _barWidth = 14.0;
  static const _maxBarHeight = 26.0;
  static const _minBarHeight = 3.0;

  @override
  Widget build(BuildContext context) {
    // 全局最大周总时长（计划 + 完成），用于高度归一化。
    var maxMinutes = 1;
    for (final row in data.values) {
      for (var i = 0; i < row.planned.length; i++) {
        final total = row.planned[i] + row.completed[i];
        if (total > maxMinutes) maxMinutes = total;
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 表头：月份刻度（与热力图一致）。
          Row(
            children: [
              const SizedBox(width: _labelWidth),
              for (var week = 0; week < weekStarts.length; week++)
                _headerMonthCell(weekStart: weekStarts[week]),
            ],
          ),
          const SizedBox(height: 4),
          for (final goal in rows)
            _GoalBarRow(
              goal: goal,
              row: data[goal.id]!,
              weekStarts: weekStarts,
              maxMinutes: maxMinutes,
            ),
        ],
      ),
    );
  }

  static Widget _headerMonthCell({required DateTime weekStart}) {
    // 只在本周首日是一号，或与上一周跨月时显示月份。
    if (weekStart.day != 1 &&
        weekStart.month == weekStart.subtract(const Duration(days: 7)).month) {
      return const SizedBox(width: _barWidth + 3);
    }
    return SizedBox(
      width: _barWidth + 3,
      child: Text(
        '${weekStart.month}月',
        style: const TextStyle(fontSize: 9),
      ),
    );
  }
}

/// 甘特图单目标行：左列目标名 + 右侧每周「计划 + 完成」双段条形。
class _GoalBarRow extends StatelessWidget {
  const _GoalBarRow({
    required this.goal,
    required this.row,
    required this.weekStarts,
    required this.maxMinutes,
  });

  final Goal goal;
  final GoalGanttRow row;
  final List<DateTime> weekStarts;
  final int maxMinutes;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 目标名（固定宽度，超长省略）。
          SizedBox(
            width: _GanttGrid._labelWidth,
            child: Text(
              goal.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
          for (var week = 0; week < row.planned.length; week++)
            _weekCell(week, row.planned[week], row.completed[week]),
        ],
      ),
    );
  }

  Widget _weekCell(int weekIndex, int planned, int completed) {
    final total = planned + completed;
    if (total <= 0) {
      // 无数据的周：空档。
      return Padding(
        padding: const EdgeInsets.only(right: 3),
        child: SizedBox(
          width: _GanttGrid._barWidth,
          height: _GanttGrid._minBarHeight,
        ),
      );
    }

    final weekStart = weekStarts[weekIndex];
    final dateStr = DateFormat('yyyy-MM-dd').format(weekStart);

    // 双段条形：浅色计划段在上，深色完成段在下。
    final plannedHeight = _heightFor(planned);
    final completedHeight = _heightFor(completed);
    final segments = <Widget>[
      if (planned > 0)
        Container(
          width: _GanttGrid._barWidth,
          height: plannedHeight,
          decoration: const BoxDecoration(
            color: _GanttSection._plannedColor,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(3),
              topRight: Radius.circular(3),
            ),
          ),
        ),
      if (completed > 0)
        Container(
          width: _GanttGrid._barWidth,
          height: completedHeight,
          decoration: const BoxDecoration(
            color: _GanttSection._doneColor,
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(3),
              bottomRight: Radius.circular(3),
            ),
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: Tooltip(
        message: _tooltipText(dateStr, planned, completed),
        child: SizedBox(
          height: _GanttGrid._maxBarHeight,
          width: _GanttGrid._barWidth,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: segments,
          ),
        ),
      ),
    );
  }

  static String _tooltipText(String dateStr, int planned, int completed) {
    final parts = <String>[
      if (planned > 0) '计划 ${DurationFormat.minutes(planned)}',
      if (completed > 0) '完成 ${DurationFormat.minutes(completed)}',
    ];
    return '$dateStr 起一周：${parts.join(' · ')}';
  }

  double _heightFor(int minutes) {
    if (minutes <= 0) return 0;
    return _GanttGrid._minBarHeight +
        (minutes / maxMinutes) *
            (_GanttGrid._maxBarHeight - _GanttGrid._minBarHeight);
  }
}
