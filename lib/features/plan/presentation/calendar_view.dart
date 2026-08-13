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
import '../../../shared/widgets/chart_empty_state.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/quick_task_form_dialog.dart';
import '../../tasks/presentation/task_tile.dart';

/// 选日面板标题（含星期，中文），复用单一实例避免每帧重建 DateFormat。
final _dayLabelFormat = DateFormat('yyyy-MM-dd EEEE', 'zh_CN');

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
    _selectedDate = formatLocalDate(today);
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(clockProvider)();
    final todayStr = formatLocalDate(today);
    final monthKey =
        '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

    final goalsAsync = ref.watch(goalListProvider);
    final settingsAsync = ref.watch(settingsProvider);
    final tasksAsync = ref.watch(tasksByMonthProvider(monthKey));
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
      return const Center(child: CircularProgressIndicator());
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
    // 月份任务：换月/刷新期间 valueOrNull 保留旧值（首次换到新月份时兜底
    // 空表），网格始终渲染不塌陷；聚合只随已就绪数据重算。
    final monthTasks = tasksAsync.valueOrNull ?? const <Task>[];
    final aggregate = _load.calendarAggregate(
      tasks: monthTasks,
      availableMinutes: settings.dailyAvailableMinutes,
      availableWeekdays: weekdays,
    );

    // 选日任务的科目名：父级一次性预取（按 goalId 去重），避免每个 TaskTile
    // 各自 watch(subjectListProvider) + 线性扫描（N+1）。
    final selectedTasks = selectedTasksAsync.valueOrNull ?? const <Task>[];
    final subjectsByGoal = <int, List<Subject>>{
      for (final gid in {for (final t in selectedTasks) t.goalId})
        gid:
            ref.watch(subjectListProvider(gid)).valueOrNull ?? const <Subject>[],
    };

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
          // 月份数据加载/出错：网格区顶部细进度条或局部错误提示，不整页塌陷。
          if (monthTasks.isEmpty)
            if (tasksAsync.hasError)
              _SectionError(
                error: tasksAsync.error!,
                onRetry: () => ref.invalidate(tasksByMonthProvider),
              )
            else if (tasksAsync.isLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          // 月份切换淡入淡出（keyed by month；刷新原位更新，不触发动画）。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _MonthGrid(
              key: ValueKey(monthKey),
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
          ),
          const Divider(height: 32),
          // 选日面板：换日淡入淡出（keyed by date），加载/错误只影响面板区。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
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

  /// 数据变更后的统一刷新（FR-3 验收：日历月视图、选日列表、今日页与
  /// 目标详情在同一操作周期内同步更新）。公共集合见 invalidateAppData
  /// （P3 收敛）。
  void _invalidateAll() => invalidateAppData(ref);

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
                      // 非颜色状态（NFR-4）：超载格在警告色文本外附警告图标。
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 11,
                        color: warning,
                      ),
                      const SizedBox(width: 2),
                      Flexible(
                        child: Text(
                          '超出${_compactDuration(agg.overMinutes)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: warning,
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
