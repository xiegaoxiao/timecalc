import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/duration_format.dart';
import '../../../services/statistics_service.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';

/// 进度页（M3）：基础统计与热力图（FR-7.1 / FR-7.2 / FR-7.4）。
///
/// 结构（自上而下）：
/// 1. 今日概览：今日完成数/总数、今日已完成预估时长、目标剩余工作量；
/// 2. 热力图：按「完成日期」统计最近 26 周完成任务数量（色块 + tooltip
///    与图例文本，状态不只依赖颜色，NFR-4）；
/// 3. FR-7.4 说明：无预估时长的任务只计入任务数。
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

    final style = Theme.of(context).textTheme.bodySmall;

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
        Text(
          '说明：无预估时长的任务只计入任务数，不计入时长（FR-7.4）。'
          '热力图按任务完成日期统计。',
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

/// 热力图区（FR-7.2）：GitHub 风格，最近 26 周，周一开头。
///
/// 每列一周，每行一个星期几；色块强度按完成数量分桶，
/// tooltip 展示「yyyy-MM-dd 完成 N 项」，图例提供 0/1-2/3-5/6+ 文本
/// （状态不只依赖颜色表达，NFR-4）。
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
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('少', style: TextStyle(fontSize: 11)),
                for (var level = 0; level <= 4; level++)
                  _LegendCell(
                    color: _levelColor(scheme, level),
                    label: _levelLabel(level),
                  ),
                const Text('多', style: TextStyle(fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color _levelColor(ColorScheme scheme, int level) {
    if (level >= 3) return scheme.primary;
    return switch (level) {
      0 => scheme.surfaceContainerHighest,
      1 => scheme.primaryContainer.withValues(alpha: 0.35),
      _ => scheme.primary.withValues(alpha: 0.55),
    };
  }

  static String _levelLabel(int level) {
    return switch (level) {
      0 => '0',
      1 => '1-2',
      2 => '3-5',
      3 => '6-8',
      _ => '9+',
    };
  }
}

class _LegendCell extends StatelessWidget {
  const _LegendCell({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 9)),
        ],
      ),
    );
  }
}

class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({
    required this.todayStr,
    required this.weekStarts,
    required this.completedCounts,
  });

  final String todayStr;
  final List<DateTime> weekStarts;
  final Map<String, int> completedCounts;

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
                  height: 16,
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

    final color = switch (level) {
      0 => scheme.surfaceContainerHighest,
      1 => scheme.primaryContainer.withValues(alpha: 0.35),
      2 => scheme.primary.withValues(alpha: 0.55),
      3 => scheme.primary,
      _ => scheme.primary,
    };

    return Tooltip(
      message: '$dateStr 完成 $count 项',
      child: Container(
        width: 13,
        height: 13,
        margin: const EdgeInsets.only(top: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: isToday
              ? Border.all(color: scheme.onSurface, width: 1.5)
              : null,
        ),
      ),
    );
  }
}
