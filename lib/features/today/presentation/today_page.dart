import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/providers/motion_provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/defer_service.dart';
import '../../../services/duration_format.dart';
import '../../../services/load_service.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/clash_hero.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../../shared/widgets/hoverable_card.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../../shared/widgets/progressive_rows.dart';
import '../../../shared/widgets/section_error_view.dart';
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

/// 今日负载卡进度环数值动画时长（v1.17）：比全局 motionSlow(320ms) 更慢
/// （800ms），勾选任务后进度滑落从容、松弛可辨；对称缓动 easeInOutCubic。
/// （v2 撞色重构后指标数字改由 ClashStatTile 直接呈现，时长仅进度环使用。）
const _kMetricAnimDuration = Duration(milliseconds: 800);

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
  static const _countdown = CountdownService();

  /// hero 区倒计时：取「最近截止」的活跃目标，与倒计时卡同一
  /// [CountdownService] 口径（同一次 evaluate，数值不完全另算）。
  ///
  /// **只回传（阶段, 天数），不回传 `CountdownService.label` 文案**：
  /// `剩余 N 天` / `今天截止` / `已逾期 N 天` 在页面上必须由倒计时卡的
  /// 撞色药丸唯一承载（goal_crud_widget_test 断言这些文案全页恰好出现
  /// 一次），hero 若再渲染同一文案就会重复。
  (CountdownPhase, int)? _heroCountdown(
    List<Goal> activeGoals,
    DateTime today,
  ) {
    if (activeGoals.isEmpty) return null;
    final nearest = activeGoals.reduce((a, b) {
      final da = tryParseLocalDate(a.deadlineDate) ?? DateTime(9999);
      final db = tryParseLocalDate(b.deadlineDate) ?? DateTime(9999);
      return da.isAfter(db) ? b : a;
    });
    return _countdown.evaluate(
      deadlineDate: nearest.deadlineDate,
      today: today,
      status: nearest.status,
    );
  }

  /// FR-3.7 横幅的会话级关闭（「保留原日期」），不写库。
  bool _bannerDismissed = false;

  @override
  Widget build(BuildContext context) {
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
            error: goalsAsync.hasError
                ? goalsAsync.error!
                : settingsAsync.error!,
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
    void onChanged() => invalidateAppData(ref.invalidate);

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
            ref.watch(subjectListProvider(gid)).valueOrNull ??
            const <Subject>[],
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
    final todayEmpty =
        todayTasks.isEmpty && !tasksLoading && tasksError == null;

    // 今日任务完成数：区块头计数与负载概览共用同一次遍历口径。
    final doneCount = todayTasks.where((t) => t.status == 'done').length;

    final viewport = MediaQuery.sizeOf(context).width;
    final pageInset = viewport > 1500
        ? (viewport - 1260) / 2
        : (viewport > 900 ? 28.0 : 16.0);
    return Stack(
      children: [
        CustomScrollView(
          // 头部区块：静态区块（概览/横幅/标题行等）用 SliverChildListDelegate
          // 一次性构建；进行中目标倒计时卡改为 ProgressiveRows 视口驱动懒构建
          // ——大目标量（批量导入）下每张卡还各自 watch 里程碑查询，只构建视口
          // 附近卡片，滚动到哪建到哪。今日任务列表在下方独立 Sliver 内，同样
          // 懒加载。
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                pageInset,
                AppTokens.spaceXl,
                pageInset,
                AppTokens.spaceLg,
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _TodayHeading(
                    today: today,
                    done: doneCount,
                    total: todayTasks.length,
                    countdown: _heroCountdown(activeGoals, today),
                  ),
                  // hero 与倒计时卡区间距：首屏高度敏感（今日任务列表与
                  // 逾期任务区必须留在首屏命中范围内），故用 spaceLg。
                  const SizedBox(height: AppTokens.spaceLg),
                  // 倒计时卡区块：有目标才显示，且首张卡必须常驻（视口最顶）。
                  // 卡片自带 bottom margin 12 提供行距。
                  if (activeGoals.isNotEmpty)
                    ProgressiveRows(
                      itemCount: activeGoals.length,
                      itemBuilder: (context, i) =>
                          _CountdownCard(goal: activeGoals[i]),
                    ),
                  if (activeGoals.isNotEmpty)
                    const SizedBox(height: AppTokens.spaceSm),
                  // 今日概览常驻：有活跃目标即显示（空态用 `--` 无数据语义），
                  // 把「今日计划量与完成度」前置到首页。
                  if (activeGoals.isNotEmpty) ...[
                    _StaggeredEntry(
                      index: 1,
                      child: _LoadOverviewCard(
                        load: load,
                        available: availableMinutes,
                        over: over,
                        stats: todayStats,
                        remainingMinutes: _stats.remainingMinutes(
                          activeTodoTasks,
                        ),
                        hasAnyTask: hasAnyTask,
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                  ],
                  if (unfinished.isEmpty && unfinishedError != null)
                    SectionErrorView(
                      error: unfinishedError,
                      onRetry: onRetryUnfinished,
                    ),
                  if (unfinished.isNotEmpty && !_bannerDismissed) ...[
                    _StaggeredEntry(
                      index: 2,
                      child: _UnfinishedBanner(
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
                                .deferMany(
                                  unfinished.map((t) => t.id).toList(),
                                  next,
                                ),
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
                        onKeepOriginal: () =>
                            setState(() => _bannerDismissed = true),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                  ],
                  // 区块头统一（v2 撞色重构）：待办主体＝暖色撞色块，
                  // count 徽标显示今日任务量，trailing 承载完成计数与入口。
                  // 空态时不重复右上角按钮：唯一的「添加任务」入口由空态大按钮承担。
                  ClashSectionHeader(
                    icon: Icons.checklist_rounded,
                    title: '今日任务',
                    tone: ClashTone.warm,
                    count: todayTasks.length,
                    trailing: todayEmpty
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${todayStats.doneCount}/${todayTasks.length}',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: ClashTones.of(
                                        context,
                                        ClashTone.warm,
                                      ).ink,
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
                      padding: EdgeInsets.only(bottom: AppTokens.spaceXs),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (todayTasks.isEmpty && tasksError != null)
                    SectionErrorView(error: tasksError, onRetry: onRetryTasks),
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
            // 今日任务列表：单卡分组行（v2 撞色重构）——一张白卡承载全部
            // 任务行（暖调细边框 + 暖投影），行间细分隔线，行内容由 TaskTile
            // （自身无卡）提供；行经 ProgressiveRows 视口驱动懒构建（同日
            // 二次卡顿修复 v2），大任务量导入不卡首帧、滚动按需构建。
            if (todayTasks.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  pageInset,
                  0,
                  pageInset,
                  AppTokens.pagePadding,
                ),
                sliver: SliverToBoxAdapter(
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: _clashCardDecoration(context),
                    child: ProgressiveRows(
                      itemCount: todayTasks.length,
                      itemBuilder: (context, i) => Column(
                        children: [
                          if (i > 0)
                            const Divider(height: 1, indent: 12, endIndent: 12),
                          TaskTile(
                            key: ValueKey('today-task-${todayTasks[i].id}'),
                            task: todayTasks[i],
                            goalTitle: goalsById[todayTasks[i].goalId]?.title,
                            subjects: subjectsByGoal[todayTasks[i].goalId],
                            onChanged: onChanged,
                            // 今日任务勾选即时完成（3afc8ac 起设计）：勾选仅划线、
                            // 不消失，写库后由 onChanged 统一刷新；不进入 5 秒撤回
                            // 批次（default enableCompleteUndo=false）。5 秒撤回
                            // FAB 仅服务过期任务区（下方 overdue 区传 true）。
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (unfinished.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pageInset, 0, pageInset, 80),
                sliver: SliverToBoxAdapter(
                  child: _OverdueTasksSection(
                    tasks: unfinished,
                    goalsById: goalsById,
                    subjectsByGoal: subjectsByGoal,
                    today: today,
                    onChanged: onChanged,
                  ),
                ),
              ),
          ],
        ),
        // 右下角批量撤销 FAB：圆形倒计时 + 撤回键。小尺寸悬浮于边角，
        // 不占满整行，因此不会像整宽 SnackBar 那样盖住正在点选的任务。
        Positioned(right: 16, bottom: 16, child: _UndoFab()),
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

/// 页面头部撞色英雄区（v2 撞色重构）：**暖×冷双撞色渐变**承载「日期 + 星期 +
/// 最近截止目标的倒计时天数 + 今日概览」，是首页第一眼的撞色锚点，也是全站
/// hero 的视觉标杆。
///
/// 文案口径：hero **不复述**倒计时卡里的 `CountdownService.label` 文案
/// （`剩余 N 天` / `今天截止` / `已逾期 N 天` 由倒计时卡的撞色药丸唯一承载），
/// 只把同一个倒计时**数字**以 hero 大字号呈现，阶段由图标承载——因此页面上
/// 不会出现重复文案（goal_crud_widget_test 断言这些文案全页唯一）。
class _TodayHeading extends StatelessWidget {
  const _TodayHeading({
    required this.today,
    required this.done,
    required this.total,
    required this.countdown,
  });
  final DateTime today;
  final int done;
  final int total;

  /// 最近截止目标的（阶段, 天数），与倒计时卡同源同口径；
  /// 无活跃目标时为 null，此时 hero 只展示日期与今日概览。
  final (CountdownPhase, int)? countdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    // hero 内前景色：撞色 hero 的默认前景已给白，这里取 warm.onFill 派生
    // 半透明层级，避免页面自己写死颜色（契约 §2 硬规则 2）。
    final onHero = ClashTones.of(context, ClashTone.warm).onFill;
    final countdown = this.countdown;
    Widget? countdownBlock;
    if (countdown != null) {
      final (phase, days) = countdown;
      // 倒计时数字：hero 主视觉大字号（headlineLarge）+ w700 + 等宽数字，
      // 让「还剩多少天」成为首页第一眼可读的量；阶段由撞色 hero 上的
      // 图标承载（状态不只靠颜色），完整文案留在倒计时卡的药丸里。
      countdownBlock = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_countdownPhaseIcon(phase), size: 18, color: onHero),
          const SizedBox(width: AppTokens.spaceSm),
          Text(
            '$days',
            style: theme.textTheme.headlineLarge?.copyWith(
              color: onHero,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    }
    return ClashHero(
      tone: ClashTone.warm,
      // 暖×冷双撞色渐变：首页的撞色身份标识。
      gradient: ClashGradient.clash(context),
      // 竖向留白收一档（spaceLg）：hero 信息变多的同时必须把首屏让给
      // 倒计时卡与今日任务列表（首页信息密度优先于大面积留白）。
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceXl,
        vertical: AppTokens.spaceLg,
      ),
      child: Row(
        // spaceBetween：右列是 Flexible（可被压缩，内容可能小于分配宽度），
        // 靠 spaceBetween 把右列顶到最右，保持「左信息 / 右数字」的对齐。
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${today.month}月${today.day}日 · 星期${weekdays[today.weekday - 1]}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: onHero.withValues(alpha: 0.90),
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '专注今天，向目标靠近',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: onHero,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.spaceMd),
          // Flexible（不是固定宽 Column）：系统放大字号（textScaler 2.0）下
          // 右列会变宽，必须允许它被压缩（内含 Text 自行换行），否则左列
          // Expanded 挤压不动、Row 直接溢出。
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (countdownBlock != null) ...[
                  countdownBlock,
                  const SizedBox(height: AppTokens.spaceXs),
                ],
                // 今日概览胶囊：hero 内的半透明白底，撞色渐变上的「轻容器」。
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceMd,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: onHero.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: onHero.withValues(alpha: 0.30)),
                  ),
                  child: Text(
                    total == 0 ? '留一点时间，给新的进步' : '今日已完成 $done / $total 项',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: onHero,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 今日负载概览（FR-3.5 / FR-7.1）。
///
/// 标题展示「今日任务总计 X 小时 Y 分」（当日未完成任务预估时长之和）；
/// 副标题展示可用时长，超出时追加「超出 X 分」文案与警告图标
/// （状态不只依赖颜色表达）。FR-7.1 展示今日完成数/总数、今日已完成
/// 预估时长与目标剩余工作量。
class _LoadOverviewCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cool = ClashTones.of(context, ClashTone.cool);
    final danger = ClashTones.of(context, ClashTone.danger);
    final motion = ref.watch(motionControllerProvider);
    // 无数据语义：今日无任务时「总计/完成」用 `-- 分`，避免 0/0 误导；
    // 应用完全无任务时「目标剩余」也用 `-- 分`（区分「没计划」与「已排完」）。
    final hasTodayTask = stats.totalCount > 0;
    final progress = hasTodayTask ? stats.doneCount / stats.totalCount : 0.0;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: _clashCardDecoration(context),
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 区块标题：数据/统计类区块＝冷色撞色块；超载时右侧警示 chip
          // （图标 + 文案 + 撞色，状态不只依赖颜色）。
          ClashSectionHeader(
            icon: over > 0 ? Icons.warning_amber_rounded : Icons.balance,
            title: '今日负载',
            tone: ClashTone.cool,
            dense: true,
            trailing: over > 0
                ? ClashChip(
                    label: '超出 ${DurationFormat.minutes(over)}',
                    tone: ClashTone.danger,
                    variant: ClashChipVariant.soft,
                    icon: Icons.warning_amber_rounded,
                  )
                : null,
          ),
          const SizedBox(height: AppTokens.spaceLg),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              // 撞色统计块行：暖＝今日待办总量，冷＝已完成/今日可用，
              // 点缀（citrus）＝目标剩余。数值与「无数据＝`-- 分`」语义
              // 与改造前完全一致，只换撞色承载。
              final tiles = <Widget>[
                ClashStatTile(
                  value: hasTodayTask ? DurationFormat.minutes(load) : '-- 分',
                  label: '今日总计',
                  tone: ClashTone.warm,
                  icon: Icons.timer_outlined,
                ),
                ClashStatTile(
                  value: hasTodayTask
                      ? DurationFormat.minutes(stats.doneMinutes)
                      : '-- 分',
                  label: '已完成',
                  tone: ClashTone.cool,
                  icon: Icons.check_circle_outline,
                ),
                ClashStatTile(
                  value: DurationFormat.minutes(available),
                  label: '今日可用',
                  tone: ClashTone.cool,
                  icon: Icons.schedule_outlined,
                  filled: false,
                ),
                ClashStatTile(
                  value: hasAnyTask
                      ? DurationFormat.minutes(remainingMinutes)
                      : '-- 分',
                  label: '目标剩余',
                  tone: ClashTone.citrus,
                  icon: Icons.flag_outlined,
                ),
              ];
              final metrics = LayoutBuilder(
                builder: (context, box) => Wrap(
                  spacing: AppTokens.spaceMd,
                  runSpacing: AppTokens.spaceMd,
                  children: [
                    for (final tile in tiles)
                      SizedBox(
                        width:
                            (box.maxWidth -
                                (wide
                                    ? AppTokens.spaceMd * 3
                                    : AppTokens.spaceMd)) /
                            (wide ? 4 : 2),
                        child: tile,
                      ),
                  ],
                ),
              );
              final ring = SizedBox(
                width: 74,
                height: 74,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: progress),
                  duration: motion.duration(_kMetricAnimDuration),
                  curve: motion.curve,
                  builder: (context, value, _) {
                    final animatedDone = (value * stats.totalCount).round();
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: CircularProgressIndicator(
                            value: hasTodayTask ? value : 0,
                            strokeWidth: 6,
                            strokeCap: StrokeCap.round,
                            // 进度＝冷色撞色（数据/进度），超载时转危险色。
                            backgroundColor: cool.soft,
                            valueColor: AlwaysStoppedAnimation(
                              over > 0 ? danger.fill : cool.fill,
                            ),
                          ),
                        ),
                        // 中心 N/M（等宽数字）：FittedBox 防系统放大字号时
                        // 撑爆 74px 固定环；环 + 分数即「完成比例」语义，
                        // 无需再叠「完成」小标签（与统计块「已完成」互补）。
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            hasTodayTask
                                ? '$animatedDone/${stats.totalCount}'
                                : '--',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: cool.ink,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              );
              if (!wide) return metrics;
              return Row(
                children: [
                  ring,
                  const SizedBox(width: AppTokens.spaceXl),
                  Expanded(child: metrics),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 今日页区块首屏错峰入场（2026-08-20 动效改造）。
///
/// 轻量版入场：淡入 + 8px 上滑，时长 [AppTokens.motionSlow]，按区块索引
/// 错峰 40ms（index 传 0/1/2…），首页区块依次浮现而非同时弹出。动画只在
/// 首帧触发一次（TweenAnimationBuilder 单次播放），数据刷新不重播；
/// 开启「减少动画」时直接显示（时长归零）。仅限首屏静态区块——懒加载
/// 任务行会随滚动动态创建，不得包裹（会随滚动重复播放）。
class _StaggeredEntry extends StatelessWidget {
  const _StaggeredEntry({required this.index, required this.child});

  /// 区块顺序：1 = 负载卡，2 = 横幅/任务区块头…（倒计时卡由
  /// [ProgressiveRows] 视口驱动懒构建，不参与首屏错峰入场，故无 index 0）。
  final int index;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(motionControllerProvider);
    if (motion.skipEntrance) return child;
    final delay = Duration(milliseconds: 40 * index);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppTokens.motionSlow,
      curve: AppTokens.motionCurve,
      // 错峰：动画总时长内按 index 推迟起始帧。
      onEnd: () {},
      builder: (context, value, child) {
        // 用延迟窗口计算有效进度：delay 前为 0（未出现），随后从 0 动画到 1。
        final elapsed =
            (AppTokens.motionSlow.inMilliseconds * value) -
            delay.inMilliseconds;
        final t = (elapsed / AppTokens.motionSlow.inMilliseconds).clamp(
          0.0,
          1.0,
        );
        return Opacity(
          opacity: Curves.easeOut.transform(t),
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - Curves.easeOut.transform(t))),
            child: child,
          ),
        );
      },
      child: child,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 逾期＝危险撞色（契约 §1 角色表）：浅色危险容器底 + 撞色描边 +
    // 撞色图标/文字，状态仍由文案与图标承载，不只靠颜色。
    final danger = ClashTones.of(context, ClashTone.danger);
    return Container(
      decoration: BoxDecoration(
        color: danger.soft,
        borderRadius: BorderRadius.circular(AppTokens.radiusXl),
        border: Border.all(color: ClashTones.tint(danger.ink, alpha: 0.32)),
        boxShadow: AppTokens.shadowCard(isDark),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg,
        AppTokens.spaceLg,
        AppTokens.spaceLg,
        AppTokens.spaceMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: ClashTones.tint(danger.ink, alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.event_busy, size: 18, color: danger.ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '昨日及更早有 $count 个未完成任务',
                      style: TextStyle(
                        color: danger.onSoft,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '原计划不会被自动更改，请选择处理方式',
                      style: TextStyle(
                        color: danger.onSoft.withValues(alpha: 0.85),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),
          // 三个操作分两级行动（2026-08-16 降噪）：主操作「延期至下一
          // 可用日」实心、次操作「选择日期」tonal，「保留原日期」为最弱
          // 的 TextButton——它是「暂不处理」，不该与延期同等抢眼。
          Wrap(
            spacing: AppTokens.spaceSm,
            runSpacing: AppTokens.spaceSm,
            children: [
              FilledButton.icon(
                onPressed: onDeferNext,
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('延期至下一可用日'),
              ),
              FilledButton.tonal(
                onPressed: onDeferPickDate,
                child: const Text('选择日期…'),
              ),
              TextButton(
                onPressed: onKeepOriginal,
                style: TextButton.styleFrom(foregroundColor: danger.onSoft),
                child: const Text('保留原日期'),
              ),
            ],
          ),
        ],
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
    final theme = Theme.of(context);
    final danger = ClashTones.of(context, ClashTone.danger);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: _clashCardDecoration(context),
      child: Stack(
        children: [
          // 左侧危险色警示带：提示逾期状态，但不再把整张卡染红，避免视觉过重。
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 3,
              color: ClashTones.tint(danger.ink, alpha: 0.40),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceMd,
              AppTokens.spaceMd,
              6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 区块头：逾期＝危险撞色；数量仍由「N 个未处理」撞色药丸承载。
                ClashSectionHeader(
                  icon: Icons.error_outline,
                  title: '过期任务',
                  tone: ClashTone.danger,
                  dense: true,
                  trailing: ClashChip(
                    label: '${tasks.length} 个未处理',
                    tone: ClashTone.danger,
                    variant: ClashChipVariant.soft,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text('以下任务原计划日期已过，请逐条延期或完成', style: theme.textTheme.bodySmall),
                const SizedBox(height: AppTokens.spaceSm),
                ProgressiveRows(
                  itemCount: tasks.length,
                  // 单卡分组行：任务之间细分隔线（与今日任务列表同形态），
                  // 分块渐进构建（过期任务无上限，防首帧全量 build）。
                  itemBuilder: (context, i) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (i > 0)
                        const Divider(height: 1, indent: 12, endIndent: 12),
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: ClashChip(
                          label:
                              '原计划 ${formatLocalDate(parseLocalDate(tasks[i].plannedDate))}'
                              ' · 已逾期 ${_overdueDays(today, tasks[i].plannedDate)} 天',
                          tone: ClashTone.danger,
                          variant: ClashChipVariant.soft,
                          dense: true,
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
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 右下角批量撤销 FAB：圆形倒计时动画 + 中央撤回键。
///
/// 取代原整宽底部 SnackBar：批次有任务时出现在右下角，尺寸小、不占满
/// 整行，故不会盖住正在勾选/取消勾选的任务。倒计时圆环随剩余秒数收缩，
/// 仅作视觉反馈；定稿仍由 [TaskCompletionController] 的计时器负责。
class _UndoFab extends ConsumerStatefulWidget {
  const _UndoFab();

  @override
  ConsumerState<_UndoFab> createState() => _UndoFabState();
}

class _UndoFabState extends ConsumerState<_UndoFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: TaskCompletionController.undoWindow,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 重置倒计时：并入新任务 / 批次重启时从头开始（与控制器滚动窗口同步）。
  void _resetCountdown() {
    _controller.duration = TaskCompletionController.undoWindow;
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Set<int>>(taskCompletionControllerProvider, (previous, next) {
      if ((previous?.length ?? 0) < next.length) _resetCountdown();
    });
    final batch = ref.watch(taskCompletionControllerProvider);
    final visible = batch.isNotEmpty;
    // 5 秒撤回＝暖色撞色（主动作）：圆环与中央按钮都走暖色 token，
    // 倒计时数值与定稿逻辑（[TaskCompletionController]）完全不动。
    final warm = ClashTones.of(context, ClashTone.warm);

    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      // 不可见时关闭命中，避免空白区误触。
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedScale(
          // 出现时轻微放大，配合淡入更顺滑，而非只做透明度渐隐。
          scale: visible ? 1.0 : 0.75,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 倒计时圆环：1（满环）→ 0（即将定稿）。value 必须在 builder 内按
                // _controller.value 逐帧取，避免捕获外层一次性局部变量导致
                // 圆环停在初始状态不动。
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => CircularProgressIndicator(
                    value: 1 - _controller.value,
                    strokeWidth: 3,
                    strokeCap: StrokeCap.round,
                    backgroundColor: ClashTones.tint(warm.fill, alpha: 0.14),
                    valueColor: AlwaysStoppedAnimation(warm.fill),
                  ),
                ),
                Center(
                  child: Tooltip(
                    message: '撤回 ${batch.length} 项勾选',
                    child: Material(
                      color: warm.fill,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      elevation: 2,
                      child: InkWell(
                        onTap: () => ref
                            .read(taskCompletionControllerProvider.notifier)
                            .undo(),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.undo_rounded,
                            color: warm.onFill,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 今日无任务空态（PRD §8：提供与页面相关的首个操作，非纯说明页）。
///
/// v2 撞色重构：空态改用共享的 [ClashEmptyState]（撞色圆底图标 + 标题 +
/// 动作），外层保留淡色容器让「今日任务」成为完整内容区域——
/// 撞色卡语言（radiusXl + 暖调细边框 + 暖投影）。
class _TodayEmptyView extends StatelessWidget {
  const _TodayEmptyView({required this.onAddTask});

  final VoidCallback? onAddTask;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onAddTask = this.onAddTask;
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: _clashCardDecoration(context),
      child: ClashEmptyState(
        icon: Icons.event_available,
        title: '今天没有安排',
        tone: ClashTone.cool,
        action: onAddTask == null
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    onPressed: onAddTask,
                    icon: const Icon(Icons.add),
                    label: const Text('添加任务'),
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  // 引导小字：指向「计划」页的按周批量排期能力，降低空态迷失感。
                  Text(
                    '小提示：可以在「计划」页按周批量添加学习任务',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
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
    final motion = ref.watch(motionControllerProvider);
    final (phase, days) = _countdown.evaluate(
      deadlineDate: goal.deadlineDate,
      today: today,
      status: goal.status,
    );
    final phaseIcon = _countdownPhaseIcon(phase);
    // 倒计时卡＝「今日焦点」白卡（v2 撞色）：暖调细边框 + 暖投影，
    // 目标名/时间进度走暖色撞色，倒计时徽标按阶段取撞色（剩余＝暖、
    // 今天截止＝点缀、已逾期＝危险、已结束＝冷），下一里程碑＝点缀。
    // 阶段与天数完全来自 [CountdownService]，只换配色与承载组件。
    final scheme = Theme.of(context).colorScheme;
    final warm = ClashTones.of(context, ClashTone.warm);
    final badgeTone = switch (phase) {
      CountdownPhase.upcoming => ClashTone.warm,
      CountdownPhase.today => ClashTone.citrus,
      CountdownPhase.overdue => ClashTone.danger,
      CountdownPhase.terminated => ClashTone.cool,
    };

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

    // 入场动效：淡入 + 自上方落位。用 TweenAnimationBuilder 直接写，不引入
    // 动画包（全站仅此一处入场动效，为此背一个依赖不划算）；位移是自身
    // 高度的 4%（分数位移，跨窗口尺寸稳定）。开启「减少动画」时 begin 与
    // end 相同，动画不启动即静止呈现。
    return TweenAnimationBuilder<double>(
      key: ValueKey('countdown-${goal.id}'),
      tween: Tween(begin: motion.skipEntrance ? 1.0 : 0.0, end: 1.0),
      duration: AppTokens.motionSlow,
      curve: AppTokens.motionCurve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: FractionalTranslation(
          translation: Offset(0, (1 - t) * -0.04),
          child: child,
        ),
      ),
      // 倒计时卡可点：hover 边框加深 + shadowCardHover 抬升 + 微上浮
      // （桌面交互反馈），与 HoverableCard 的水波纹叠加。
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
        child: HoverableCard(
          onTap: () => context.push('/goals/${goal.id}'),
          borderRadius: BorderRadius.circular(AppTokens.radiusXl),
          decoration: _clashCardDecoration(context),
          hoverBorderColor: ClashTones.tint(warm.ink, alpha: 0.50),
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行：目标名 + 右侧紧凑倒计时徽标。
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '进行中目标',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: AppTokens.spaceSm),
                          Text(
                            goal.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: warm.ink,
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '截止 ${formatLocalDate(parseLocalDate(goal.deadlineDate))}',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    // 紧凑倒计时徽标：与标题同行，字号收敛，避免「剩余 493 天」
                    // 独占大块面积导致视觉失衡；撞色药丸按阶段取色，
                    // 阶段语义同时由图标与文案承载（不只依赖颜色）。
                    ClashChip(
                      label: CountdownService.label(phase, days),
                      tone: badgeTone,
                      variant: ClashChipVariant.filled,
                      icon: phaseIcon,
                    ),
                  ],
                ),
                // 时间进度条：已走过时长占比（创建日→截止日），每天打开首页
                // 直观感受「这段旅程走了多少」。
                const SizedBox(height: AppTokens.spaceMd),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    borderRadius: BorderRadius.circular(4),
                    backgroundColor: ClashTones.tint(warm.ink, alpha: 0.14),
                    valueColor: AlwaysStoppedAnimation(warm.fill),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                // 学习日 + 下一里程碑：同一行浅色信息，降低视觉重量；
                // 里程碑＝点缀撞色（citrus）。
                Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(
                      '约 $studyDays 个学习日',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    if (nextMilestone.valueOrNull case final milestone?) ...[
                      const SizedBox(width: AppTokens.spaceMd),
                      Flexible(
                        child: ClashChip(
                          label: '${milestone.title} · ${milestone.date}',
                          tone: ClashTone.citrus,
                          variant: ClashChipVariant.soft,
                          icon: Icons.flag_outlined,
                          dense: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 全页空态（无进行中目标 / 今日无任务 / 无逾期任务）：用共享
/// [ClashEmptyState] 的撞色空态语言（撞色圆底图标 + 标题 + 说明 + 动作），
/// 文案与动作条件与改造前一致。
class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.hasAnyGoal, required this.onCreateGoal});

  final bool hasAnyGoal;
  final Future<void> Function() onCreateGoal;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ClashEmptyState(
          icon: Icons.today_outlined,
          title: '今天没有安排',
          message: hasAnyGoal ? '所有目标已结束或归档' : '创建一个目标，开始倒计时',
          tone: ClashTone.cool,
          action: hasAnyGoal
              ? null
              : FilledButton.icon(
                  onPressed: onCreateGoal,
                  icon: const Icon(Icons.add),
                  label: const Text('创建目标'),
                ),
        ),
      ),
    );
  }
}

/// 撞色卡片装饰（白卡 + 暖调细边框 + 暖投影）：今天页内所有卡片/行容器
/// 统一用它，保证「白卡浮于暖奶油底、撞色块浮于白卡上」的一致卡片语言
/// （契约 §5）；hover 抬升由 [HoverableCard] 的 shadowCardHover 提供。
BoxDecoration _clashCardDecoration(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: scheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(AppTokens.radiusXl),
    border: Border.all(
      color: isDark
          ? AppTokens.neutralBorderDark
          : AppTokens.neutralBorderLight,
    ),
    boxShadow: AppTokens.shadowCard(isDark),
  );
}

/// 倒计时阶段 → 图标（hero 与倒计时卡共用）：阶段语义由图标 + 文案承载，
/// 不只依赖颜色（NFR-4）。
IconData _countdownPhaseIcon(CountdownPhase phase) => switch (phase) {
  CountdownPhase.upcoming => Icons.schedule,
  CountdownPhase.today => Icons.today,
  CountdownPhase.overdue => Icons.error_outline,
  CountdownPhase.terminated => Icons.flag_outlined,
};

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
