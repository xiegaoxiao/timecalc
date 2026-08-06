import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/clock_provider.dart';
import '../../../services/load_service.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/quick_task_form_dialog.dart';
import '../../tasks/presentation/task_tile.dart';

/// 日历视图（FR-3.4）：月历网格 + 选日任务面板。
///
/// - 网格展示每日任务数（已完成/总数）、预估时长与「超出 Y 分钟」；
/// - 无任务日期保持中性（不显示过载或 0/0）；
/// - 计划偏好的不可用星期置灰；
/// - 点击日期在下方面板展示当日任务，可完成/编辑/延期/删除与添加
///   （FR-3.2；FR-3.6 历史日期补录顺带覆盖）。
class CalendarView extends ConsumerStatefulWidget {
  const CalendarView({super.key});

  @override
  ConsumerState<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends ConsumerState<CalendarView> {
  static const _load = LoadService();

  late DateTime _month; // 年/月（day 固定 1）
  late String _selectedDate; // yyyy-MM-dd

  @override
  void initState() {
    super.initState();
    final today = ref.read(clockProvider)();
    _month = DateTime(today.year, today.month);
    _selectedDate = DateFormat('yyyy-MM-dd').format(today);
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(clockProvider)();
    final todayStr = DateFormat('yyyy-MM-dd').format(today);
    final monthKey = '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

    final goalsAsync = ref.watch(goalListProvider);
    final settingsAsync = ref.watch(settingsProvider);
    final tasksAsync = ref.watch(tasksByMonthProvider(monthKey));
    final selectedTasksAsync = ref.watch(tasksByDateProvider(_selectedDate));

    return goalsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('加载失败：$error')),
      data: (goals) => settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (settings) => tasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('加载失败：$error')),
          data: (monthTasks) => selectedTasksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('加载失败：$error')),
            data: (selectedTasks) {
              void onChanged() {
                // 日历月视图、选日列表、今日页与目标详情统一刷新，保证
                // 跨页数据一致（FR-3 验收）。family 级 invalidate 覆盖
                // 所有日期/月份实例。
                ref.invalidate(tasksByMonthProvider);
                ref.invalidate(tasksByDateProvider);
                ref.invalidate(taskListProvider);
                ref.invalidate(unfinishedBeforeProvider);
                ref.invalidate(goalListProvider);
                ref.invalidate(completedTasksProvider);
                ref.invalidate(allTodoTasksProvider);
              }

              final activeGoals = goals
                  .where((g) =>
                      g.status != 'completed' &&
                      g.status != 'abandoned' &&
                      g.status != 'archived')
                  .toList();
              final addGoals = activeGoals.isNotEmpty ? activeGoals : goals;
              final goalsById = {for (final g in goals) g.id: g};
              final weekdays = SettingsRepository.decodeWeekdays(
                settings.availableWeekdays,
              );
              final aggregate = _load.calendarAggregate(
                tasks: monthTasks,
                availableMinutes: settings.dailyAvailableMinutes,
                availableWeekdays: weekdays,
              );

              // SingleChildScrollView：网格与选日面板全部构建（日历面板
              // 体积有限，避免 ListView 懒加载导致面板在窄屏被裁剪）。
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MonthHeader(
                    month: _month,
                    isCurrentMonth: todayStr.startsWith(monthKey),
                    onPrev: () => setState(() {
                      _month = DateTime(_month.year, _month.month - 1);
                    }),
                    onNext: () => setState(() {
                      _month = DateTime(_month.year, _month.month + 1);
                    }),
                    onBackToToday: () => setState(() {
                      _month = DateTime(today.year, today.month);
                      _selectedDate = todayStr;
                    }),
                  ),
                  const SizedBox(height: 8),
                  _MonthGrid(
                    month: _month,
                    todayStr: todayStr,
                    selectedDate: _selectedDate,
                    weekdays: weekdays,
                    aggregate: aggregate,
                    onSelect: (dateStr) =>
                        setState(() => _selectedDate = dateStr),
                  ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          DateFormat('yyyy-MM-dd EEEE', 'zh_CN')
                              .format(_parseDate(_selectedDate)),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: addGoals.isEmpty
                            ? null
                            : () async {
                                await QuickTaskFormDialog.show(
                                  context,
                                  date: _parseDate(_selectedDate),
                                  goals: addGoals,
                                );
                                onChanged();
                              },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加任务'),
                      ),
                    ],
                  ),
                  if (selectedTasks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('这一天没有任务'),
                    )
                  else
                    for (final task in selectedTasks)
                      TaskTile(
                        task: task,
                        goalTitle: goalsById[task.goalId]?.title,
                        onChanged: onChanged,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}

/// 月份切换头部：上一月 / 标题（当前月份显示「回到今天」）/ 下一月。
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.isCurrentMonth,
    required this.onPrev,
    required this.onNext,
    required this.onBackToToday,
  });

  final DateTime month;
  final bool isCurrentMonth;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onBackToToday;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: '上一月',
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            '${month.year}年${month.month}月',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (!isCurrentMonth)
          TextButton(onPressed: onBackToToday, child: const Text('回到今天')),
        IconButton(
          tooltip: '下一月',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// 手写月历网格（周一开头，PRD §7 日历视图）。
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.todayStr,
    required this.selectedDate,
    required this.weekdays,
    required this.aggregate,
    required this.onSelect,
  });

  final DateTime month;
  final String todayStr;
  final String selectedDate;
  final Set<int> weekdays;
  final Map<String, DayAggregate> aggregate;
  final ValueChanged<String> onSelect;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// 紧凑时长（日历格空间有限）：120 → '2h'，90 → '1h30'，30 → '30m'。
  static String _compactDuration(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '${rest}m';
    if (rest == 0) return '${hours}h';
    return '${hours}h${rest}m';
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday;
    final leadingBlanks = firstWeekday - 1; // 周一开头
    final totalCells = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;

    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Row(
          children: [
            for (final label in _weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(label, style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var row = 0; row < totalCells ~/ 7; row++) ...[
          Row(
            children: [
              for (var col = 0; col < 7; col++) ...[
                Expanded(
                  child: _buildCell(
                    context,
                    scheme,
                    day: row * 7 + col + 1 - leadingBlanks,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  Widget _buildCell(BuildContext context, ColorScheme scheme, {required int day}) {
    if (day < 1 || day > DateTime(month.year, month.month + 1, 0).day) {
      return const SizedBox(height: 80);
    }
    final date = DateTime(month.year, month.month, day);
    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final agg = aggregate[dateStr] ?? DayAggregate.empty;
    final isAvailable = weekdays.contains(date.weekday);
    final isToday = dateStr == todayStr;
    final isSelected = dateStr == selectedDate;

    final textColor = isAvailable
        ? scheme.onSurface
        : scheme.outlineVariant;
    final background = isSelected
        ? scheme.secondaryContainer
        : (isToday ? scheme.primaryContainer : scheme.surfaceContainerLow);

    return InkWell(
      onTap: () => onSelect(dateStr),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$day',
              style: TextStyle(
                color: isToday ? scheme.primary : textColor,
                fontWeight: isToday ? FontWeight.bold : null,
              ),
            ),
            if (agg.totalCount > 0) ...[
              Text(
                '${agg.doneCount}/${agg.totalCount}',
                style: TextStyle(fontSize: 11, color: textColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _compactDuration(agg.loadMinutes),
                style: TextStyle(fontSize: 11, color: textColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (agg.overMinutes > 0)
                Text(
                  '超出${_compactDuration(agg.overMinutes)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
