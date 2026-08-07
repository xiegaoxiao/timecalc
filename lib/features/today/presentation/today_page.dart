import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/defer_service.dart';
import '../../../services/duration_format.dart';
import '../../../services/load_service.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/milestone_repository_provider.dart';
import '../../goals/presentation/goal_form_dialog.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/quick_task_form_dialog.dart';
import '../../tasks/presentation/task_tile.dart';

/// 今天页：目标倒计时 + 今日任务闭环（M2）。
///
/// 结构（自上而下）：
/// 1. 进行中目标的倒计时卡片（FR-1.2/FR-1.3）；
/// 2. 今日负载概览（FR-3.5：超可用时长显示「超出 X 分钟」）；
/// 3. FR-3.7 横幅：昨日及更早未完成任务集中确认（不自动改计划）；
/// 4. 今日任务列表（完成/编辑/延期/删除）与快速添加。
/// 今日日期取自 [clockProvider]，全程可测试注入。
class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key});

  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage> {
  static const _defer = DeferService();
  static const _load = LoadService();
  static const _stats = StatisticsService();

  /// FR-3.7 横幅的会话级关闭（「保留原日期」），不写库。
  bool _bannerDismissed = false;

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(clockProvider)();
    final todayStr = DateFormat('yyyy-MM-dd').format(today);

    final goalsAsync = ref.watch(goalListProvider);
    final settingsAsync = ref.watch(settingsProvider);
    final tasksAsync = ref.watch(tasksByDateProvider(todayStr));
    final unfinishedAsync = ref.watch(unfinishedBeforeProvider(todayStr));
    final todoAsync = ref.watch(allTodoTasksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('今天')),
      body: goalsAsync.when(
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
              onRetry: () => ref.invalidate(tasksByDateProvider),
            ),
            data: (tasks) => unfinishedAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => AppErrorView(
                error: error,
                onRetry: () => ref.invalidate(unfinishedBeforeProvider),
              ),
              data: (unfinished) => todoAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => AppErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(allTodoTasksProvider),
                ),
                data: (todo) => _buildBody(
                  goals: goals,
                  settings: settings,
                  today: today,
                  todayTasks: tasks,
                  unfinished: unfinished,
                  todoTasks: todo,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody({
    required List<Goal> goals,
    required Setting settings,
    required DateTime today,
    required List<Task> todayTasks,
    required List<Task> unfinished,
    required List<Task> todoTasks,
  }) {
    final activeGoals = goals
        .where((g) =>
            g.status != 'completed' &&
            g.status != 'abandoned' &&
            g.status != 'archived')
        .toList();

    // 数据变更后的统一刷新（FR-3 验收：今日列表、日历、目标详情在同一
    // 操作周期内同步更新）。公共集合见 invalidateAppData（P3 收敛）。
    void onChanged() => invalidateAppData(ref);

    // 空态：无进行中目标、今日无任务、且无逾期未完成任务时展示。
    // 有逾期任务时保留 FR-3.7 横幅与任务区，避免横幅被空态遮蔽（回归）。
    if (activeGoals.isEmpty && todayTasks.isEmpty && unfinished.isEmpty) {
      return _EmptyView(
        hasAnyGoal: goals.isNotEmpty,
        onCreateGoal: _createGoal,
      );
    }

    final goalsById = {for (final g in goals) g.id: g};
    final availableMinutes = settings.dailyAvailableMinutes;
    final load = _load.dayLoad(todayTasks);
    final over = _load.overMinutes(
      load: load,
      available: availableMinutes,
    );
    final weekdays =
        SettingsRepository.decodeWeekdays(settings.availableWeekdays);
    final addGoals = activeGoals.isNotEmpty ? activeGoals : goals;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (activeGoals.isNotEmpty) ...[
          for (final goal in activeGoals)
            _CountdownCard(goal: goal),
          const SizedBox(height: 8),
        ],
        if (todayTasks.isNotEmpty) ...[
          _LoadOverviewCard(
            load: load,
            available: availableMinutes,
            over: over,
            stats: _stats.completionStats(todayTasks),
            remainingMinutes: _stats.remainingMinutes(todoTasks),
          ),
          const SizedBox(height: 8),
        ],
        if (unfinished.isNotEmpty && !_bannerDismissed) ...[
          _UnfinishedBanner(
            count: unfinished.length,
            onDeferNext: () async {
              final next = _defer.nextAvailableDate(
                today: today,
                availableWeekdays: weekdays,
              );
              final ok = await runDbAction(
                context,
                action: () => ref
                    .read(taskRepositoryProvider)
                    .deferMany(unfinished.map((t) => t.id).toList(), next),
              );
              if (ok) onChanged();
            },
            onDeferPickDate: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: today,
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 10),
                helpText: '选择延期日期',
              );
              if (picked == null) return;
              if (!mounted) return;
              final ok = await runDbAction(
                context,
                action: () => ref.read(taskRepositoryProvider).deferMany(
                      unfinished.map((t) => t.id).toList(),
                      DateFormat('yyyy-MM-dd').format(picked),
                    ),
              );
              if (ok) onChanged();
            },
            onKeepOriginal: () => setState(() => _bannerDismissed = true),
          ),
          const SizedBox(height: 8),
        ],
        // 过期任务区块（FR-3.7 扩展）：红条下方逐条列出昨日及更早未完成
        // 任务，复用 TaskTile 的完成/编辑/延期/删除操作；与红条共用
        // unfinished 数据源，任何操作经 onChanged 联动刷新。
        // 数据驱动显示：无过期任务即隐藏；「保留原日期」只关横幅，区块
        // 保留以便用户仍可逐条处理。
        if (unfinished.isNotEmpty) ...[
          _OverdueTasksSection(
            tasks: unfinished,
            goalsById: goalsById,
            today: today,
            onChanged: onChanged,
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Text('今日任务', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: addGoals.isEmpty
                  ? null
                  : () async {
                      await QuickTaskFormDialog.show(
                        context,
                        date: today,
                        goals: addGoals,
                      );
                      onChanged();
                    },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加任务'),
            ),
          ],
        ),
        if (todayTasks.isEmpty)
          _TodayEmptyView(onAddTask: addGoals.isEmpty ? null : () async {
            // 等待对话框保存完成后再刷新，避免 invalidate 早于数据写入（回归）。
            await QuickTaskFormDialog.show(context, date: today, goals: addGoals);
            onChanged();
          })
        else
          for (final task in todayTasks)
            TaskTile(
              task: task,
              goalTitle: goalsById[task.goalId]?.title,
              onChanged: onChanged,
            ),
      ],
    );
  }

  Future<void> _createGoal() async {
    final createdId = await GoalFormDialog.show(context);
    if (createdId != null && mounted) {
      ref.invalidate(goalListProvider);
      context.push('/goals/$createdId');
    }
  }
}

/// 今日负载概览（FR-3.5 / FR-7.1）。
///
/// 标题展示「今日任务总计 X 小时 Y 分」（当日未完成任务预估时长之和）；
/// 副标题展示可用时长，超出时追加「超出 X 分」文案与警告图标
/// （状态不只依赖颜色表达）。FR-7.1 展示今日完成数/总数、今日已完成
/// 预估时长与目标剩余工作量。
class _LoadOverviewCard extends StatelessWidget {
  const _LoadOverviewCard({
    required this.load,
    required this.available,
    required this.over,
    required this.stats,
    required this.remainingMinutes,
  });

  final int load;
  final int available;
  final int over;
  final DayCompletionStats stats;
  final int remainingMinutes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: Icon(over > 0 ? Icons.warning_amber_rounded : Icons.balance),
        title: Text('今日任务总计 ${DurationFormat.minutes(load)}'),
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('可用 ${DurationFormat.minutes(available)}'),
            if (over > 0)
              Text(
                '超出 ${DurationFormat.minutes(over)}，请调整任务或可用时间',
                style: TextStyle(color: scheme.error),
              ),
            Text(
              '完成 ${stats.doneCount}/${stats.totalCount} · '
              '已完成 ${DurationFormat.minutes(stats.doneMinutes)} · '
              '目标剩余 ${DurationFormat.minutes(remainingMinutes)}',
            ),
          ],
        ),
        trailing: over > 0
            ? Icon(Icons.error_outline, color: scheme.error)
            : null,
      ),
    );
  }
}

/// FR-3.7 次日未完成任务集中确认横幅。
///
/// 不自动改变原计划（FR-3.7）：由用户选择延期（下一可用日/指定日期）
/// 或保留原日期（仅本会话关闭横幅）。
class _UnfinishedBanner extends StatelessWidget {
  const _UnfinishedBanner({
    required this.count,
    required this.onDeferNext,
    required this.onDeferPickDate,
    required this.onKeepOriginal,
  });

  final int count;
  final VoidCallback onDeferNext;
  final VoidCallback onDeferPickDate;
  final VoidCallback onKeepOriginal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_busy, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '昨日及更早有 $count 个未完成任务',
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '原计划不会被自动更改，请选择处理方式',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: onDeferNext,
                  child: const Text('延期至下一可用日'),
                ),
                OutlinedButton(
                  onPressed: onDeferPickDate,
                  child: const Text('选择日期…'),
                ),
                TextButton(
                  onPressed: onKeepOriginal,
                  child: const Text('保留原日期'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 过期任务区块（FR-3.7 扩展）。
///
/// 红条下方浅红背景逐条列出昨日及更早未完成任务：每条展示原计划日期与
/// 已逾期天数，并复用 [TaskTile] 的完成/编辑/延期/删除操作。数据来自与
/// 红条相同的 [unfinished] 列表，任何操作经 [onChanged] 联动刷新（红条
/// 计数与本区块同步消失）。
class _OverdueTasksSection extends StatelessWidget {
  const _OverdueTasksSection({
    required this.tasks,
    required this.goalsById,
    required this.today,
    required this.onChanged,
  });

  final List<Task> tasks;
  final Map<int, Goal> goalsById;
  final DateTime today;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 浅红背景：在 banner 的 errorContainer 之上叠加低透明度，视觉更轻。
    final background = Color.alphaBlend(
      scheme.errorContainer.withValues(alpha: 0.30),
      scheme.surface,
    );
    return Card(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: scheme.error.withValues(alpha: 0.30),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Text(
                  '过期任务',
                  style: TextStyle(
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${tasks.length} 个未处理',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '以下任务原计划日期已过，请逐条延期或完成',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            for (final task in tasks) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '原计划 ${DateFormat('yyyy-MM-dd').format(parseLocalDate(task.plannedDate))}'
                  ' · 已逾期 ${_overdueDays(today, task.plannedDate)} 天',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
              TaskTile(
                task: task,
                goalTitle: goalsById[task.goalId]?.title,
                onChanged: onChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 今日无任务空态（PRD §8：提供与页面相关的首个操作，非纯说明页）。
class _TodayEmptyView extends StatelessWidget {
  const _TodayEmptyView({required this.onAddTask});

  final VoidCallback? onAddTask;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          const Icon(Icons.event_available, size: 48),
          const SizedBox(height: 8),
          const Text('今天没有安排'),
          const SizedBox(height: 12),
          if (onAddTask != null)
            FilledButton.icon(
              onPressed: onAddTask,
              icon: const Icon(Icons.add),
              label: const Text('添加任务'),
            ),
        ],
      ),
    );
  }
}

class _CountdownCard extends ConsumerWidget {
  const _CountdownCard({required this.goal});

  final Goal goal;

  static const _countdown = CountdownService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(clockProvider)();
    final nextMilestone = ref.watch(nextUpcomingMilestoneProvider(goal.id));
    final (phase, days) = _countdown.evaluate(
      deadlineDate: goal.deadlineDate,
      today: today,
      status: goal.status,
    );

    final scheme = Theme.of(context).colorScheme;
    final (phaseColor, phaseIcon) = switch (phase) {
      CountdownPhase.upcoming => (scheme.primary, Icons.schedule),
      CountdownPhase.today => (scheme.error, Icons.today),
      CountdownPhase.overdue => (scheme.error, Icons.error_outline),
      CountdownPhase.terminated => (scheme.outline, Icons.flag_outlined),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(
          goal.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('截止 ${DateFormat('yyyy-MM-dd').format(parseLocalDate(goal.deadlineDate))}'),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(phaseIcon, size: 14, color: phaseColor),
                const SizedBox(width: 4),
                Text(
                  CountdownService.label(phase, days),
                  style: TextStyle(color: phaseColor),
                ),
              ],
            ),
            // FR-2.3：首页仅展示距离最近的一个未完成里程碑。
            if (nextMilestone.valueOrNull case final milestone?) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.flag_outlined, size: 14, color: scheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '下一里程碑：${milestone.title} · ${milestone.date}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.primary,
                          ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        isThreeLine: true,
        onTap: () => context.push('/goals/${goal.id}'),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.hasAnyGoal, required this.onCreateGoal});

  final bool hasAnyGoal;
  final Future<void> Function() onCreateGoal;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.today_outlined, size: 64),
          const SizedBox(height: 12),
          const Text('今天没有安排'),
          const SizedBox(height: 4),
          Text(hasAnyGoal ? '所有目标已结束或归档' : '创建一个目标，开始倒计时'),
          const SizedBox(height: 16),
          if (!hasAnyGoal)
            FilledButton.icon(
              onPressed: onCreateGoal,
              icon: const Icon(Icons.add),
              label: const Text('创建目标'),
            ),
        ],
      ),
    );
  }
}

/// 任务逾期天数：计划日期距今经过的整天数（计划日期必早于 [today]）。
int _overdueDays(DateTime today, String plannedDate) {
  final planned = parseLocalDate(plannedDate);
  return DateUtils.dateOnly(today).difference(DateUtils.dateOnly(planned)).inDays;
}
