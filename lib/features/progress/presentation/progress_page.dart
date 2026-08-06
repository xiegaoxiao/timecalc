import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/duration_format.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
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
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(goalListProvider),
        ),
        data: (goals) => todayTasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppErrorView(
            error: error,
            onRetry: () => ref.invalidate(tasksByDateProvider),
          ),
          data: (todayTasks) => completedAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppErrorView(
              error: error,
              onRetry: () => ref.invalidate(completedTasksProvider),
            ),
            data: (completed) => todoAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => AppErrorView(
                error: error,
                onRetry: () => ref.invalidate(allTodoTasksProvider),
              ),
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

    // 甘特图数据一次计算，供行数（行高自适应）与图表区共用。
    final ganttData = _stats.goalGanttData(
      todoTasks: todo,
      completedTasks: completed,
      weekStarts: ganttStarts,
    );
    final ganttRows = goals
        .where((g) => ganttData[g.id]?.hasData ?? false)
        .toList();

    // 整页纵向滚动（概览 + 热力图 + 甘特图 + 说明统一滚动）：甘特图行高
    // 随窗口高度与行数自适应——行少/窗口高时条形饱满，行数多时回落到
    // 最小行高并靠整页滚动查看全部行（不被固定/截断）。
    return LayoutBuilder(
      builder: (context, constraints) {
        // 水平边距按容器宽度比例（约 5%，夹取 12~48px），其余交给内容铺满。
        final hPad = (constraints.maxWidth * 0.05).clamp(12.0, 48.0);
        // 行高：甘特图约占窗口高度 45%，均分给各行，夹取 [min, max]。
        final rowHeight = ganttRows.isEmpty
            ? _GanttChart._defaultRowHeight
            : (constraints.maxHeight * 0.45 / ganttRows.length)
                .clamp(
                  _GanttChart._minRowHeight,
                  _GanttChart._maxRowHeight,
                );

        return SingleChildScrollView(
          key: const ValueKey('progressPageScroll'),
          padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                rows: ganttRows,
                data: ganttData,
                weekStarts: ganttStarts,
                rowHeight: rowHeight,
              ),
              const SizedBox(height: 8),
              // 说明文本：左对齐，不随 stretch 拉伸；随整页滚动。
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '说明：无预估时长的任务只计入任务数，不计入时长（FR-7.4）。'
                  '热力图按任务完成日期统计；甘特图浅色为未来计划时长，'
                  '深色为已完成时长。',
                  style: style,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 今日概览卡（FR-7.1）。
///
/// 展示今日完成数/总数、今日已完成预估时长与目标剩余工作量，
/// 数字 + 图标文本表达，不只依赖颜色。三项数据用 Wrap 排布：
/// 宽屏下三列并排撑满卡片宽度，窄屏下自动换行不挤压。
class _TodayOverviewCard extends StatelessWidget {
  const _TodayOverviewCard({
    required this.stats,
    required this.remainingMinutes,
  });

  final DayCompletionStats stats;
  final int remainingMinutes;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日概览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                // 三项等宽 + 两项间距，恰好铺满卡片内容区。
                const spacing = 16.0;
                final itemWidth =
                    (constraints.maxWidth - spacing * 2) / 3;
                return Wrap(
                  spacing: spacing,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: itemWidth,
                      child: _StatItem(
                        icon: Icons.task_alt,
                        label: '已完成任务',
                        value: '${stats.doneCount}/${stats.totalCount}',
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: _StatItem(
                        icon: Icons.timer_outlined,
                        label: '已完成时长',
                        value: DurationFormat.minutes(stats.doneMinutes),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: _StatItem(
                        icon: Icons.flag_outlined,
                        label: '目标剩余工作量',
                        value: DurationFormat.minutes(remainingMinutes),
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
    return Column(
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
///
/// 用 LayoutBuilder 按父级宽度动态计算色块尺寸：26 周横向铺满卡片内容区
/// （宽屏下色块自动放大，消除右侧留白），窄窗口自动收缩并出现横向滚动。
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
                          _monthLabel(weekStart: weekStarts[week]),
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

  Widget _monthLabel({required DateTime weekStart}) {
    final firstDay = weekStart;
    // 只在本周首日是一号，或与上一周跨月时显示月份。
    if (firstDay.day != 1 &&
        weekStart.month == weekStart.subtract(const Duration(days: 7)).month) {
      return const SizedBox(height: _monthLabelHeight);
    }
    return SizedBox(
      height: _monthLabelHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '${firstDay.month}月',
          style: const TextStyle(fontSize: 9),
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
      child: Semantics(
        // 屏幕阅读器可读（NFR-4）：日期 + 完成项数，状态不只依赖颜色。
        label: '$dateStr：完成 $count 项',
        child: Container(
          width: size,
          height: size,
          margin: const EdgeInsets.only(top: _cellVTopGap),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: isToday ? Border.all(color: scheme.onSurface, width: 1.5) : null,
          ),
        ),
      ),
    );
  }
}

/// 任务耗时甘特图（M3 迭代，flutter_gantt 式布局重构）。
///
/// - X 轴：过去 12 周 + 当前周 + 未来 13 周（共 26 周），横向可拖拽滚动，
///   能看到之后的任务计划；表头双刻度（月份 + ISO 周序号）；
/// - Y 轴：当前录入的目标（有计划或完成记录者），目标名列 sticky 固定；
/// - 条形：每个目标每周的时长分两段——浅色为未来计划时长（未完成任务按
///   计划日期归周），深色为已完成时长（按完成日期归周）；高度按全局最大
///   周时长归一化；
/// - 悬停展示「周起始 yyyy-MM-dd：计划 X · 完成 Y」。
///
/// [rows]/[data] 由页面层计算传入（行高自适应的数据源）；[rowHeight] 为
/// 每目标行高，随窗口高度自适应。
class _GanttSection extends StatelessWidget {
  const _GanttSection({
    required this.rows,
    required this.data,
    required this.weekStarts,
    required this.rowHeight,
  });

  final List<Goal> rows;
  final Map<int, GoalGanttRow> data;
  final List<DateTime> weekStarts;
  final double rowHeight;

  /// 计划（未完成）条形颜色：浅绿。
  static const _plannedColor = Color(0xFF9BE9A8);

  /// 完成条形颜色：最深绿。
  static const _doneColor = Color(0xFF216E39);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  mainAxisSize: MainAxisSize.min,
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
              _GanttChart(
                rows: rows,
                data: data,
                weekStarts: weekStarts,
                rowHeight: rowHeight,
              ),
            const SizedBox(height: 12),
            // 图例固定在卡片底部，不随图表横向滚动而移动。
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

/// 甘特图（flutter_gantt 式左右分栏）：sticky 目标名列 + 双刻度时间轴。
///
/// 参考开源 flutter_gantt 的布局：
/// - 左列固定（sticky）展示目标名，右侧时间轴区横向滚动时目标名始终可见；
/// - 表头双刻度：月份（跨月时显示，1 月带年份）+ ISO 周序号（每周一格）；
/// - 每目标一行、每周一格：双段条形（浅色=未来计划时长、深色=已完成时长），
///   高度按全局最大周时长归一化；格带 tooltip「周起始 yyyy-MM-dd：
///   计划 X · 完成 Y」与屏幕阅读器语义标签（NFR-4）；
/// - 网格线（周列分隔 + 行分隔）接近常规甘特图观感。
///
/// 高度策略：行高由页面层按「窗口高度 × 45% / 目标数」计算并传入
/// （夹取到 [minRowHeight, maxRowHeight]）——窗口越高、目标越少，条形
/// 越饱满；目标行多时回落到最小行高，靠整页滚动查看全部行（本组件
/// 不设置纵向滚动，避免滚动被固定）。
class _GanttChart extends StatelessWidget {
  const _GanttChart({
    required this.rows,
    required this.data,
    required this.weekStarts,
    required this.rowHeight,
  });

  final List<Goal> rows;
  final Map<int, GoalGanttRow> data;
  final List<DateTime> weekStarts;
  final double rowHeight;

  // 布局常量：目标名列宽、周格宽/间距、表头双行高与行高范围（页面层
  // 按窗口高度与行数自适应计算行高，夹取到该范围；整页滚动兜底超高）。
  static const _labelWidth = 112.0;
  static const _barWidth = 20.0;
  static const _cellGap = 4.0;
  static const _monthRowHeight = 18.0;
  static const _weekRowHeight = 18.0;
  static const _headerGap = 6.0;
  static const _minRowHeight = 56.0;
  static const _maxRowHeight = 240.0;
  static const _defaultRowHeight = 68.0;

  /// 每格最小列宽 = 条形宽 + 格间距；表头块高度 = 月份行 + 周行 + 间距。
  static double get _minCellWidth => _barWidth + _cellGap;
  static double get _headerBlockHeight =>
      _monthRowHeight + _weekRowHeight + _headerGap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.45);

    // 全局最大周总时长（计划 + 完成），用于高度归一化。
    var maxMinutes = 1;
    for (final row in data.values) {
      for (var i = 0; i < row.planned.length; i++) {
        final total = row.planned[i] + row.completed[i];
        if (total > maxMinutes) maxMinutes = total;
      }
    }

    final weeks = weekStarts.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 横向：每周格宽 = 可用宽度（去目标名列）均分，宽屏铺满消除
        // 右侧留白；窄窗口回落到最小格宽并靠横向滚动。
        final evenCell = (constraints.maxWidth - _labelWidth) / weeks;
        final cellWidth =
            evenCell >= _minCellWidth ? evenCell : _minCellWidth;
        final totalWidth = cellWidth * weeks;
        final barMaxHeight = rowHeight - 14;

        // 图体：左目标名列 + 右侧时间轴（横向滚动）。
        final gridArea = SizedBox(
          width: totalWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 表头第一行：月份刻度。
              SizedBox(
                height: _monthRowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var w = 0; w < weeks; w++)
                      _headerCell(
                        cellWidth: cellWidth,
                        borderColor: borderColor,
                        height: _monthRowHeight,
                        text: _monthLabel(w),
                        textStyle: const TextStyle(fontSize: 9),
                      ),
                  ],
                ),
              ),
              // 表头第二行：ISO 周序号。
              SizedBox(
                height: _weekRowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var w = 0; w < weeks; w++)
                      _headerCell(
                        cellWidth: cellWidth,
                        borderColor: borderColor,
                        height: _weekRowHeight,
                        text: 'W${_isoWeekOf(weekStarts[w])}',
                        textStyle: TextStyle(
                          fontSize: 9,
                          color: scheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: _headerGap),
              for (final goal in rows)
                _goalRow(
                  goal: goal,
                  row: data[goal.id]!,
                  maxMinutes: maxMinutes,
                  borderColor: borderColor,
                  cellWidth: cellWidth,
                  rowHeight: rowHeight,
                  barMaxHeight: barMaxHeight,
                ),
            ],
          ),
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左列（sticky）：目标名，右侧滚动时保持可见；行高与数据区同步。
            SizedBox(
              width: _labelWidth,
              child: ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: _headerBlockHeight),
                    for (final goal in rows)
                      SizedBox(
                        height: rowHeight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              goal.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: gridArea,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 表头单元格：动态列宽 + 右分隔线（与数据行网格列对齐）。
  static Widget _headerCell({
    required double cellWidth,
    required Color borderColor,
    required double height,
    required String text,
    required TextStyle textStyle,
  }) {
    return SizedBox(
      width: cellWidth,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: borderColor, width: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: textStyle,
          ),
        ),
      ),
    );
  }

  /// 该周表头的月份文本：与上一周同月且非一号时留空（避免重复）；
  /// 1 月带年份（跨年边界可辨）。
  String _monthLabel(int weekIndex) {
    final start = weekStarts[weekIndex];
    if (weekIndex > 0) {
      final prev = weekStarts[weekIndex - 1];
      if (start.month == prev.month && start.day != 1) return '';
    }
    return start.month == 1
        ? '${start.year}-${start.month}月'
        : '${start.month}月';
  }

  /// ISO 8601 周序号：周四所在的周为当年第几周。
  static int _isoWeekOf(DateTime date) {
    final thursday = date.add(Duration(days: 3 - ((date.weekday + 6) % 7)));
    final jan1 = DateTime(thursday.year, 1, 1);
    final firstThursday = jan1.add(Duration(days: (11 - jan1.weekday) % 7));
    return 1 + (thursday.difference(firstThursday).inDays ~/ 7);
  }

  /// 单个目标行：每周一格。
  Widget _goalRow({
    required Goal goal,
    required GoalGanttRow row,
    required int maxMinutes,
    required Color borderColor,
    required double cellWidth,
    required double rowHeight,
    required double barMaxHeight,
  }) {
    return SizedBox(
      height: rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var w = 0; w < weekStarts.length; w++)
            _weekCell(
              weekStart: weekStarts[w],
              planned: row.planned[w],
              completed: row.completed[w],
              maxMinutes: maxMinutes,
              borderColor: borderColor,
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              barMaxHeight: barMaxHeight,
            ),
        ],
      ),
    );
  }

  /// 单周格：右/下分隔线构成网格线；有数据为双段条形，无数据为空档圆点。
  ///
  /// 条形宽度随格宽自适应（格宽 − 间隙，每侧留 2px），居中排布，
  /// 宽屏拉伸时条形同步变宽；条形高度随行高增长（窗口越高条形越高）。
  Widget _weekCell({
    required DateTime weekStart,
    required int planned,
    required int completed,
    required int maxMinutes,
    required Color borderColor,
    required double cellWidth,
    required double rowHeight,
    required double barMaxHeight,
  }) {
    final total = planned + completed;
    final dateStr = DateFormat('yyyy-MM-dd').format(weekStart);
    final tooltip = _tooltipText(dateStr, planned, completed);
    final barWidth = cellWidth - _cellGap;
    final barMinHeight = 4.0;

    return SizedBox(
      width: cellWidth,
      height: rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: borderColor, width: 0.5),
            bottom: BorderSide(color: borderColor, width: 0.5),
          ),
        ),
        child: Tooltip(
          message: tooltip,
          child: Semantics(
            // 屏幕阅读器可读（NFR-4）：周起始 + 计划/完成时长。
            label: tooltip,
            child: Padding(
              padding: EdgeInsets.only(
                top: rowHeight - barMaxHeight - 6,
                bottom: 6,
              ),
              child: Center(
                child: SizedBox(
                  height: barMaxHeight,
                  width: barWidth,
                  child: total <= 0
                      // 无数据周：仅留占位圆点，保持网格对齐。
                      ? Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: 4,
                            height: barMinHeight,
                            decoration: BoxDecoration(
                              color: borderColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (planned > 0)
                              Container(
                                width: barWidth,
                                height:
                                    _heightFor(planned, maxMinutes, barMaxHeight),
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
                                width: barWidth,
                                height: _heightFor(
                                    completed, maxMinutes, barMaxHeight),
                                decoration: const BoxDecoration(
                                  color: _GanttSection._doneColor,
                                  borderRadius: BorderRadius.only(
                                    bottomLeft: Radius.circular(3),
                                    bottomRight: Radius.circular(3),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
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

  /// 条形高度：按时长占比线性映射到 `[0, barMaxHeight - barMinHeight]`。
  ///
  /// 最忙周两段高度之和恰为 `barMaxHeight - barMinHeight`，配合外层
  /// `Padding(top: rowHeight - barMaxHeight - 6)` 顶部留白，不溢出。
  static double _heightFor(
    int minutes,
    int maxMinutes,
    double barMaxHeight,
  ) {
    if (minutes <= 0) return 0;
    return (minutes / maxMinutes) * (barMaxHeight - 4);
  }
}
