import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/load_service.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/quick_task_form_dialog.dart';
import '../../tasks/presentation/task_tile.dart';

/// 选日面板标题（含星期，中文），复用单一实例避免每帧重建 DateFormat。
final _dayLabelFormat = DateFormat('yyyy-MM-dd EEEE', 'zh_CN');

/// 日历视图模式（周 / 月 / 年）。
enum CalendarViewMode { week, month, year }

/// 日历视图（FR-3.4）：周/月/年网格 + 选日任务面板。
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

  late CalendarViewMode _mode; // 周/月/年视图
  late DateTime _month; // 年/月（day 固定 1）
  late DateTime _weekStart; // 周一（周视图）
  late int _year; // 年视图
  late String _selectedDate; // yyyy-MM-dd
  late bool _monthHideCompleted; // 月视图：隐藏已完成任务

  @override
  void initState() {
    super.initState();
    final today = ref.read(clockProvider)();
    _mode = CalendarViewMode.month; // 默认月视图（与现状一致）
    _month = DateTime(today.year, today.month);
    _weekStart = _mondayOf(today);
    _year = today.year;
    _selectedDate = formatLocalDate(today);
    _monthHideCompleted = false;
  }

  /// 所在周的周一（周一开头，与网格一致）。
  static DateTime _mondayOf(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    // 纯日历加法（date_text）：Duration(days:) 在夏令时切换日偏移一小时，
    // 周起点可能落到相邻日期（与 ganttWeekStarts/recentWeekStarts 同口径，
    // 2026-08-14 审查 #3）。
    return addLocalDays(day, -(day.weekday - 1));
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(clockProvider)();
    final todayStr = formatLocalDate(today);
    final monthKey =
        '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
    final weekKey = formatLocalDate(_weekStart);

    final goalsAsync = ref.watch(goalListProvider);
    final settingsAsync = ref.watch(settingsProvider);
    final selectedTasksAsync = ref.watch(tasksByDateProvider(_selectedDate));

    // 核心数据（目标/设置）：仅首次加载或出错时整页占位；此后刷新期间
    // valueOrNull 保留旧值继续渲染，不再整页塌陷（去闪烁核心）。
    final goals = goalsAsync.valueOrNull;
    final settings = settingsAsync.valueOrNull;
    if (goals == null || settings == null) {
      if (goalsAsync.hasError || settingsAsync.hasError) {
        return AppErrorView(
          error:
              goalsAsync.hasError ? goalsAsync.error! : settingsAsync.error!,
          onRetry: () {
            ref.invalidate(goalListProvider);
            ref.invalidate(settingsProvider);
          },
        );
      }
      return PageSkeletons.cardColumn(count: 3, height: 220);
    }

    void onChanged() => _invalidateAll();

    final activeGoals = goals
        .where(
          (g) =>
              g.status != 'completed' &&
              g.status != 'abandoned' &&
              g.status != 'archived',
        )
        .toList();
    final addGoals = activeGoals.isNotEmpty ? activeGoals : goals;
    final goalsById = {for (final g in goals) g.id: g};
    final weekdays = SettingsRepository.decodeWeekdays(
      settings.availableWeekdays,
    );
    // 只 watch / 只聚合当前视图的数据族（2026-08-15 性能优化）：此前月视图
    // 也 watch 周/年并计算全部三个聚合，勾选任务失效后连带重查/重建无关数据。
    // 刷新期间 valueOrNull 保留旧值，网格始终渲染不塌陷。
    final AsyncValue<List<Task>> viewTasksAsync;
    final Map<String, DayAggregate> gridAggregate;
    final Map<String, List<Task>> weekTasksByDate;
    final Map<String, int> yearMonthCounts;
    switch (_mode) {
      case CalendarViewMode.month:
        {
          viewTasksAsync = ref.watch(tasksByMonthProvider(monthKey));
          gridAggregate = _load.calendarAggregate(
            tasks: _monthHideCompleted
                ? (viewTasksAsync.valueOrNull ?? const <Task>[])
                    .where((t) => t.status != TaskStatus.done)
                    .toList()
                : (viewTasksAsync.valueOrNull ?? const <Task>[]),
            availableMinutes: settings.dailyAvailableMinutes,
            availableWeekdays: weekdays,
          );
          weekTasksByDate = const {};
          yearMonthCounts = const {};
          break;
        }
      case CalendarViewMode.week:
        {
          viewTasksAsync = ref.watch(tasksByWeekProvider(weekKey));
          weekTasksByDate = _groupTasksByDate(
            viewTasksAsync.valueOrNull ?? const <Task>[],
          );
          gridAggregate = _load.calendarAggregate(
            tasks: viewTasksAsync.valueOrNull ?? const <Task>[],
            availableMinutes: settings.dailyAvailableMinutes,
            availableWeekdays: weekdays,
          );
          yearMonthCounts = const {};
          break;
        }
      case CalendarViewMode.year:
        {
          viewTasksAsync = ref.watch(tasksByYearProvider(_year));
          // 年视图月完成数：按 completedAt 归月（口径与进度页热力图一致）。
          const stats = StatisticsService();
          yearMonthCounts = stats.completedCountsByMonth(
            viewTasksAsync.valueOrNull ?? const <Task>[],
          );
          gridAggregate = const {};
          weekTasksByDate = const {};
          break;
        }
    }

    // 选日任务的科目名：父级一次性预取（按 goalId 去重），避免每个 TaskTile
    // 各自 watch(subjectListProvider) + 线性扫描（N+1）。
    final selectedTasks = selectedTasksAsync.valueOrNull ?? const <Task>[];
    final subjectsByGoal = <int, List<Subject>>{
      for (final gid in {for (final t in selectedTasks) t.goalId})
        gid:
            ref.watch(subjectListProvider(gid)).valueOrNull ?? const <Subject>[],
    };

    // 头部标题与前后切换单位（随视图模式变化）。
    final (title, isCurrent, onPrev, onNext, onBackToToday) = switch (_mode) {
      CalendarViewMode.month => (
          '${_month.year}年${_month.month}月',
          todayStr.startsWith(monthKey),
          () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
          () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
          () => setState(() {
            _month = DateTime(today.year, today.month);
            _selectedDate = todayStr;
          }),
        ),
      CalendarViewMode.week => (
          _weekTitle(_weekStart),
          todayStr == weekKey,
          () => setState(() => _weekStart = addLocalDays(_weekStart, -7)),
          () => setState(() => _weekStart = addLocalDays(_weekStart, 7)),
          () => setState(() {
            _weekStart = _mondayOf(today);
            _selectedDate = todayStr;
          }),
        ),
      CalendarViewMode.year => (
          '$_year年',
          _year == today.year,
          () => setState(() => _year--),
          () => setState(() => _year++),
          () => setState(() {
            _year = today.year;
            _selectedDate = todayStr;
          }),
        ),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CalendarHeader(
            mode: _mode,
            title: title,
            isCurrent: isCurrent,
            onModeChanged: (m) => setState(() => _mode = m),
            onPrev: onPrev,
            onNext: onNext,
            onBackToToday: onBackToToday,
            hideCompleted: _monthHideCompleted,
            onHideCompletedChanged: _mode == CalendarViewMode.month
                ? (value) => setState(() => _monthHideCompleted = value)
                : null,
          ),
          const SizedBox(height: 8),
          // 当前视图数据加载/出错：网格区顶部细进度条或局部错误提示，
          // 不整页塌陷。
          if (_viewTasks().isEmpty)
            if (_viewAsync().hasError)
              _SectionError(
                error: _viewAsync().error!,
                onRetry: () {
                  // 按当前视图失效对应数据族（family 无参整族失效）。
                  switch (_mode) {
                    case CalendarViewMode.month:
                      ref.invalidate(tasksByMonthProvider);
                    case CalendarViewMode.week:
                      ref.invalidate(tasksByWeekProvider);
                    case CalendarViewMode.year:
                      ref.invalidate(tasksByYearProvider);
                  }
                },
              )
            else if (_viewAsync().isLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          // 视图/单元切换淡入淡出（keyed by 视图+单元；刷新原位更新，
          // 不触发动画）。过渡期新旧两份网格各自成层（RepaintBoundary）：
          // 淡入淡出只做图层合成，不逐帧重绘整棵子树（2026-08-16 优化）。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: RepaintBoundary(child: child),
            ),
            child: switch (_mode) {
              CalendarViewMode.month => _MonthGrid(
                  key: ValueKey('month-$monthKey'),
                  month: _month,
                  todayStr: todayStr,
                  selectedDate: _selectedDate,
                  weekdays: weekdays,
                  aggregate: gridAggregate,
                  onSelect: (dateStr) =>
                      setState(() => _selectedDate = dateStr),
                  // FR-5.1：把任务拖到某一天改期。
                  onDropTask: (task, date) => _handleTaskDropped(task, date),
                ),
              CalendarViewMode.week => _WeekGrid(
                  key: ValueKey('week-$weekKey'),
                  weekStart: _weekStart,
                  todayStr: todayStr,
                  selectedDate: _selectedDate,
                  weekdays: weekdays,
                  aggregate: gridAggregate,
                  // 周视图格内直接展示当日任务条（与月视图的聚合数字区分：
                  // 周视图的价值是「一周安排一览」，而非仅负载概览）。
                  tasksByDate: weekTasksByDate,
                  onSelect: (dateStr) =>
                      setState(() => _selectedDate = dateStr),
                  onDropTask: (task, date) => _handleTaskDropped(task, date),
                ),
              CalendarViewMode.year => _YearGrid(
                  key: ValueKey('year-$_year'),
                  year: _year,
                  todayStr: todayStr,
                  monthCounts: yearMonthCounts,
                  onSelectMonth: (month) => setState(() {
                    _mode = CalendarViewMode.month;
                    _month = DateTime(_year, month);
                  }),
                ),
            },
          ),
          const Divider(height: 32),
          // 选日面板：换日淡入淡出（keyed by date），加载/错误只影响面板区。
          // 新旧面板同样各自成层（与上方视图切换同口径）。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: RepaintBoundary(child: child),
            ),
            child: _DayPanel(
              key: ValueKey(_selectedDate),
              dateLabel: _dayLabelFormat.format(parseLocalDate(_selectedDate)),
              selectedTasksAsync: selectedTasksAsync,
              goalsById: goalsById,
              subjectsByGoal: subjectsByGoal,
              onChanged: onChanged,
              // 无可归属目标时不提供「添加任务」（头部按钮 + 空态 CTA 共用）。
              onAddTask: addGoals.isEmpty
                  ? null
                  : () async {
                      await QuickTaskFormDialog.show(
                        context,
                        date: parseLocalDate(_selectedDate),
                        goals: addGoals,
                      );
                      onChanged();
                    },
              onRetryTasks: () => ref.invalidate(tasksByDateProvider),
            ),
          ),
        ],
      ),
    );
  }

  /// 任务按计划日期分组（周视图格内任务条用）。
  static Map<String, List<Task>> _groupTasksByDate(List<Task> tasks) {
    final map = <String, List<Task>>{};
    for (final t in tasks) {
      map.putIfAbsent(t.plannedDate, () => []).add(t);
    }
    return map;
  }

  /// 当前视图的标题：周视图显示「8 月 25 日 – 31 日 · 第 34 周」。
  String _weekTitle(DateTime monday) {
    final sunday = addLocalDays(monday, 6);
    final sameMonth = monday.month == sunday.month;
    // 一年中的第几周（ISO 周数，周一为每周第一天）。
    final weekNumber = _isoWeekNumber(monday);
    if (sameMonth) {
      return '${monday.month}月${monday.day}日 – ${sunday.day}日 · '
          '第 $weekNumber 周';
    }
    return '${monday.month}月${monday.day}日 – ${sunday.month}月'
        '${sunday.day}日 · 第 $weekNumber 周';
  }

  /// ISO 周数：本周周四所在年份的第几周。
  static int _isoWeekNumber(DateTime date) {
    // 将日期调整到本周四（ISO 周以周四定义所属年份）。
    // 纯日历加法 + UTC 归一化天数差（2026-08-14 审查 #3/#8）：Duration/本地
    // difference 在 DST 切换日可能差一天，导致跨年周的周号显示偏移。
    final day = DateTime(date.year, date.month, date.day);
    final thursday = addLocalDays(day, 4 - day.weekday);
    final yearStartUtc = DateTime.utc(thursday.year, 1, 1);
    final thursdayUtc = DateTime.utc(
      thursday.year,
      thursday.month,
      thursday.day,
    );
    final dayDiff = thursdayUtc.difference(yearStartUtc).inDays;
    return (dayDiff ~/ 7) + 1;
  }

  /// 当前视图对应的任务列表（加载/聚合共用）。
  List<Task> _viewTasks() => switch (_mode) {
        CalendarViewMode.month =>
          ref.read(tasksByMonthProvider(
            '${_month.year}-${_month.month.toString().padLeft(2, '0')}',
          )).valueOrNull ??
              const <Task>[],
        CalendarViewMode.week =>
          ref.read(tasksByWeekProvider(formatLocalDate(_weekStart)))
                  .valueOrNull ??
              const <Task>[],
        CalendarViewMode.year =>
          ref.read(tasksByYearProvider(_year)).valueOrNull ?? const <Task>[],
      };

  AsyncValue<List<Task>> _viewAsync() => switch (_mode) {
        CalendarViewMode.month => ref.read(
            tasksByMonthProvider(
              '${_month.year}-${_month.month.toString().padLeft(2, '0')}',
            ),
          ),
        CalendarViewMode.week =>
          ref.read(tasksByWeekProvider(formatLocalDate(_weekStart))),
        CalendarViewMode.year => ref.read(tasksByYearProvider(_year)),
      };

  /// 数据变更后的统一刷新：计划页高频任务操作走局部失效（invalidatePlanData，
  /// 2026-08-15 性能优化：不重查目标、补上周/年视图；跨页统计仍一并刷新）。
  void _invalidateAll() => invalidatePlanData(ref);

  /// FR-5.1：任务被拖到某一天（网格 DragTarget 命中）时改期。
  ///
  /// - 已完成任务不拖动改期（拖动语义为「重新安排未完成任务」），落位时
  ///   给出明确提示，不静默忽略；
  /// - 复用 [TaskRepository.defer] 改期并记录原计划日期（FR-3.3 验收）；
  /// - 写入失败（数据库异常）时弹错误对话框，任务保持原日期；
  /// - 成功后在 [onChanged] 中统一刷新跨页缓存。
  Future<void> _handleTaskDropped(Task task, String date) async {
    if (task.status == TaskStatus.done) {
      // L3 修复：此前直接 return 无反馈，用户以为拖放无效。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已完成任务不能拖动改期，请先取消完成再调整日期'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (task.plannedDate == date) return; // 同一天：无操作
    final ok = await runDbAction(
      context,
      action: () => ref.read(taskRepositoryProvider).defer(task.id, date),
    );
    if (!ok) return;
    _invalidateAll();
  }
}

/// 选日面板：日期标题 + 添加任务 + 当日任务列表（或空态/局部加载）。
///
/// 作为 [AnimatedSwitcher] 的子级（keyed by 日期）整体淡入淡出；选日任务
/// 的加载/错误只影响本面板，不塌陷整个日历。
class _DayPanel extends StatelessWidget {
  const _DayPanel({
    super.key,
    required this.dateLabel,
    required this.selectedTasksAsync,
    required this.goalsById,
    required this.subjectsByGoal,
    required this.onChanged,
    required this.onAddTask,
    required this.onRetryTasks,
  });

  final String dateLabel;
  final AsyncValue<List<Task>> selectedTasksAsync;
  final Map<int, Goal> goalsById;
  final Map<int, List<Subject>> subjectsByGoal;
  final VoidCallback onChanged;

  /// 「添加任务」回调（无可归属目标时为 null：头部按钮禁用、空态无 CTA）。
  final Future<void> Function()? onAddTask;
  final VoidCallback onRetryTasks;

  @override
  Widget build(BuildContext context) {
    // 换日/刷新期间 valueOrNull 保留旧值继续展示；仅首次无数据时兜底空表。
    final selectedTasks = selectedTasksAsync.valueOrNull ?? const <Task>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                dateLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: onAddTask,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加任务'),
            ),
          ],
        ),
        // 选日数据局部状态：加载细进度条 / 错误条，均不整页塌陷。
        if (selectedTasks.isEmpty)
          if (selectedTasksAsync.hasError)
            _SectionError(
              error: selectedTasksAsync.error!,
              onRetry: onRetryTasks,
            )
          else if (selectedTasksAsync.isLoading)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else
            // 空态内容横向居中（本列 start 对齐需给全宽）+ 引导 CTA：
            // 「去添加任务」直接点开所选日期的快速添加。
            SizedBox(
              width: double.infinity,
              child: ChartEmptyState(
                icon: Icons.event_outlined,
                title: '这一天没有任务',
                actionLabel: onAddTask == null ? null : '去添加任务',
                onAction: onAddTask,
              ),
            )
        else
          for (final task in selectedTasks)
            // FR-5.1：长按任务条目即可拖动到网格中的目标日期改期。
            // 按任务身份 key 复用 element：勾选/删除导致列表收缩时，
            // 划线/透明度动画不会错播到相邻任务上（幻影动画）。
            LongPressDraggable<Task>(
              key: ValueKey('day-task-${task.id}'),
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
                  subjects: subjectsByGoal[task.goalId],
                  onChanged: onChanged,
                ),
              ),
              child: TaskTile(
                task: task,
                goalTitle: goalsById[task.goalId]?.title,
                subjects: subjectsByGoal[task.goalId],
                onChanged: onChanged,
              ),
            ),
      ],
    );
  }
}

/// 局部错误条（区块级提示，替代整页 AppErrorView）：错误文案 + 重试。
class _SectionError extends StatelessWidget {
  const _SectionError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontSize: 12,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 日历头部：视图切换器（周/月/年）+ 标题 + 上一单元/下一单元 + 回到今天。
class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({
    required this.mode,
    required this.title,
    required this.isCurrent,
    required this.onModeChanged,
    required this.onPrev,
    required this.onNext,
    required this.onBackToToday,
    this.hideCompleted = false,
    this.onHideCompletedChanged,
  });

  final CalendarViewMode mode;
  final String title;
  final bool isCurrent;
  final ValueChanged<CalendarViewMode> onModeChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onBackToToday;

  /// 仅月视图：「隐藏已完成」开关的当前值。
  final bool hideCompleted;

  /// 仅月视图：「隐藏已完成」开关变更回调；非月视图传 null。
  final ValueChanged<bool>? onHideCompletedChanged;

  /// 当前是否为月视图（决定工具是否展示）。
  bool get _isMonthView => onHideCompletedChanged != null;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 第一行：视图切换器（左）+ 月视图工具（中）+ 前后切换（右）。
        Row(
          children: [
            SegmentedButton<CalendarViewMode>(
              segments: const [
                ButtonSegment(
                  value: CalendarViewMode.week,
                  label: Text('周'),
                  icon: Icon(Icons.view_week_outlined),
                ),
                ButtonSegment(
                  value: CalendarViewMode.month,
                  label: Text('月'),
                  icon: Icon(Icons.calendar_month_outlined),
                ),
                ButtonSegment(
                  value: CalendarViewMode.year,
                  label: Text('年'),
                  icon: Icon(Icons.calendar_view_month_outlined),
                ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  onModeChanged(selection.first),
            ),
            // 月视图专属：隐藏已完成开关。
            if (mode == CalendarViewMode.month && _isMonthView) ...[
              const SizedBox(width: 8),
              _HideCompletedChip(
                value: hideCompleted,
                onChanged: onHideCompletedChanged!,
              ),
            ],
            const Spacer(),
            IconButton(
              tooltip: '上一单元',
              onPressed: onPrev,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: '下一单元',
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        // 第二行：标题 + 回到今天。
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (!isCurrent)
              FilledButton.tonal(
                onPressed: onBackToToday,
                child: const Text('回到今天'),
              )
            else
              // 当前单元也保留占位，避免标题行高度跳动。
              const SizedBox.shrink(),
          ],
        ),
      ],
    );
  }
}

/// 「隐藏已完成」开关小_chip。
class _HideCompletedChip extends StatelessWidget {
  const _HideCompletedChip({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        value ? Icons.check_box : Icons.check_box_outline_blank,
        size: 18,
        color: value ? scheme.primary : scheme.onSurfaceVariant,
      ),
      label: const Text('隐藏已完成'),
      labelStyle: const TextStyle(fontSize: 12),
      padding: EdgeInsets.zero,
      side: BorderSide.none,
      backgroundColor:
          value ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      onPressed: () => onChanged(!value),
    );
  }
}

/// 手写月历网格（周一开头，PRD §7 日历视图）。
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    super.key,
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

  /// 本月天数（L5：build 与逐格判定共用，避免每格重复计算）。
  int get _daysInMonth => DateTime(month.year, month.month + 1, 0).day;

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
    final daysInMonth = _daysInMonth;
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
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
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

  Widget _buildCell(
    BuildContext context,
    ColorScheme scheme, {
    required int day,
  }) {
    if (day < 1 || day > _daysInMonth) {
      return const SizedBox(height: 80);
    }
    final warning = AppSemanticColors.of(context).warning;
    final date = DateTime(month.year, month.month, day);
    final dateStr = formatLocalDate(date);
    final agg = aggregate[dateStr] ?? DayAggregate.empty;
    final isAvailable = weekdays.contains(date.weekday);
    final isToday = dateStr == todayStr;
    final isSelected = dateStr == selectedDate;
    final hasTask = agg.totalCount > 0;

    // 三态视觉优先级（选中 > 今天 > 有任务；NFR-4 不只依赖颜色，多重表达）：
    // - 选中：最深最饱满的主色实心块（onPrimary 白字），表意优先级最高；
    // - 今天（未选中）：与普通格同底 + 主色描边 + 主色粗体日号，不占大块
    //   填充，避免「今天」抢过「选中」的风头；
    // - 有任务：日期数字旁主色小圆点（选中时用 onPrimary 保证对比度）。
    final baseTextColor =
        isAvailable ? scheme.onSurface : scheme.outlineVariant;
    final textColor = isSelected
        ? scheme.onPrimary
        : (isToday ? scheme.primary : baseTextColor);
    final background = isSelected
        ? scheme.primary
        : scheme.surfaceContainerLow;
    // 今天描边：仅未选中时渲染——选中已是主色实块，叠加同色描边无意义。
    final border = isToday && !isSelected
        ? Border.all(color: scheme.primary, width: 1.5)
        : null;
    final dotColor = isSelected ? scheme.onPrimary : scheme.primary;

    // 屏幕阅读器可读的单元格描述（NFR-4）：日期 + 完成数/总数 + 时长，
    // 超载时带「超出」文本，状态不只依赖颜色。
    final label = StringBuffer(
      '$dateStr，完成 ${agg.doneCount}/${agg.totalCount}',
    );
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
            border: border,
          ),
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$day',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: isToday ? FontWeight.bold : null,
                    ),
                  ),
                  // 有任务圆点：日期数字右侧的主色小点，一眼可辨「这天有安排」
                  // （占用同行空间，不挤压格子下方计数内容）。
                  if (hasTask) ...[
                    const SizedBox(width: 4),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              if (agg.totalCount > 0) ...[
                const SizedBox(height: 2),
                // 小型完成进度条：直观展示当天完成比例。
                _MonthDayProgressBar(
                  done: agg.doneCount,
                  total: agg.totalCount,
                  color: textColor,
                ),
                const SizedBox(height: 4),
                // 时长与超载信息。
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        _compactDuration(agg.loadMinutes),
                        style: TextStyle(fontSize: 10, color: textColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (agg.overMinutes > 0)
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 10,
                              color: warning,
                            ),
                            Flexible(
                              child: Text(
                                _compactDuration(agg.overMinutes),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: warning,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
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
      onWillAcceptWithDetails: (details) =>
          details.data.status != TaskStatus.done,
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

/// 月视图日格完成进度条：细条形，已完成比例一目了然。
///
/// 全部完成时显示勾选徽标而非实心条，避免 100% 时前景与背景融为一条
/// 粗黑线（withValues alpha 仅 0.2，但颜色饱和度高时仍显脏）。
class _MonthDayProgressBar extends StatelessWidget {
  const _MonthDayProgressBar({
    required this.done,
    required this.total,
    required this.color,
  });

  final int done;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAllDone = total > 0 && done >= total;
    if (isAllDone) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 11, color: scheme.primary),
          const SizedBox(width: 3),
          Text(
            '完成',
            style: TextStyle(fontSize: 10, color: scheme.primary),
          ),
        ],
      );
    }

    final fraction = total == 0 ? 0.0 : done / total;
    return Container(
      height: 4,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.centerLeft,
      clipBehavior: Clip.antiAlias,
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: fraction,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// 周视图网格（格子样式）：7 列（周一~周日）× 1 行，展示当周每日任务。
///
/// 单元格视觉与 [_MonthGrid] 完全一致（三态/置灰/负载聚合），仅网格为
/// 当周 7 天；跨月的周正常显示相邻月日期号（不加灰）。
class _WeekGrid extends StatelessWidget {
  const _WeekGrid({
    super.key,
    required this.weekStart,
    required this.todayStr,
    required this.selectedDate,
    required this.weekdays,
    required this.aggregate,
    required this.tasksByDate,
    required this.onSelect,
    this.onDropTask,
  });

  final DateTime weekStart; // 周一
  final String todayStr;
  final String selectedDate;
  final Set<int> weekdays;
  final Map<String, DayAggregate> aggregate;
  final Map<String, List<Task>> tasksByDate;
  final ValueChanged<String> onSelect;
  final void Function(Task task, String date)? onDropTask;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// 单个格子最多展示的任务条数。
  static const int _maxTaskPills = 3;

  /// 任务条高度（含上下 margin）。
  static const double _pillHeight = 18;

  /// 紧凑时长（与月网格同口径）。
  static String _compactDuration(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '${rest}m';
    if (rest == 0) return '${hours}h';
    return '${hours}h${rest}m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 星期表头。
        Row(
          children: [
            for (final label in _weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        // 7 天格子：固定高度以容纳任务条预览。
        SizedBox(
          height: 180,
          child: Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: _buildCell(
                    context,
                    scheme,
                    // 纯日历加法（date_text）：防 DST 切换日周格日期错位
                    // （2026-08-14 审查 #3）。
                    date: addLocalDays(weekStart, col),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCell(
    BuildContext context,
    ColorScheme scheme, {
    required DateTime date,
  }) {
    final dateStr = formatLocalDate(date);
    final agg = aggregate[dateStr] ?? DayAggregate.empty;
    final isAvailable = weekdays.contains(date.weekday);
    final isToday = dateStr == todayStr;
    final isSelected = dateStr == selectedDate;
    final hasTask = agg.totalCount > 0;

    // 三态视觉优先级（选中 > 今天 > 有任务；NFR-4 不只依赖颜色）：
    // 与月网格完全一致（选中主色实心块、今天描边+粗体、有任务圆点）。
    final baseTextColor =
        isAvailable ? scheme.onSurface : scheme.outlineVariant;
    final textColor = isSelected
        ? scheme.onPrimary
        : (isToday ? scheme.primary : baseTextColor);
    final background = isSelected
        ? scheme.primary
        : scheme.surfaceContainerLow;
    final border = isToday && !isSelected
        ? Border.all(color: scheme.primary, width: 1.5)
        : null;
    final dotColor = isSelected ? scheme.onPrimary : scheme.primary;

    // 屏幕阅读器可读的单元格描述（NFR-4）：日期 + 完成数/总数 + 时长。
    final label = StringBuffer(
      '$dateStr，完成 ${agg.doneCount}/${agg.totalCount}',
    );
    if (agg.loadMinutes > 0) {
      label.write('，时长 ${_compactDuration(agg.loadMinutes)}');
    }
    if (agg.overMinutes > 0) {
      label.write('，超出 ${_compactDuration(agg.overMinutes)}');
    }

    final dayTasks = tasksByDate[dateStr] ?? const <Task>[];

    final cell = Semantics(
      label: label.toString(),
      button: true,
      child: InkWell(
        onTap: () => onSelect(dateStr),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 170,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
            border: border,
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 日期行 + 完成进度徽标。
              Row(
                children: [
                  Text(
                    '${date.day}',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: isToday ? FontWeight.bold : null,
                    ),
                  ),
                  if (hasTask) ...[
                    const SizedBox(width: 4),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (agg.totalCount > 0)
                    _CompletionBadge(
                      done: agg.doneCount,
                      total: agg.totalCount,
                      color: textColor,
                    ),
                ],
              ),
              // 任务条预览（周视图核心价值）。
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _TaskPills(
                    tasks: dayTasks,
                    textColor: textColor,
                  ),
                ),
              ),
              // 底部负载/超载信息条。
              if (agg.totalCount > 0)
                _DayLoadBar(aggregate: agg, textColor: textColor),
            ],
          ),
        ),
      ),
    );

    final drop = onDropTask;
    if (drop == null) return cell;
    return DragTarget<Task>(
      onWillAcceptWithDetails: (details) =>
          details.data.status != TaskStatus.done,
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

/// 完成进度徽标（e.g. 2/5）。
class _CompletionBadge extends StatelessWidget {
  const _CompletionBadge({
    required this.done,
    required this.total,
    required this.color,
  });

  final int done;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$done/$total',
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 任务条预览：最多展示 [_WeekGrid._maxTaskPills] 条，超出显示 "+n"。
class _TaskPills extends StatelessWidget {
  const _TaskPills({
    required this.tasks,
    required this.textColor,
  });

  final List<Task> tasks;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = tasks.take(_WeekGrid._maxTaskPills).toList();
    final overflow = tasks.length - display.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final task in display)
          Container(
            height: _WeekGrid._pillHeight - 2,
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: task.status == TaskStatus.done
                  ? scheme.surfaceContainerHighest
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(
                  task.status == TaskStatus.done
                      ? Icons.check_circle
                      : Icons.circle,
                  size: 8,
                  color: task.status == TaskStatus.done
                      ? scheme.outline
                      : scheme.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    task.title,
                    style: TextStyle(
                      fontSize: 10,
                      color: textColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (overflow > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '+$overflow 项',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// 底部负载信息条：时长 + 超载提示（如存在）。
class _DayLoadBar extends StatelessWidget {
  const _DayLoadBar({
    required this.aggregate,
    required this.textColor,
  });

  final DayAggregate aggregate;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final warning = AppSemanticColors.of(context).warning;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _WeekGrid._compactDuration(aggregate.loadMinutes),
            style: TextStyle(fontSize: 10, color: textColor),
          ),
          if (aggregate.overMinutes > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 10,
                  color: warning,
                ),
                const SizedBox(width: 2),
                Text(
                  _WeekGrid._compactDuration(aggregate.overMinutes),
                  style: TextStyle(
                    fontSize: 10,
                    color: warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 年视图月格强度色板（5 档，与进度页热力图 LeetCode 色板同语义）。
const _heatColors = <Color>[
  Color(0xFFEBEDF0),
  Color(0xFF9BE9A8),
  Color(0xFF40C463),
  Color(0xFF30A14E),
  Color(0xFF216E39),
];

/// 年视图网格（12 月概览）：3×4 月格，每月显示完成强度与完成数。
///
/// - 月格：月份标题 + 5 档强度色点行（复用 [StatisticsService.heatLevel]
///   语义，按当月完成数分档）+ 「N 完成」文本（NFR-4 不只依赖颜色）；
/// - 点击月格 → 切到月视图并定位该月（滴答语义：年 → 月下钻）；
/// - 当前月高亮边框，未来月正常显示（完成 0）。
class _YearGrid extends StatelessWidget {
  const _YearGrid({
    super.key,
    required this.year,
    required this.todayStr,
    required this.monthCounts,
    required this.onSelectMonth,
  });

  final int year;
  final String todayStr;
  final Map<String, int> monthCounts; // 'yyyy-MM' -> 完成数
  final ValueChanged<int> onSelectMonth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.parse(todayStr);
    final todayYear = today.year;
    final todayMonth = today.month;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.45,
      ),
      itemCount: 12,
      itemBuilder: (context, index) {
        final month = index + 1;
        final key = '$year-${month.toString().padLeft(2, '0')}';
        final count = monthCounts[key] ?? 0;
        final level = StatisticsService.heatLevel(count);
        final isCurrentMonth = year == todayYear && month == todayMonth;
        final isFutureMonth =
            year > todayYear || (year == todayYear && month > todayMonth);

        return Material(
          color: isFutureMonth
              ? scheme.surfaceContainerLowest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          elevation: isCurrentMonth ? 1 : 0,
          child: InkWell(
            onTap: () => onSelectMonth(month),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: isCurrentMonth
                    ? Border.all(color: scheme.primary, width: 1.5)
                    : null,
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$month 月',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isCurrentMonth
                                  ? scheme.primary
                                  : scheme.onSurface,
                            ),
                      ),
                      // 当前月小徽标。
                      if (isCurrentMonth)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  // 完成数大数字 + 描述。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$count',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: isCurrentMonth
                                  ? scheme.primary
                                  : scheme.onSurface,
                              height: 1,
                            ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '完成',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  // 强度色点行：5 档（与进度页热力图同语义）。
                  Row(
                    children: [
                      for (var i = 0; i < 5; i++)
                        Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsets.only(right: 3),
                          decoration: BoxDecoration(
                            color: i < level
                                ? _heatColors[level]
                                : scheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
