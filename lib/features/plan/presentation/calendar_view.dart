import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/load_service.dart';
import '../../../shared/widgets/app_error_view.dart';
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
      error: (error, _) => AppErrorView(
        error: error,
        onRetry: () => ref.invalidate(goalListProvider),
      ),
      data: (goals) => settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(settingsProvider),
        ),
        data: (settings) => tasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppErrorView(
            error: error,
            onRetry: () => ref.invalidate(tasksByMonthProvider),
          ),
          data: (monthTasks) => selectedTasksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppErrorView(
              error: error,
              onRetry: () => ref.invalidate(tasksByDateProvider),
            ),
            data: (selectedTasks) {
              void onChanged() => _invalidateAll();

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
                    // FR-5.1：把任务拖到某一天改期。
                    onDropTask: (task, date) => _handleTaskDropped(task, date),
                  ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          DateFormat('yyyy-MM-dd EEEE', 'zh_CN')
                              .format(parseLocalDate(_selectedDate)),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: addGoals.isEmpty
                            ? null
                            : () async {
                                await QuickTaskFormDialog.show(
                                  context,
                                  date: parseLocalDate(_selectedDate),
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
                      // FR-5.1：长按任务条目即可拖动到网格中的目标日期改期。
                      LongPressDraggable<Task>(
                        data: task,
                        feedback: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              task.title,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        childWhenDragging: Opacity(
                          opacity: 0.4,
                          child: TaskTile(
                            task: task,
                            goalTitle: goalsById[task.goalId]?.title,
                            onChanged: onChanged,
                          ),
                        ),
                        child: TaskTile(
                          task: task,
                          goalTitle: goalsById[task.goalId]?.title,
                          onChanged: onChanged,
                        ),
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

  /// 数据变更后的统一刷新（FR-3 验收：日历月视图、选日列表、今日页与
  /// 目标详情在同一操作周期内同步更新）。公共集合见 invalidateAppData
  /// （P3 收敛）。
  void _invalidateAll() => invalidateAppData(ref);

  /// FR-5.1：任务被拖到某一天（网格 DragTarget 命中）时改期。
  ///
  /// - 已完成任务不拖动改期（拖动语义为「重新安排未完成任务」）；
  /// - 复用 [TaskRepository.defer] 改期并记录原计划日期（FR-3.3 验收）；
  /// - 写入失败（数据库异常）时弹错误对话框，任务保持原日期；
  /// - 成功后在 [onChanged] 中统一刷新跨页缓存。
  Future<void> _handleTaskDropped(Task task, String date) async {
    if (task.status == TaskStatus.done) return;
    if (task.plannedDate == date) return; // 同一天：无操作
    final ok = await runDbAction(
      context,
      action: () => ref.read(taskRepositoryProvider).defer(task.id, date),
    );
    if (!ok) return;
    _invalidateAll();
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
    this.onDropTask,
  });

  final DateTime month;
  final String todayStr;
  final String selectedDate;
  final Set<int> weekdays;
  final Map<String, DayAggregate> aggregate;
  final ValueChanged<String> onSelect;

  /// FR-5.1：任务拖到某一天改期（为空则不接受放置）。
  final void Function(Task task, String date)? onDropTask;

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

    // 屏幕阅读器可读的单元格描述（NFR-4）：日期 + 完成数/总数 + 时长，
    // 超载时带「超出」文本，状态不只依赖颜色。
    final label = StringBuffer('$dateStr，完成 ${agg.doneCount}/${agg.totalCount}');
    if (agg.loadMinutes > 0) {
      label.write('，时长 ${_compactDuration(agg.loadMinutes)}');
    }
    if (agg.overMinutes > 0) {
      label.write('，超出 ${_compactDuration(agg.overMinutes)}');
    }

    final cell = Semantics(
      label: label.toString(),
      button: true,
      child: InkWell(
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 非颜色状态（NFR-4）：超载格在红色文本外附警告图标。
                      Icon(Icons.warning_amber_rounded,
                          size: 11, color: scheme.error),
                      const SizedBox(width: 2),
                      Flexible(
                        child: Text(
                          '超出${_compactDuration(agg.overMinutes)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ),
      ),
    );

    final drop = onDropTask;
    if (drop == null) return cell;
    // FR-5.1：网格格作为 DragTarget，接受从选日面板拖来的任务改期。
    // 拖动悬停时高亮边框；放置失败（数据库异常）时任务保持原日期。
    return DragTarget<Task>(
      onWillAcceptWithDetails: (details) => details.data.status != TaskStatus.done,
      onAcceptWithDetails: (details) => drop(details.data, dateStr),
      builder: (context, candidate, rejected) => DecoratedBox(
        decoration: candidate.isNotEmpty
            ? BoxDecoration(
                border: Border.all(color: scheme.primary, width: 2),
                borderRadius: BorderRadius.circular(8),
              )
            : const BoxDecoration(),
        child: cell,
      ),
    );
  }
}
