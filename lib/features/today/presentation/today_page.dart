import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/theme/app_theme.dart';
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

    // 核心数据（目标/设置）：仅首次加载或出错时整页占位；此后刷新期间
    // valueOrNull 保留旧值继续渲染，不再整页塌陷（去闪烁核心）。
    final goals = goalsAsync.valueOrNull;
    final settings = settingsAsync.valueOrNull;
    if (goals == null || settings == null) {
      if (goalsAsync.hasError || settingsAsync.hasError) {
        return Scaffold(
          appBar: AppBar(title: const Text('今天')),
          body: AppErrorView(
            error:
                goalsAsync.hasError ? goalsAsync.error! : settingsAsync.error!,
            onRetry: () {
              ref.invalidate(goalListProvider);
              ref.invalidate(settingsProvider);
            },
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('今天')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 任务类数据：刷新/换参期间 valueOrNull 保留旧值，兜底空表继续渲染；
    // 首次加载与局部错误在 _buildBody 内以细进度条/局部错误条呈现。
    return _buildBody(
      goals: goals,
      settings: settings,
      today: today,
      todayTasks: tasksAsync.valueOrNull ?? const <Task>[],
      unfinished: unfinishedAsync.valueOrNull ?? const <Task>[],
      todoTasks: todoAsync.valueOrNull ?? const <Task>[],
      tasksLoading: tasksAsync.isLoading && !tasksAsync.isRefreshing,
      tasksError: tasksAsync.error,
      unfinishedError: unfinishedAsync.error,
      onRetryTasks: () => ref.invalidate(tasksByDateProvider),
      onRetryUnfinished: () => ref.invalidate(unfinishedBeforeProvider),
    );
  }

  Widget _buildBody({
    required List<Goal> goals,
    required Setting settings,
    required DateTime today,
    required List<Task> todayTasks,
    required List<Task> unfinished,
    required List<Task> todoTasks,
    required bool tasksLoading,
    required Object? tasksError,
    required Object? unfinishedError,
    required VoidCallback onRetryTasks,
    required VoidCallback onRetryUnfinished,
  }) {
    final activeGoals = goals
        .where(
          (g) =>
              g.status != 'completed' &&
              g.status != 'abandoned' &&
              g.status != 'archived',
        )
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
    final over = _load.overMinutes(load: load, available: availableMinutes);
    final weekdays = SettingsRepository.decodeWeekdays(
      settings.availableWeekdays,
    );
    final addGoals = activeGoals.isNotEmpty ? activeGoals : goals;
    // 应用是否完全没有任务：决定「目标剩余工作量」显示 `-- 分`（没计划）
    // 还是实际数值（计划已满但全部完成）。
    final hasAnyTask = todoTasks.isNotEmpty || todayTasks.isNotEmpty;
    // 今日任务区空态（显示 _TodayEmptyView）：此时标题行右上角按钮隐藏，
    // 由空态大按钮承担唯一「添加任务」入口，避免两个相同入口。
    final todayEmpty = todayTasks.isEmpty && !tasksLoading && tasksError == null;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (activeGoals.isNotEmpty) ...[
          for (final goal in activeGoals) _CountdownCard(goal: goal),
          const SizedBox(height: 8),
        ],
        // 今日概览常驻：有活跃目标即显示（空态用 `--` 无数据语义），
        // 把「今日计划量与完成度」前置到首页。
        if (activeGoals.isNotEmpty) ...[
          _LoadOverviewCard(
            load: load,
            available: availableMinutes,
            over: over,
            stats: _stats.completionStats(todayTasks),
            remainingMinutes: _stats.remainingMinutes(todoTasks),
            hasAnyTask: hasAnyTask,
          ),
          const SizedBox(height: 8),
        ],
        if (unfinished.isEmpty && unfinishedError != null)
          _SectionError(
            error: unfinishedError,
            onRetry: onRetryUnfinished,
          ),
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
                action: () => ref
                    .read(taskRepositoryProvider)
                    .deferMany(
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
            // 空态时不重复右上角按钮：唯一的「添加任务」入口由空态大按钮承担。
            if (!todayEmpty) ...[
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
          ],
        ),
        if (todayTasks.isEmpty && tasksLoading)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (todayTasks.isEmpty && tasksError != null)
          _SectionError(
            error: tasksError,
            onRetry: onRetryTasks,
          ),
        if (todayTasks.isEmpty && !tasksLoading && tasksError == null)
          _TodayEmptyView(
            onAddTask: addGoals.isEmpty
                ? null
                : () async {
                    // 等待对话框保存完成后再刷新，避免 invalidate 早于数据写入（回归）。
                    await QuickTaskFormDialog.show(
                      context,
                      date: today,
                      goals: addGoals,
                    );
                    onChanged();
                  },
          )
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
    required this.hasAnyTask,
  });

  final int load;
  final int available;
  final int over;
  final DayCompletionStats stats;
  final int remainingMinutes;

  /// 应用是否完全没有任务：控制「目标剩余工作量」显示 `-- 分`（没计划）。
  final bool hasAnyTask;

  @override
  Widget build(BuildContext context) {
    final semantics = AppSemanticColors.of(context);
    // 无数据语义：今日无任务时「总计/完成」用 `--`，避免 0/0 误导；
    // 应用完全无任务时「目标剩余」也用 `--`（区分「没计划」与「已排完」）。
    final hasTodayTask = stats.totalCount > 0;
    return Card(
      child: ListTile(
        leading: Icon(
          over > 0 ? Icons.warning_amber_rounded : Icons.balance,
          color: over > 0 ? semantics.warning : null,
        ),
        title: Text(
          '今日任务总计 ${hasTodayTask ? DurationFormat.minutes(load) : '-- 分'}',
        ),
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('可用 ${DurationFormat.minutes(available)}'),
            if (over > 0)
              Text(
                '超出 ${DurationFormat.minutes(over)}，请调整任务或可用时间',
                style: TextStyle(color: semantics.warning),
              ),
            Text(
              '完成 ${hasTodayTask ? '${stats.doneCount}/${stats.totalCount}' : '-- / --'} · '
              '已完成 ${hasTodayTask ? DurationFormat.minutes(stats.doneMinutes) : '-- 分'} · '
              '目标剩余 ${hasAnyTask ? DurationFormat.minutes(remainingMinutes) : '-- 分'}',
            ),
          ],
        ),
        trailing: over > 0
            ? Icon(Icons.error_outline, color: semantics.warning)
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
            // 三个按钮统一为 FilledButton 家族（实心主操作 + tonal 次操作），
            // 避免混用 FilledButton/Outlined/TextButton 造成高度与视觉宽度不齐。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: onDeferNext,
                  child: const Text('延期至下一可用日'),
                ),
                FilledButton.tonal(
                  onPressed: onDeferPickDate,
                  child: const Text('选择日期…'),
                ),
                FilledButton.tonal(
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
        side: BorderSide(color: scheme.error.withValues(alpha: 0.30)),
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
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
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
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
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
          if (onAddTask != null) ...[
            FilledButton.icon(
              onPressed: onAddTask,
              icon: const Icon(Icons.add),
              label: const Text('添加任务'),
            ),
            const SizedBox(height: 8),
            // 引导小字：指向「计划」页的按周批量排期能力，降低空态迷失感。
            Text(
              '小提示：可以在「计划」页按周批量添加学习任务',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ],
      ),
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

class _CountdownCard extends ConsumerWidget {
  const _CountdownCard({required this.goal});

  final Goal goal;

  static const _countdown = CountdownService();
  static const _load = LoadService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(clockProvider)();
    final nextMilestone = ref.watch(nextUpcomingMilestoneProvider(goal.id));
    final settings = ref.watch(settingsProvider).valueOrNull;
    final (phase, days) = _countdown.evaluate(
      deadlineDate: goal.deadlineDate,
      today: today,
      status: goal.status,
    );
    final phaseIcon = switch (phase) {
      CountdownPhase.upcoming => Icons.schedule,
      CountdownPhase.today => Icons.today,
      CountdownPhase.overdue => Icons.error_outline,
      CountdownPhase.terminated => Icons.flag_outlined,
    };
    // 倒计时卡是「今日焦点」hero：品牌渐变背景 + 白字（对比度 ≥4.5，
    // 白/深绿对已由 contrast_test 的 onPrimary/primary 断言覆盖）。
    final onHero = Colors.white;
    final onHeroSoft = Colors.white.withValues(alpha: 0.88);

    // 学习日剩余：按「计划偏好」的每周可用日排除休息日（与目标详情页
    // 「学习日」口径一致），让首页倒计时与负载计算共享同一规则。
    final weekdays = settings == null
        ? const {1, 2, 3, 4, 5, 6, 7}
        : SettingsRepository.decodeWeekdays(settings.availableWeekdays);
    final studyDays = _load.remainingAvailableDays(
      deadlineDate: goal.deadlineDate,
      today: today,
      availableWeekdays: weekdays,
    );

    // 时间进度：已走过时长占（创建日 → 截止日）的比例，夹取 0~1。
    final deadline = parseLocalDate(goal.deadlineDate);
    final createdDay = DateUtils.dateOnly(goal.createdAt.toLocal());
    final todayDay = DateUtils.dateOnly(today);
    final totalDays = deadline.difference(createdDay).inDays;
    final elapsedDays = todayDay.difference(createdDay).inDays;
    final progress = totalDays <= 0
        ? 1.0
        : (elapsedDays / totalDays).clamp(0.0, 1.0).toDouble();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: const [kTimeCalcBrandDeep, kTimeCalcBrandBright],
          ),
        ),
        child: InkWell(
          onTap: () => context.push('/goals/${goal.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  goal.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onHero,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '截止 ${DateFormat('yyyy-MM-dd').format(parseLocalDate(goal.deadlineDate))}',
                  style: TextStyle(color: onHeroSoft, fontSize: 12),
                ),
                // 倒计时是 hero 的视觉焦点：大号数字 + 阶段图标，一眼抓住剩余量。
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(phaseIcon, size: 18, color: onHero),
                    const SizedBox(width: 6),
                    Text(
                      CountdownService.label(phase, days),
                      style: TextStyle(
                        color: onHero,
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                      ),
                    ),
                  ],
                ),
                // 时间进度条：已走过时长占比（创建日→截止日），每天打开首页
                // 直观感受「这段旅程走了多少」。
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
                const SizedBox(height: 4),
                // 学习日剩余（按计划偏好排除休息日），与目标详情页口径一致。
                Text(
                  '约 $studyDays 个学习日',
                  style: TextStyle(color: onHeroSoft, fontSize: 12),
                ),
                // FR-2.3：首页仅展示距离最近的一个未完成里程碑。
                if (nextMilestone.valueOrNull case final milestone?) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.flag_outlined, size: 14, color: onHeroSoft),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '下一里程碑：${milestone.title} · ${milestone.date}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: onHeroSoft, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
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
  return DateUtils.dateOnly(
    today,
  ).difference(DateUtils.dateOnly(planned)).inDays;
}
