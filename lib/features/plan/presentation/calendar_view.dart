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
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../../shared/widgets/progressive_rows.dart';
import '../../../shared/widgets/section_error_view.dart';
import '../../calendar_io/data/ics_export_service.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/quick_task_form_dialog.dart';
import '../../tasks/presentation/task_tile.dart';

/// 选日面板标题（含星期，中文），复用单一实例避免每帧重建 DateFormat。
final _dayLabelFormat = DateFormat('yyyy-MM-dd EEEE', 'zh_CN');

/// 日历视图模式（周 / 月）。
enum CalendarViewMode { week, month }

/// 日历视图（FR-3.4）：周/月网格 + 选日任务面板。
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

  late CalendarViewMode _mode; // 周/月视图
  late DateTime _month; // 月（day 固定 1）
  late DateTime _weekStart; // 周一（周视图）
  late String _selectedDate; // yyyy-MM-dd
  late bool _monthHideCompleted; // 月视图：隐藏已完成任务

  @override
  void initState() {
    super.initState();
    final today = ref.read(clockProvider)();
    _mode = CalendarViewMode.month; // 默认月视图（与现状一致）
    _month = DateTime(today.year, today.month);
    _weekStart = _mondayOf(today);
    _selectedDate = formatLocalDate(today);
    _monthHideCompleted = false;
  }

  /// 导出当前计划为 iCalendar（.ics）文件：未归档任务 + 全部里程碑。
  ///
  /// 与备份导出同款交互（原生「另存为」对话框）；用户取消不提示，
  /// 失败给出可读 SnackBar（不阻断页面）。
  Future<void> _exportIcs() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(icsExportServiceProvider)
          .export(calendarName: 'TimeCalc 学习计划');
      if (!mounted || result == null) return; // 用户取消。
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.eventCount == 0
                ? '没有可导出的日程（任务与里程碑都为空）'
                : '已导出 ${result.eventCount} 个日程'
                      '（任务 ${result.taskCount} · 里程碑 ${result.milestoneCount}）'
                      '到 ${result.path}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('导出日历失败：$e')));
    }
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
          error: goalsAsync.hasError ? goalsAsync.error! : settingsAsync.error!,
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
    // 也 watch 周视图并计算全部聚合，勾选任务失效后连带重查/重建无关数据。
    // 刷新期间 valueOrNull 保留旧值，网格始终渲染不塌陷。
    final AsyncValue<List<Task>> viewTasksAsync;
    final Map<String, DayAggregate> gridAggregate;
    final Map<String, List<Task>> weekTasksByDate;
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
          break;
        }
    }

    // 选日任务的科目名：父级一次性预取（按 goalId 去重），避免每个 TaskTile
    // 各自 watch(subjectListProvider) + 线性扫描（N+1）。
    final selectedTasks = selectedTasksAsync.valueOrNull ?? const <Task>[];
    final subjectsByGoal = <int, List<Subject>>{
      for (final gid in {for (final t in selectedTasks) t.goalId})
        gid:
            ref.watch(subjectListProvider(gid)).valueOrNull ??
            const <Subject>[],
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
    };

    final header = _CalendarHeader(
      mode: _mode,
      title: title,
      isCurrent: isCurrent,
      onModeChanged: (m) => setState(() => _mode = m),
      onPrev: onPrev,
      onNext: onNext,
      onBackToToday: onBackToToday,
      onExportIcs: _exportIcs,
      hideCompleted: _monthHideCompleted,
      onHideCompletedChanged: _mode == CalendarViewMode.month
          ? (value) => setState(() => _monthHideCompleted = value)
          : null,
    );
    final calendar = AnimatedSwitcher(
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
          tasksByDate: _groupTasksByDate(
            (viewTasksAsync.valueOrNull ?? const <Task>[])
                .where(
                  (task) =>
                      !_monthHideCompleted || task.status != TaskStatus.done,
                )
                .toList(),
          ),
          onSelect: (dateStr) => setState(() => _selectedDate = dateStr),
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
          onSelect: (dateStr) => setState(() => _selectedDate = dateStr),
          onDropTask: (task, date) => _handleTaskDropped(task, date),
        ),
      },
    );
    final dayPanel = AnimatedSwitcher(
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
    );
    final status = Column(
      children: [
        if (_viewTasks().isEmpty)
          if (_viewAsync().hasError)
            SectionErrorView(
              error: _viewAsync().error!,
              onRetry: () {
                // 按当前视图失效对应数据族（family 无参整族失效）。
                switch (_mode) {
                  case CalendarViewMode.month:
                    ref.invalidate(tasksByMonthProvider);
                  case CalendarViewMode.week:
                    ref.invalidate(tasksByWeekProvider);
                }
              },
            )
          else if (_viewAsync().isLoading)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: LinearProgressIndicator(minHeight: 2),
            ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 1050 && constraints.hasBoundedHeight;
        final scheme = Theme.of(context).colorScheme;
        // 宽屏把日历区域铺成页面底色（暖奶油）：白色日期格/卡片「浮于暖奶油
        // 底」，与窄屏 Scaffold 底色一致；不再硬编码白色（旧版宽屏铺白，
        // 白格与页面同色，只剩边框可辨）。
        final surface = scheme.surface;
        if (!wide) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: 16),
                status,
                calendar,
                const SizedBox(height: 24),
                dayPanel,
              ],
            ),
          );
        }
        return ColoredBox(
          color: surface,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: header,
              ),
              status,
              const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        key: const ValueKey('calendar-main-scroll'),
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        child: calendar,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 330,
                      child: SingleChildScrollView(
                        key: const ValueKey('calendar-detail-scroll'),
                        padding: const EdgeInsets.all(16),
                        child: dayPanel,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
      ref
              .read(
                tasksByMonthProvider(
                  '${_month.year}-${_month.month.toString().padLeft(2, '0')}',
                ),
              )
              .valueOrNull ??
          const <Task>[],
    CalendarViewMode.week =>
      ref.read(tasksByWeekProvider(formatLocalDate(_weekStart))).valueOrNull ??
          const <Task>[],
  };

  AsyncValue<List<Task>> _viewAsync() => switch (_mode) {
    CalendarViewMode.month => ref.read(
      tasksByMonthProvider(
        '${_month.year}-${_month.month.toString().padLeft(2, '0')}',
      ),
    ),
    CalendarViewMode.week => ref.read(
      tasksByWeekProvider(formatLocalDate(_weekStart)),
    ),
  };

  /// 数据变更后的统一刷新：计划页高频任务操作走局部失效（invalidatePlanData，
  /// 2026-08-15 性能优化：不重查目标、补上周/年视图；跨页统计仍一并刷新）。
  void _invalidateAll() => invalidatePlanData(ref.invalidate);

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
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(dateLabel, style: Theme.of(context).textTheme.titleMedium),
            TextButton.icon(
              onPressed: onAddTask,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加任务'),
            ),
          ],
        ),
        if (selectedTasks.isNotEmpty) ...[
          Text(
            '${selectedTasks.length} 项任务 · ${selectedTasks.where((t) => t.status == TaskStatus.done).length} 项已完成',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
        ],
        // 选日数据局部状态：加载细进度条 / 错误条，均不整页塌陷。
        if (selectedTasks.isEmpty)
          if (selectedTasksAsync.hasError)
            SectionErrorView(
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
              child: ClashEmptyState(
                icon: Icons.event_outlined,
                title: '这一天没有任务',
                // 空态＝冷色撞色（tone 默认 cool）+ compact 布局，
                // 与旧 ChartEmptyState 的空态口径一致。
                compact: true,
                action: onAddTask == null
                    ? null
                    : OutlinedButton.icon(
                        onPressed: onAddTask,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('去添加任务'),
                      ),
              ),
            )
        else
          // 单卡分组行（2026-08-16 视觉升级）：一张卡片承载当日全部任务行，
          // 行间细分隔线；行内容由 TaskTile（自身无卡）提供，经
          // ProgressiveRows 分块渐进构建（选日任务无上限，防首帧全量 build）。
          Card(
            margin: const EdgeInsets.only(top: 4),
            clipBehavior: Clip.antiAlias,
            child: ProgressiveRows(
              itemCount: selectedTasks.length,
              itemBuilder: (context, i) => Column(
                children: [
                  if (i > 0)
                    const Divider(height: 1, indent: 12, endIndent: 12),
                  // FR-5.1：长按任务条目即可拖动到网格中的目标日期改期。
                  // 按任务身份 key 复用 element：勾选/删除导致列表收缩时，
                  // 划线/透明度动画不会错播到相邻任务上（幻影动画）。
                  LongPressDraggable<Task>(
                    key: ValueKey('day-task-${selectedTasks[i].id}'),
                    data: selectedTasks[i],
                    feedback: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          selectedTasks[i].title,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.4,
                      child: TaskTile(
                        task: selectedTasks[i],
                        goalTitle: goalsById[selectedTasks[i].goalId]?.title,
                        subjects: subjectsByGoal[selectedTasks[i].goalId],
                        onChanged: onChanged,
                      ),
                    ),
                    child: TaskTile(
                      task: selectedTasks[i],
                      goalTitle: goalsById[selectedTasks[i].goalId]?.title,
                      subjects: subjectsByGoal[selectedTasks[i].goalId],
                      onChanged: onChanged,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 日历头部：视图切换器（周/月）+ 标题 + 上一单元/下一单元 + 回到今天。
class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({
    required this.mode,
    required this.title,
    required this.isCurrent,
    required this.onModeChanged,
    required this.onPrev,
    required this.onNext,
    required this.onBackToToday,
    required this.onExportIcs,
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

  /// 导出 .ics 日历（全部未归档任务 + 里程碑）。
  final VoidCallback onExportIcs;

  /// 仅月视图：「隐藏已完成」开关的当前值。
  final bool hideCompleted;

  /// 仅月视图：「隐藏已完成」开关变更回调；非月视图传 null。
  final ValueChanged<bool>? onHideCompletedChanged;

  /// 当前是否为月视图（决定工具是否展示）。
  bool get _isMonthView => onHideCompletedChanged != null;

  @override
  Widget build(BuildContext context) {
    final navigation = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上一单元',
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
        IconButton(
          tooltip: '下一单元',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right, size: 20),
        ),
        TextButton(onPressed: onBackToToday, child: const Text('回到今天')),
      ],
    );
    final tools = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // 周/月切换器：直接用主题的 segmentedButton（选中＝暖色容器 +
        // onWarmContainer 文字），不再包一层 styleFrom 覆盖颜色。
        SegmentedButton<CalendarViewMode>(
          segments: const [
            ButtonSegment(value: CalendarViewMode.week, label: Text('周')),
            ButtonSegment(value: CalendarViewMode.month, label: Text('月')),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onModeChanged(selection.first),
        ),
        if (mode == CalendarViewMode.month && _isMonthView)
          _HideCompletedChip(
            value: hideCompleted,
            onChanged: onHideCompletedChanged!,
          ),
        IconButton(
          tooltip: '导出日历（.ics，可导入手机/Google 日历）',
          onPressed: onExportIcs,
          icon: const Icon(Icons.ios_share_outlined, size: 19),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final heading = Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
        );
        if (constraints.maxWidth >= 1000) {
          return Row(
            children: [
              heading,
              const SizedBox(width: 20),
              navigation,
              const Spacer(),
              tools,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [heading, navigation],
            ),
            const SizedBox(height: 12),
            tools,
          ],
        );
      },
    );
  }
}

/// 「隐藏已完成」开关小_chip。
class _HideCompletedChip extends StatelessWidget {
  const _HideCompletedChip({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // 过滤开关属于「数据筛选」语义 → 冷藏青；未启用时保持中性档位。
    final cool = ClashTones.of(context, ClashTone.cool);
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        value ? Icons.check_box : Icons.check_box_outline_blank,
        size: 18,
        color: value ? cool.onSoft : scheme.onSurfaceVariant,
      ),
      label: const Text('隐藏已完成'),
      labelStyle: const TextStyle(fontSize: 12),
      padding: EdgeInsets.zero,
      side: BorderSide.none,
      backgroundColor: value ? cool.soft : scheme.surfaceContainerHighest,
      onPressed: () => onChanged(!value),
    );
  }
}

/// 日历网格共用的撞色色组。
///
/// 每次网格 `build` 只解析一次主题（月网格 42 格、周网格 7 格、年网格 12 格
/// 逐格复用），避免逐格重复 `Theme.of`/撞色解析——月历在大数据量下的构建
/// 开销保持与重构前同一量级。
@immutable
class _GridTones {
  const _GridTones({required this.warm, required this.cool, required this.series});

  factory _GridTones.of(BuildContext context) => _GridTones(
    warm: ClashTones.of(context, ClashTone.warm),
    cool: ClashTones.of(context, ClashTone.cool),
    series: ClashTones.chartSeries(context),
  );

  /// 暖色（今天、当前时间、主动作）。
  final ClashTones warm;

  /// 冷藏青（选中日期、计划块）。
  final ClashTones cool;

  /// 撞色三序列（暖/冷/点缀）：日历事件块按**既有分类（目标 id）**稳定映射
  /// 到其中一支——同一目标的任务在月/周视图里颜色一致，切换视图不跳色。
  final List<Color> series;

  /// 事件块的撞色序列色（作描边 / 文字 / 图标，均为「ink」角色）。
  Color seriesColor(int categoryId) => series[categoryId % series.length];
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
    required this.tasksByDate,
    required this.onSelect,
    this.onDropTask,
  });

  final DateTime month;
  final String todayStr;
  final String selectedDate;
  final Set<int> weekdays;
  final Map<String, DayAggregate> aggregate;
  final Map<String, List<Task>> tasksByDate;
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
    final tones = _GridTones.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final preview = constraints.maxWidth >= 700;
        final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final cellHeight = (preview ? 138.0 : 80.0) * scale.clamp(1.0, 2.5);
        return Column(
          children: [
            Row(
              children: [
                for (final label in _weekdayLabels)
                  Expanded(
                    child: Center(
                      child: Text(
                        '周$label',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (var row = 0; row < totalCells ~/ 7; row++) ...[
              Row(
                children: [
                  for (var col = 0; col < 7; col++) ...[
                    Expanded(
                      child: _buildCell(
                        context,
                        scheme,
                        tones,
                        day: row * 7 + col + 1 - leadingBlanks,
                        preview: preview,
                        cellHeight: cellHeight,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCell(
    BuildContext context,
    ColorScheme scheme,
    _GridTones tones, {
    required int day,
    required bool preview,
    required double cellHeight,
  }) {
    if (day < 1 || day > _daysInMonth) {
      // 非本月日期：走 surfaceContainer / outlineVariant 档位（不再手调 alpha）。
      return Container(
        height: cellHeight,
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border.all(color: scheme.outlineVariant, width: 0.5),
        ),
      );
    }
    final warning = AppSemanticColors.of(context).warning;
    final date = DateTime(month.year, month.month, day);
    final dateStr = formatLocalDate(date);
    final agg = aggregate[dateStr] ?? DayAggregate.empty;
    final isAvailable = weekdays.contains(date.weekday);
    final isToday = dateStr == todayStr;
    final isSelected = dateStr == selectedDate;
    final hasTask = agg.totalCount > 0;
    final isWeekend = date.weekday >= DateTime.saturday;

    // 三态撞色语言（NFR-4：状态另有日期徽标/圆点/时长文本承载，不只靠颜色）：
    // - **今天**＝暖色实心日期徽标 + 暖色粗描边（`ClashTone.warm`）；
    // - **选中**＝冷藏青浅容器（`ClashTone.cool.soft` + `onSoft`）；
    // - 两者可同时成立：冷底 + 暖徽标/暖描边，仍然是「一个暖实心 + 一个冷浅底」，
    //   一眼可分（此前两者都用 primary，深浅只差 6% alpha，几乎无法区分）。
    final warm = tones.warm;
    final cool = tones.cool;
    final background = isSelected
        ? cool.soft
        : (isWeekend ? scheme.surfaceContainer : scheme.surfaceContainerLow);
    final borderColor = isToday
        ? warm.ink
        : (isSelected ? cool.ink : scheme.outlineVariant);
    final border = Border.all(
      color: borderColor,
      width: isToday ? 2 : (isSelected ? 1.5 : 0.5),
    );
    // 格内前景色：选中格用 onSoft（保证冷容器上的对比），今天用暖 ink。
    final foreground = isSelected
        ? cool.onSoft
        : (isToday ? warm.ink : scheme.onSurface);
    final dotColor = isSelected ? cool.ink : warm.ink;
    final dayTasks = tasksByDate[dateStr] ?? const <Task>[];

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
      selected: isSelected,
      child: InkWell(
        onTap: () => onSelect(dateStr),
        borderRadius: BorderRadius.circular(2),
        child: Container(
          height: cellHeight,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(2),
            border: border,
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      // 今天＝暖色实心徽标（与选中格的冷浅底彻底区分）。
                      color: isToday ? warm.fill : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '$day',
                      style: TextStyle(
                        color: isToday
                            ? warm.onFill
                            : (isSelected
                                  ? cool.onSoft
                                  : (!isAvailable
                                        ? scheme.onSurfaceVariant
                                        : scheme.onSurface)),
                        fontWeight: isToday || isSelected
                            ? FontWeight.w600
                            : null,
                      ),
                    ),
                  ),
                  // 有任务圆点：日期数字右侧的撞色小点，一眼可辨「这天有安排」
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
              if (preview && dayTasks.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final task in dayTasks.take(2))
                  _MonthTaskPill(
                    task: task,
                    seriesColor: tones.seriesColor(task.goalId),
                    scheme: scheme,
                  ),
                if (dayTasks.length > 2)
                  Text(
                    '+${dayTasks.length - 2} 项',
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
              if (preview && agg.totalCount > 0) ...[
                const Spacer(),
                Text(
                  '${_compactDuration(agg.loadMinutes)}${agg.overMinutes > 0 ? ' · 超出 ${_compactDuration(agg.overMinutes)}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: agg.overMinutes > 0
                        ? warning
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (agg.totalCount > 0 && !preview) ...[
                const SizedBox(height: 2),
                // 小型完成进度条：直观展示当天完成比例。
                _MonthDayProgressBar(
                  done: agg.doneCount,
                  total: agg.totalCount,
                  // 冷容器上用冷填充、暖/中性底上用暖填充（同一格内永远可读）。
                  color: isSelected ? cool.fill : warm.fill,
                ),

                // 时长与超载信息。
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        _compactDuration(agg.loadMinutes),
                        style: TextStyle(fontSize: 10, color: foreground),
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
    // 拖动悬停时用暖色描边 + 撞色半透明底高亮；放置失败（数据库异常）时
    // 任务保持原日期。
    return DragTarget<Task>(
      onWillAcceptWithDetails: (details) =>
          details.data.status != TaskStatus.done,
      onAcceptWithDetails: (details) => drop(details.data, dateStr),
      builder: (context, candidate, rejected) => DecoratedBox(
        decoration: candidate.isNotEmpty
            ? BoxDecoration(
                color: ClashTones.tint(warm.ink, alpha: 0.08),
                border: Border.all(color: warm.ink, width: 2),
                borderRadius: BorderRadius.circular(2),
              )
            : const BoxDecoration(),
        child: cell,
      ),
    );
  }
}

/// 月视图格内的事件块（最多两条预览）。
///
/// 撞色序列着色：底色＝该分类序列色的撞色半透明底（`ClashTones.tint`），
/// 左侧 2px 竖条与文字＝序列色本身（`chartSeries` 的 ink 角色，压在浅底上
/// ≥4.5:1）；已完成任务保持「灰化 + 删除线」的中性语义，不与未完成块抢眼。
class _MonthTaskPill extends StatelessWidget {
  const _MonthTaskPill({
    required this.task,
    required this.seriesColor,
    required this.scheme,
  });

  final Task task;
  final Color seriesColor;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    final title =
        '${task.startTime == null ? '' : '${task.startTime} '}${task.title}';
    final label =
        '${task.startTime == null ? '' : '${task.startTime} · '}${task.title}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: label,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
            // 不透明浅底（撞色 tint 压在卡片白底上）：块内文字对比度只取决于
            // 序列色与该浅底，不受所在格底色（冷容器/周末底）影响。
            color: done
                ? scheme.surfaceContainerHighest
                : Color.alphaBlend(
                    ClashTones.tint(seriesColor, alpha: 0.08),
                    scheme.surfaceContainerLowest,
                  ),
            border: Border(
              left: BorderSide(
                color: done ? scheme.outline : seriesColor,
                width: 2,
              ),
            ),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              color: done ? scheme.onSurfaceVariant : seriesColor,
              decoration: done ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 月视图日格完成进度条：细条形，已完成比例一目了然。
///
/// 全部完成时显示勾选徽标而非实心条，避免 100% 时前景与背景融为一条
/// 粗黑线（withValues alpha 仅 0.2，但颜色饱和度高时仍显脏）。
/// 颜色由调用方按格子撞色态传入（冷容器→冷填充，暖/中性底→暖填充）。
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
          Icon(Icons.check_circle, size: 11, color: color),
          const SizedBox(width: 3),
          Text('完成', style: TextStyle(fontSize: 10, color: color)),
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
    final tones = _GridTones.of(context);
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
                    tones,
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
    ColorScheme scheme,
    _GridTones tones, {
    required DateTime date,
  }) {
    final dateStr = formatLocalDate(date);
    final agg = aggregate[dateStr] ?? DayAggregate.empty;
    final isAvailable = weekdays.contains(date.weekday);
    final isToday = dateStr == todayStr;
    final isSelected = dateStr == selectedDate;
    final hasTask = agg.totalCount > 0;
    final isWeekend = date.weekday >= DateTime.saturday;

    // 撞色三态（NFR-4：状态另有日期号/圆点/完成徽标/负载文本承载）：
    // 今天＝暖色浅容器 + 暖色粗描边（+ 暖色粗体日期号）；选中＝冷藏青浅容器
    // （cool soft/onSoft）；两者可同时成立，冷底 + 暖描边，一眼可分。
    // 文字取「所在容器自己的配对前景色」，不把 ink（压卡片的角色）压到
    // 撞色容器上（那会掉到 4.2:1 左右）。
    final warm = tones.warm;
    final cool = tones.cool;
    final baseTextColor = isAvailable
        ? scheme.onSurface
        : scheme.outlineVariant;
    final textColor = isSelected
        ? cool.onSoft
        : (isToday ? warm.onSoft : baseTextColor);
    final background = isSelected
        ? cool.soft
        : (isToday
              ? warm.soft
              : (isWeekend
                    ? scheme.surfaceContainer
                    : scheme.surfaceContainerLow));
    final borderColor = isToday
        ? warm.ink
        : (isSelected ? cool.ink : scheme.outlineVariant);
    final border = Border.all(
      color: borderColor,
      width: isToday ? 2 : (isSelected ? 1.5 : 0.5),
    );
    final dotColor = isSelected ? cool.ink : warm.ink;

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
                  // 周格窄（7 列）：日期号保持裸文本，不额外加内边距（窄视口会
                  // 挤出日期行）；「今天」由暖色浅容器 + 暖色粗描边 + 暖色
                  // 粗体日期号 + 暖色圆点共同承载。
                  Text(
                    '${date.day}',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: isToday || isSelected
                          ? FontWeight.bold
                          : null,
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
                  child: _TaskPills(tasks: dayTasks, tones: tones),
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
                color: ClashTones.tint(warm.ink, alpha: 0.08),
                border: Border.all(color: warm.ink, width: 2),
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
        // 统一走撞色半透明底（与 hover/选中行同一透明度入口）。
        color: ClashTones.tint(color, alpha: 0.12),
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
///
/// 撞色序列着色（与月视图事件块同一映射）：底色＝该任务所属目标序列色的
/// 撞色半透明底（`ClashTones.tint`），文字/图标＝序列色本身。
///
/// 为什么不再跟随「格子前景色」：选中格改成冷藏青浅容器后，若沿用
/// 「浅底 + 格子前景色」或「onPrimary 覆盖层」的写法，浅底配白字（深色
/// 主题为深底深字）都会不可读。事件块的取色与格子底色解耦后，
/// 选中格 / 普通格都能保证 ≥4.5:1（2026-08-16 对比度回归的延续）。
class _TaskPills extends StatelessWidget {
  const _TaskPills({required this.tasks, required this.tones});

  final List<Task> tasks;
  final _GridTones tones;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = tasks.take(_WeekGrid._maxTaskPills).toList();
    final overflow = tasks.length - display.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final task in display)
          Builder(
            builder: (context) {
              final done = task.status == TaskStatus.done;
              final accent = tones.seriesColor(task.goalId);
              return Container(
                height: _WeekGrid._pillHeight - 2,
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: done
                      ? scheme.surfaceContainerHighest
                      // 与月视图事件块同一取色：撞色 tint 压在不透明卡片底上，
                      // 对比度不随所在格底色（冷容器/周末底）变化。
                      : Color.alphaBlend(
                          ClashTones.tint(accent, alpha: 0.08),
                          scheme.surfaceContainerLowest,
                        ),
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      done ? Icons.check_circle : Icons.circle,
                      size: 8,
                      color: done ? scheme.outline : accent,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        task.title,
                        style: TextStyle(
                          fontSize: 10,
                          color: done ? scheme.onSurfaceVariant : accent,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            },
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
  const _DayLoadBar({required this.aggregate, required this.textColor});

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
                Icon(Icons.warning_amber_rounded, size: 10, color: warning),
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
