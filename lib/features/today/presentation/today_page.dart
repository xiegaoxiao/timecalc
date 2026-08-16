import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/defer_service.dart';
import '../../../services/duration_format.dart';
import '../../../services/load_service.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/celebration_overlay.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../../shared/widgets/section_header.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/milestone_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../goals/presentation/goal_form_dialog.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_completion_controller.dart';
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

  /// v1.11 彩带：已触发过「今日任务全部完成」庆祝的标记（非全完成时复位），
  /// 避免每次刷新/操作重复播放骚扰用户。
  bool _celebratedDone = false;

  /// Telegram 式撤回 SnackBar 控制器：仅精确关闭本撤回条，避免误关
  /// 其它页面/流程弹出的 SnackBar（IndexedStack 下各页常驻，App 级
  /// ScaffoldMessenger 全局共享）。
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoSnackBar;

  @override
  Widget build(BuildContext context) {
    // 勾选完成 → 进入 5 秒撤回批次。SnackBar 单实例（2026-08-16 动画
    // 流畅度优化）：只在「空 → 非空」弹出、「非空 → 空」收起；批次增长时
    // 不再关旧开新（连续勾选时出入场动画反复启停是掉帧感的主要来源），
    // 计数与倒计时由内容组件 [_UndoSnackBarContent] 原地更新。
    ref.listen<Set<int>>(taskCompletionControllerProvider, (previous, next) {
      final wasEmpty = previous == null || previous.isEmpty;
      if (next.isEmpty) {
        // 批次清空（到期定稿 / 整批撤回）：收起撤回条。只关闭本撤回条，
        // 不影响其它页面/流程的 SnackBar；已自行关闭则 close 为 no-op。
        final current = _undoSnackBar;
        if (current != null) {
          _undoSnackBar = null;
          current.close();
        }
        return;
      }
      if (!wasEmpty && _undoSnackBar != null) return; // 已在展示：原地更新
      final messenger = ScaffoldMessenger.of(context);
      final snack = messenger.showSnackBar(
        SnackBar(
          // 关闭完全由批次状态驱动（上方 listener close）；不设短 duration
          // 抢在定稿前自动消失。此值仅作兜底（正常流程远早于 1 分钟收起）。
          duration: const Duration(minutes: 1),
          content: _UndoSnackBarContent(
            totalSeconds: TaskCompletionController.undoWindow.inSeconds,
          ),
          action: SnackBarAction(
            label: '撤回',
            onPressed: () {
              // 显式收起（undo() 清空批次时 listener 里引用已为 null，
              // 若不在此关闭会一直展示到兜底 duration）。
              final current = _undoSnackBar;
              _undoSnackBar = null;
              current?.close();
              ref.read(taskCompletionControllerProvider.notifier).undo();
            },
          ),
        ),
      );
      _undoSnackBar = snack;
      // 无论何种原因关闭（到期/撤回/手动关），都清理引用，避免再对其 close。
      unawaited(
        snack.closed.whenComplete(() {
          if (identical(_undoSnackBar, snack)) _undoSnackBar = null;
        }),
      );
    });

    final today = ref.watch(clockProvider)();
    final todayStr = formatLocalDate(today);

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
        body: PageSkeletons.todayPage(),
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
    // L13：进行中目标 id 集合——「目标剩余工作量」只汇总进行中目标的
    // 未完成任务，与倒计时（已结束/已归档停止计数）口径一致。
    final activeGoalIds = {for (final g in activeGoals) g.id};
    final activeTodoTasks = todoTasks
        .where((t) => activeGoalIds.contains(t.goalId))
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
    // 跨目标列表的科目名：父级一次性预取（按 goalId 去重），避免每个
    // TaskTile 各自 watch(subjectListProvider) + 线性扫描（N+1）。
    final goalIdsForSubjects = <int>{
      for (final t in todayTasks) t.goalId,
      for (final t in unfinished) t.goalId,
    };
    final subjectsByGoal = <int, List<Subject>>{
      for (final gid in goalIdsForSubjects)
        gid:
            ref.watch(subjectListProvider(gid)).valueOrNull ?? const <Subject>[],
    };
    final availableMinutes = settings.dailyAvailableMinutes;
    final load = _load.dayLoad(todayTasks);
    final over = _load.overMinutes(load: load, available: availableMinutes);
    // 今日完成统计：负载概览仪表盘与「今日任务」区块头计数共用一次计算。
    final todayStats = _stats.completionStats(todayTasks);
    final weekdays = SettingsRepository.decodeWeekdays(
      settings.availableWeekdays,
    );
    final addGoals = activeGoals.isNotEmpty ? activeGoals : goals;
    // 应用是否完全没有任务：决定「目标剩余工作量」显示 `-- 分`（没计划）
    // 还是实际数值（计划已满但全部完成）。只统计进行中目标的任务（L13）。
    final hasAnyTask = activeTodoTasks.isNotEmpty || todayTasks.isNotEmpty;
    // 今日任务区空态（显示 _TodayEmptyView）：此时标题行右上角按钮隐藏，
    // 由空态大按钮承担唯一「添加任务」入口，避免两个相同入口。
    final todayEmpty = todayTasks.isEmpty && !tasksLoading && tasksError == null;

    // 今日任务全部完成庆祝（v1.11）：从非全完成跃迁到全完成（且确有任务）
    // 时在 Overlay 层播一次彩带；首帧即全完成不触发，非全完成后复位标记。
    final doneCount = todayTasks.where((t) => t.status == 'done').length;
    final allDone = todayTasks.isNotEmpty && doneCount == todayTasks.length;
    if (allDone && !_celebratedDone) {
      _celebratedDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _celebratedDone) showCelebration(context);
      });
    } else if (!allDone && _celebratedDone) {
      _celebratedDone = false;
    }

    return CustomScrollView(
      // 头部区块（倒计时卡/概览/横幅/标题行等）用 SliverChildListDelegate
      // 一次性构建；今日任务列表用 SliverList.builder 懒加载——大任务量下
      // 只实例化视口内的任务行，滚动时按需构建（原 ListView(children:) 会
      // 一次性构建全部行）。
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
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
                  stats: todayStats,
                  remainingMinutes: _stats.remainingMinutes(activeTodoTasks),
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
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: today,
                      // L40：延期语义——只允许选今天及之后，禁止改期到过去
                      // （此前 firstDate 为去年，可把任务"延期"回过去再次逾期）。
                      firstDate: today,
                      lastDate: DateTime(today.year + 10),
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
                            formatLocalDate(picked),
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
                  subjectsByGoal: subjectsByGoal,
                  today: today,
                  onChanged: onChanged,
                ),
                const SizedBox(height: 8),
              ],
              // 区块头统一（2026-08-16 视觉升级）：与进度页同一 SectionHeader
              // 语言，trailing 承载完成计数与「添加任务」入口。
              // 空态时不重复右上角按钮：唯一的「添加任务」入口由空态大按钮承担。
              SectionHeader(
                icon: Icons.checklist_rounded,
                title: '今日任务',
                trailing: todayEmpty
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${todayStats.doneCount}/${todayTasks.length}',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
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
                ),
            ]),
          ),
        ),
        // 今日任务列表：单卡分组行（2026-08-16 视觉升级）——一张卡片承载
        // 全部任务行，行间细分隔线，行内容由 TaskTile（自身无卡）提供。
        // 取舍：放弃此前 SliverList.builder 的懒加载——单日任务量有限、
        // 勾选扇出已由 select 收窄覆盖，换取整卡一致的视觉形态。
        if (todayTasks.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverToBoxAdapter(
              child: Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < todayTasks.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 12, endIndent: 12),
                      TaskTile(
                        key: ValueKey('today-task-${todayTasks[i].id}'),
                        task: todayTasks[i],
                        goalTitle: goalsById[todayTasks[i].goalId]?.title,
                        subjects: subjectsByGoal[todayTasks[i].goalId],
                        onChanged: onChanged,
                        // 今日任务勾选走 5 秒撤回（Telegram 式）。
                        enableCompleteUndo: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
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
    final scheme = Theme.of(context).colorScheme;
    // 无数据语义：今日无任务时「总计/完成」用 `--`，避免 0/0 误导；
    // 应用完全无任务时「目标剩余」也用 `--`（区分「没计划」与「已排完」）。
    final hasTodayTask = stats.totalCount > 0;
    final progress = hasTodayTask ? stats.doneCount / stats.totalCount : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 区块标题：与进度页统计卡同一视觉语言（SectionHeader）；
            // 超载时右侧警示 chip（图标 + 文案，不只依赖颜色）。
            SectionHeader(
              icon: over > 0 ? Icons.warning_amber_rounded : Icons.balance,
              title: '今日负载',
              trailing: over > 0
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: semantics.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: semantics.warning,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '超出 ${DurationFormat.minutes(over)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: semantics.warning,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 今日完成进度环：品牌绿圆头弧 + 中心「N/M 完成」，
                // 值变化经 TweenAnimationBuilder 平滑过渡（勾选定稿后
                // 环会从旧比例滑到新比例，而非跳变）。
                SizedBox(
                  width: 72,
                  height: 72,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: progress),
                          duration: AppTokens.motionSlow,
                          curve: AppTokens.motionCurve,
                          builder: (context, value, _) =>
                              CircularProgressIndicator(
                                value: hasTodayTask ? value : 0,
                                strokeWidth: 6,
                                strokeCap: StrokeCap.round,
                                backgroundColor:
                                    scheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation(
                                  scheme.primary,
                                ),
                              ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 中心 N/M（等宽数字）：FittedBox 防系统放大字号时
                          // 撑爆 72px 固定环；环 + 分数即「完成比例」语义，
                          // 无需再叠「完成」小标签（与指标格「已完成」互补）。
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              hasTodayTask
                                  ? '${stats.doneCount}/${stats.totalCount}'
                                  : '--',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // 指标格 2×2：label + value（等宽数字，数值变化不抖动）。
                Expanded(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _MetricCell(
                            label: '今日总计',
                            value: hasTodayTask
                                ? DurationFormat.minutes(load)
                                : '-- 分',
                          ),
                          _MetricCell(
                            label: '可用时长',
                            value: DurationFormat.minutes(available),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _MetricCell(
                            label: '已完成',
                            value: hasTodayTask
                                ? DurationFormat.minutes(stats.doneMinutes)
                                : '-- 分',
                          ),
                          _MetricCell(
                            label: '目标剩余',
                            value: hasAnyTask
                                ? DurationFormat.minutes(remainingMinutes)
                                : '-- 分',
                          ),
                        ],
                      ),
                    ],
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

/// 负载概览指标格：小标签 + 等宽数字数值（2026-08-16 仪表盘化）。
class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
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
            // 三个操作分两级行动（2026-08-16 降噪）：主操作「延期至下一
            // 可用日」实心、次操作「选择日期」tonal，「保留原日期」为最弱
            // 的 TextButton——它是「暂不处理」，不该与延期同等抢眼。
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
                TextButton(
                  onPressed: onKeepOriginal,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  ),
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
    required this.subjectsByGoal,
    required this.today,
    required this.onChanged,
  });

  final List<Task> tasks;
  final Map<int, Goal> goalsById;
  final Map<int, List<Subject>> subjectsByGoal;
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
            for (var i = 0; i < tasks.length; i++) ...[
              // 单卡分组行：任务之间细分隔线（与今日任务列表同形态）。
              if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '原计划 ${formatLocalDate(parseLocalDate(tasks[i].plannedDate))}'
                  ' · 已逾期 ${_overdueDays(today, tasks[i].plannedDate)} 天',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
              TaskTile(
                // 按任务身份复用 element：定稿后区块收缩时，划线/透明度
                // 动画不会错播到相邻任务上（幻影动画）。
                key: ValueKey('overdue-task-${tasks[i].id}'),
                task: tasks[i],
                goalTitle: goalsById[tasks[i].goalId]?.title,
                subjects: subjectsByGoal[tasks[i].goalId],
                onChanged: onChanged,
                // 过期任务勾选同样走 5 秒撤回：期间保持勾选显示，5 秒后才消失。
                enableCompleteUndo: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 撤回 SnackBar 内容：「已勾选 N 项任务 · M 秒后自动完成」。
///
/// 单实例 SnackBar 的内容组件（2026-08-16 动画流畅度优化）：计数经
/// watch 批次 provider 原地更新；批次并入新任务时倒计时重置——与
/// [TaskCompletionController] 的滚动窗口一致。倒计时仅作视觉反馈，
/// 定稿本身仍由控制器的计时器负责，本组件不参与触发。
class _UndoSnackBarContent extends ConsumerStatefulWidget {
  const _UndoSnackBarContent({required this.totalSeconds});

  /// 撤回窗口总时长（秒）。
  final int totalSeconds;

  @override
  ConsumerState<_UndoSnackBarContent> createState() =>
      _UndoSnackBarContentState();
}

class _UndoSnackBarContentState extends ConsumerState<_UndoSnackBarContent> {
  late int _remaining;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _remaining = widget.totalSeconds;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        if (_remaining > 0) _remaining--;
        if (_remaining == 0) _ticker?.cancel();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // 并入新任务 → 重置倒计时（与控制器滚动窗口同步）。
    ref.listen<Set<int>>(taskCompletionControllerProvider, (previous, next) {
      if ((previous?.length ?? 0) < next.length) _startCountdown();
    });
    final count = ref.watch(taskCompletionControllerProvider).length;
    return Text('已勾选 $count 项任务 · $_remaining 秒后自动完成');
  }
}

/// 今日无任务空态（PRD §8：提供与页面相关的首个操作，非纯说明页）。
class _TodayEmptyView extends StatelessWidget {
  const _TodayEmptyView({required this.onAddTask});

  final VoidCallback? onAddTask;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          // 圆底图标语言与图表空态/今天页全页空态统一（v1.11 空态规范）。
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.event_available, size: 26, color: scheme.primary),
          ),
          const SizedBox(height: 12),
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
    // UTC 归一化天数差（L15）：本地 difference().inDays 在夏令时切换日
    // 可能差一天，与 countdown_service 的 _dayDiff 口径一致。
    final deadline = parseLocalDate(goal.deadlineDate);
    final createdDay = DateUtils.dateOnly(goal.createdAt.toLocal());
    final todayDay = DateUtils.dateOnly(today);
    final totalDays = _utcDayDiff(deadline, createdDay);
    final elapsedDays = _utcDayDiff(todayDay, createdDay);
    final progress = totalDays <= 0
        ? 1.0
        : (elapsedDays / totalDays).clamp(0.0, 1.0).toDouble();

    return Animate(
      key: ValueKey('countdown-${goal.id}'),
      effects: [
        FadeEffect(duration: AppTokens.motionSlow, curve: AppTokens.motionCurve),
        SlideEffect(
          begin: const Offset(0, -0.04),
          end: Offset.zero,
          duration: AppTokens.motionSlow,
          curve: AppTokens.motionCurve,
        ),
      ],
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusXl),
        ),
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
                  '截止 ${formatLocalDate(parseLocalDate(goal.deadlineDate))}',
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
                        // 等宽数字：倒计时天数逐日变化时数字列对齐不抖动。
                        fontFeatures: const [FontFeature.tabularFigures()],
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
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 主色通明圆底图标（与 ChartEmptyState 同一空态语言）。
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.today_outlined, size: 32, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          Text(
            '今天没有安排',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            hasAnyGoal ? '所有目标已结束或归档' : '创建一个目标，开始倒计时',
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
  return _utcDayDiff(DateUtils.dateOnly(today), planned);
}

/// 以「日历日」为单位计算 [a] - [b] 的天数（UTC 归一化，防 DST 偏差，L15）。
int _utcDayDiff(DateTime a, DateTime b) {
  final aDay = DateTime.utc(a.year, a.month, a.day);
  final bDay = DateTime.utc(b.year, b.month, b.day);
  return aDay.difference(bDay).inDays;
}
