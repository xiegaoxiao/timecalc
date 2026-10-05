import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Value;
import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/providers/motion_provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../../shared/widgets/hoverable_card.dart';
import '../../plan_import/presentation/plan_import_dialog.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/recurrence_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../data/goal_repository_provider.dart';
import '../data/milestone_repository_provider.dart';
import '../data/subject_repository_provider.dart';
import 'goal_form_dialog.dart';
import 'goal_section.dart';

/// 各目标任务完成统计（目标卡片进度条与统计行用）。
///
/// 依赖 [goalListProvider] 的目标集合，一次批量 SQL（[TaskRepository.completionByGoals]）
/// 避免逐卡查询的 N+1；目标变更（invalidateAppData）时随 goalList 一同失效。
final goalCompletionProvider =
    FutureProvider<
      Map<int, ({int total, int done, int totalMinutes, int doneMinutes})>
    >((ref) async {
      final goals = await ref.watch(goalListProvider.future);
      final ids = goals.map((g) => g.id).toList();
      if (ids.isEmpty) return const {};
      return ref.watch(taskRepositoryProvider).completionByGoals(ids);
    });

/// 目标页：目标列表（FR-1 目标 CRUD 入口）。
///
/// v1.12 起从计划页拆分为独立一级导航：底部导航「目标」进入本页，
/// 计划页退化为纯日历。无 AppBar（与今天页一致，左上角干净）；
/// 「导入完整计划」入口在区块头（原 AppBar actions 迁入），「新建目标」
/// 按钮同为区块头主操作。
class GoalListPage extends ConsumerWidget {
  const GoalListPage({super.key});

  /// 打开创建对话框；创建成功后自动进入目标详情页，引导继续添加任务。
  Future<void> _createGoal(BuildContext context) async {
    final createdId = await GoalFormDialog.show(context);
    if (createdId != null && context.mounted) {
      context.push('/goals/$createdId');
    }
  }

  /// 打开「导入完整计划」对话框；导入成功（返回新建目标 id）后跳转详情。
  Future<void> _importPlan(BuildContext context) async {
    final createdId = await PlanImportDialog.show(context);
    if (createdId != null && context.mounted) {
      context.push('/goals/$createdId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: GoalListBody(
        onCreateGoal: () => _createGoal(context),
        onImportPlan: () => _importPlan(context),
      ),
    );
  }
}

/// 目标列表主体（无 Scaffold）：空态 / 错误 / 目标卡片列表。
///
/// [onCreateGoal] 为空时，空态按钮回退为内置的创建流程。
class GoalListBody extends ConsumerWidget {
  const GoalListBody({super.key, this.onCreateGoal, this.onImportPlan});

  final Future<void> Function()? onCreateGoal;

  /// 打开「导入完整计划」对话框（区块头入口，原 AppBar actions 迁入）。
  final Future<void> Function()? onImportPlan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(goalListProvider);
    return goalsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppErrorView(
        error: error,
        onRetry: () => ref.invalidate(goalListProvider),
      ),
      data: (goals) {
        // 各目标任务完成统计：父级一次性预取（批量 SQL，避免逐卡 N+1），
        // 供卡片进度条与统计行使用；数据未就绪时显示 0% 占位。
        // 空态不发起查询（goals 为空时 provider 本就返回空 map）。
        final completion = goals.isEmpty
            ? const <
                int,
                ({int total, int done, int totalMinutes, int doneMinutes})
              >{}
            : ref.watch(goalCompletionProvider).valueOrNull ?? const {};
        // 顶部统计（进行中 / 已完成 / 全部）：把「目标页」从孤零零的
        // 卡片列表升级为 Dashboard——一眼看清目标池规模（Todoist 式）。
        final activeCount = goals
            .where((g) => g.status == GoalStatus.active)
            .length;
        final completedCount = goals
            .where((g) => g.status == GoalStatus.completed)
            .length;
        // 矮窗口（如 500×400 视口）压缩「固定头部」：撞色统计块切 dense 形态、
        // 头部与统计行的间距各收一档。原因：列表行是视口驱动的懒构建，
        // 只有落在视口内（而非缓存区）的行才会被算作「屏上可见」；头部过高
        // 会把首张目标卡挤出首屏。高窗口（≥640）完全走原样，视觉不受影响。
        final compactChrome = MediaQuery.sizeOf(context).height < 640;
        final headPad = compactChrome ? AppTokens.spaceMd : AppTokens.spaceXl;
        return CustomScrollView(
          slivers: [
            // 区块头（Dashboard 语言，2026-08-16 统一为 ClashSectionHeader）：
            // 页面主标题 + 导入完整计划 + 新建目标入口（取代原 FAB 与
            // AppBar actions）。始终显示——空态也要能导入完整计划/新建目标。
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  headPad,
                  headPad,
                  headPad,
                  compactChrome ? AppTokens.spaceSm : AppTokens.pagePadding,
                ),
                child: ClashSectionHeader(
                  icon: Icons.flag_outlined,
                  title: '我的目标',
                  // 目标页是品牌主动作页：区块头取暖色撞色。
                  tone: ClashTone.warm,
                  // 空态时不重复放「新建目标」（空态大按钮是唯一主入口，
                  // 避免两个『创建目标』tooltip 歧义）；非空态显示。
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (onImportPlan != null)
                        IconButton(
                          tooltip: '导入完整计划',
                          onPressed: onImportPlan,
                          icon: const Icon(Icons.upload_file_outlined),
                        ),
                      if (goals.isNotEmpty) ...[
                        const SizedBox(width: AppTokens.spaceXs),
                        // tooltip 保留旧语义，兼容既有测试与无障碍。
                        Tooltip(
                          message: '创建目标',
                          child: FilledButton.icon(
                            onPressed:
                                onCreateGoal ?? () => _defaultCreate(context),
                            icon: const Icon(Icons.add),
                            label: const Text('新建目标'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (goals.isEmpty)
              // 空态：占满剩余高度（hasScrollBody: false），内容高于剩余
              // 高度时整页可滚，不溢出。
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyView(onCreateGoal: onCreateGoal),
              )
            else ...[
              // 顶部统计块：进行中 / 已完成 / 全部（撞色统计小块，
              // 冷/暖/点缀三色各自承担一个计数情绪）。
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    headPad,
                    0,
                    headPad,
                    compactChrome ? AppTokens.spaceSm : AppTokens.spaceMd,
                  ),
                  child: Wrap(
                    spacing: compactChrome
                        ? AppTokens.spaceSm
                        : AppTokens.spaceLg,
                    runSpacing: compactChrome
                        ? AppTokens.spaceXs
                        : AppTokens.spaceSm,
                    children: [
                      // 统计块内部是 mainAxisSize.max 的行，直接放进 Wrap 会
                      // 各占满整行、竖着堆成三行（矮窗口下把首张目标卡挤出
                      // 首屏）；故显式限宽，让三块并排一行。
                      SizedBox(
                        width: compactChrome ? 92 : 148,
                        child: ClashStatTile(
                          value: '$activeCount',
                          label: '进行中',
                          tone: ClashTone.warm,
                          icon: Icons.play_circle_outline,
                          filled: false,
                          dense: compactChrome,
                        ),
                      ),
                      SizedBox(
                        width: compactChrome ? 92 : 148,
                        child: ClashStatTile(
                          value: '$completedCount',
                          label: '已完成',
                          tone: ClashTone.citrus,
                          icon: Icons.emoji_events_outlined,
                          filled: false,
                          dense: compactChrome,
                        ),
                      ),
                      SizedBox(
                        width: compactChrome ? 92 : 148,
                        child: ClashStatTile(
                          value: '${goals.length}',
                          label: '全部',
                          tone: ClashTone.cool,
                          icon: Icons.flag_outlined,
                          filled: false,
                          dense: compactChrome,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverLayoutBuilder(
                builder: (context, constraints) {
                  // 列数判定沿用旧口径（可用宽度 ≥900 且未放大字号时双列）。
                  final columns =
                      constraints.crossAxisExtent >= 900 &&
                          MediaQuery.textScalerOf(context).scale(14) < 23
                      ? 2
                      : 1;
                  final rows = (goals.length / columns).ceil();
                  return SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      AppTokens.spaceXl,
                      compactChrome ? AppTokens.spaceXs : AppTokens.spaceSm,
                      AppTokens.spaceXl,
                      AppTokens.spaceXl,
                    ),
                    sliver: SliverList.separated(
                      itemCount: rows,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppTokens.spaceLg),
                      itemBuilder: (context, row) => Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var col = 0; col < columns; col++) ...[
                            if (col > 0)
                              const SizedBox(width: AppTokens.spaceLg),
                            Expanded(
                              child: row * columns + col < goals.length
                                  ? Align(
                                      alignment: Alignment.topLeft,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 600,
                                        ),
                                        child: _GoalCard(
                                          goal: goals[row * columns + col],
                                          completion:
                                              completion[goals[row * columns +
                                                      col]
                                                  .id],
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  /// 回退创建流程：无 [onCreateGoal]（空态按钮）时的内置行为。
  Future<void> _defaultCreate(BuildContext context) async {
    final createdId = await GoalFormDialog.show(context);
    if (createdId != null && context.mounted) {
      context.push('/goals/$createdId');
    }
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({this.onCreateGoal});

  final Future<void> Function()? onCreateGoal;

  Future<void> _createGoal(BuildContext context) async {
    if (onCreateGoal != null) {
      await onCreateGoal!();
      return;
    }
    final createdId = await GoalFormDialog.show(context);
    if (createdId != null && context.mounted) {
      context.push('/goals/$createdId');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 数据为空时提供与当前页相关的首个操作（PRD §8）。
    // 撞色空态（暖色圆底图标 + 主文案 + 说明 + 主行动），
    // 与今天页/进度页空态共用同一语言（v2.0 空态规范）。
    return ClashEmptyState(
      icon: Icons.flag_outlined,
      title: '还没有目标',
      message: '创建一个目标，把截止日期变成今天的行动',
      tone: ClashTone.warm,
      // tooltip 与区块头「新建目标」一致，供既有测试与无障碍定位。
      action: Tooltip(
        message: '创建目标',
        child: FilledButton.icon(
          onPressed: () => _createGoal(context),
          icon: const Icon(Icons.add),
          label: const Text('创建目标'),
        ),
      ),
    );
  }
}

/// 目标概览卡片：标题、截止状态、单一进度条和紧凑时长摘要。
class _GoalCard extends ConsumerStatefulWidget {
  const _GoalCard({required this.goal, this.completion});

  final Goal goal;

  /// 该目标任务完成统计（null = 数据未就绪，进度显示 0% 占位）。
  final ({int total, int done, int totalMinutes, int doneMinutes})? completion;

  @override
  ConsumerState<_GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends ConsumerState<_GoalCard> {
  /// 详情页导航进行中标志（双击去重）：250ms 窗口内重复点击卡片/
  /// 「查看详情」只 push 一次，避免压入两个相同详情页（需按两次返回）。
  bool _navInFlight = false;

  /// 去重窗口计时器（dispose 取消，防 widget 测试 pending timer）。
  Timer? _navGuard;

  /// 转发到 widget 字段：保持下方方法体 `goal.`/`completion` 引用不变。
  Goal get goal => widget.goal;
  ({int total, int done, int totalMinutes, int doneMinutes})? get completion =>
      widget.completion;

  static const _countdown = CountdownService();

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(clockProvider)();
    final motion = ref.watch(motionControllerProvider);
    final (phase, days) = _countdown.evaluate(
      deadlineDate: goal.deadlineDate,
      today: today,
      status: goal.status,
    );

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 状态撞色（契约 §1）：进行中=暖、已完成=点缀、逾期/放弃=危险、归档=冷。
    final tone = goalClashTone(goal, phase);
    final t = ClashTones.of(context, tone);
    final isDark = theme.brightness == Brightness.dark;

    final done = completion?.done ?? 0;
    final total = completion?.total ?? 0;
    final progress = total == 0 ? 0.0 : done / total;
    final percent = progress > 0 && progress < 0.01
        ? (progress * 100).toStringAsFixed(1)
        : (progress * 100).round().toString();
    final doneMinutes = completion?.doneMinutes ?? 0;
    final totalMinutes = completion?.totalMinutes ?? 0;
    final remainingMinutes = totalMinutes - doneMinutes;

    return HoverableCard(
      onTap: () => _openDetail(context, ref),
      hoverElevate: false,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTokens.radiusXl),
        // 边框取撞色淡色：卡片整体带上该目标的状态色温。
        border: Border.all(color: ClashTones.tint(t.ink, alpha: 0.30)),
        boxShadow: AppTokens.shadowCard(isDark),
      ),
      child: Stack(
        children: [
          // 左侧 4px 撞色竖条：卡片的状态色标（NFR-4：状态另有倒计时文字
          // 与进度文案承载，不只依赖颜色）。
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(color: t.ink),
          ),
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceXl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        goal.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    PopupMenuButton<String>(
                      tooltip: '目标操作',
                      onSelected: (action) =>
                          _handleAction(context, ref, action),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(
                          value: 'complete',
                          child: Text('标记已完成'),
                        ),
                        PopupMenuItem(
                          value: 'abandon',
                          child: Text('标记已放弃'),
                        ),
                        PopupMenuItem(value: 'archive', child: Text('归档')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Wrap(
                  spacing: AppTokens.spaceMd,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // 截止日倒计时：撞色药丸（逾期=危险实心、今日/临近=暖、
                    // 已结束=冷）。文字仍是状态的第一承载，颜色只是加强。
                    ClashChip(
                      label: CountdownService.label(phase, days),
                      tone: countdownClashTone(phase),
                      dense: true,
                      icon: switch (phase) {
                        CountdownPhase.upcoming => Icons.schedule,
                        CountdownPhase.today => Icons.today,
                        CountdownPhase.overdue => Icons.error_outline,
                        CountdownPhase.terminated => Icons.flag_outlined,
                      },
                      variant:
                          phase == CountdownPhase.overdue ||
                              phase == CountdownPhase.today
                          ? ClashChipVariant.filled
                          : ClashChipVariant.soft,
                    ),
                    Text(
                      '截止 ${_dotDate(parseLocalDate(goal.deadlineDate))}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceXl),
                Row(
                  children: [
                    // 进度环：底色 = 撞色淡色（ClashTones.tint）、前景 = 撞色
                    // ink，环心为完成百分比（卡片上视觉重量最高的数字）。
                    _ProgressRing(
                      progress: progress,
                      percent: percent,
                      tone: tone,
                    ),
                    const SizedBox(width: AppTokens.spaceLg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('任务进度', style: theme.textTheme.bodySmall),
                          const SizedBox(height: AppTokens.spaceSm),
                          TweenAnimationBuilder<double>(
                            tween: Tween(end: progress),
                            duration: motion.duration(
                              const Duration(milliseconds: 200),
                            ),
                            builder: (context, value, _) =>
                                LinearProgressIndicator(
                                  value: value,
                                  minHeight: 5,
                                  borderRadius: BorderRadius.circular(4),
                                  backgroundColor: ClashTones.tint(t.ink),
                                  color: t.ink,
                                ),
                          ),
                          const SizedBox(height: AppTokens.spaceSm),
                          Text(
                            total == 0 ? '尚未安排任务' : '已完成 $done / $total 项任务',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceXl),
                Row(
                  children: [
                    Expanded(
                      child: _CardStat(
                        title: '已投入',
                        value: total == 0
                            ? '--'
                            : DurationFormat.minutes(doneMinutes),
                        tone: tone,
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceLg),
                    Expanded(
                      child: _CardStat(
                        title: '待投入',
                        value: total == 0
                            ? '--'
                            : DurationFormat.minutes(remainingMinutes),
                        tone: tone,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceLg),
                const Divider(),
                const SizedBox(height: AppTokens.spaceSm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _openDetail(context, ref),
                    icon: const Text('查看详情'),
                    label: const Icon(Icons.arrow_forward, size: 16),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 本地日期 → `yyyy.MM.dd` 点分格式（区间展示更紧凑）。
  static String _dotDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}.$mm.$dd';
  }

  /// 打开详情页：**立即导航 + 后台预热数据**（2026-08-16 二次卡顿修复）。
  ///
  /// 此前「数据先到再导航」（await 预取，最多 800ms 兜底）在真实文件库上
  /// 把查询延迟直接转嫁成点击响应延迟——点卡片后数百毫秒无任何反馈，
  /// 感知为「卡」（内存库测试测不出：查询微秒级）。现改为：点击瞬间
  /// push（150ms 淡入与数据加载并行），预取在后台继续填充 provider
  /// 缓存；数据未就绪时详情页静态骨架兜底（无闪烁，数据到达自然替换）。
  void _openDetail(BuildContext context, WidgetRef ref) {
    // 双击去重：快速重复点击（250ms 窗口）只 push 一次。计时器持有并
    // 在 dispose 取消——widget 测试会因 pending timer 失败。
    if (_navInFlight) return;
    _navInFlight = true;
    _navGuard?.cancel();
    _navGuard = Timer(const Duration(milliseconds: 250), () {
      _navInFlight = false;
      _navGuard = null;
    });
    // 后台预热（不阻塞导航）：失败/慢查询由详情页骨架/错误态兜底，
    // 异常不冒泡为未处理异步错误。
    unawaited(_prefetchDetail(ref, goal.id).catchError((Object _) {}));
    context.push('/goals/${goal.id}');
  }

  @override
  void dispose() {
    _navGuard?.cancel();
    super.dispose();
  }

  /// 预热详情页数据源（P3.5 卡顿排查；2026-08-16 起后台执行、不设超时）。
  ///
  /// 详情页首载同时 watch 目标详情/任务列表/科目列表/里程碑列表四个
  /// provider，各自独立查询库（后台 isolate 不阻塞 UI）。点击瞬间触发
  /// 查询，页面进入时数据多已缓存，首帧直接渲染内容；未就绪时骨架兜底。
  Future<void> _prefetchDetail(WidgetRef ref, int goalId) async {
    final futures = <Future<Object?>>[
      ref.read(goalDetailProvider(goalId).future),
      ref.read(taskListProvider(goalId).future),
      ref.read(subjectListProvider(goalId).future),
      ref.read(milestoneListProvider(goalId).future),
      // 详情页进入后立即依赖的次级数据源也一并预热：负载区
      // （settingsProvider）与任务区重复模板标注
      // （recurrenceTemplatesProvider）。此前漏预取 → 进入后二次查询
      // 触发对应区块重建（骨架→内容跳变，感知为卡顿）。
      ref.read(settingsProvider.future),
      ref.read(recurrenceTemplatesProvider(goalId).future),
    ];
    // 后台预热无需超时（旧 800ms 超时是为「await 后再 push」兜底的，
    // 现在不等待也就没有可超时的东西）：查询完成即入缓存，慢查询
    // 不拖累已完成的项。
    await Future.wait(futures);
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final repo = ref.read(goalRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'edit':
        await GoalFormDialog.show(context, goal: goal);
        break;
      case 'complete':
        final ok = await runDbAction(
          context,
          action: () => repo.update(
            id: goal.id,
            status: 'completed',
            // 走 clockProvider（可注入/固定时钟），避免 UI 层裸 DateTime.now()
            // 绕过注入时钟，导致完成时间无法在测试中精确断言。
            completedAt: Value(ref.read(clockProvider)().toUtc()),
          ),
        );
        if (!ok) return;
        _refreshGoalRelated(ref);
        messenger.showSnackBar(
          SnackBar(content: Text('「${goal.title}」已标记为完成')),
        );
        break;
      case 'abandon':
        final ok = await runDbAction(
          context,
          action: () => repo.update(id: goal.id, status: 'abandoned'),
        );
        if (!ok) return;
        _refreshGoalRelated(ref);
        messenger.showSnackBar(
          SnackBar(content: Text('「${goal.title}」已标记为放弃')),
        );
        break;
      case 'archive':
        final ok = await runDbAction(
          context,
          action: () => repo.update(id: goal.id, status: 'archived'),
        );
        if (!ok) return;
        _refreshGoalRelated(ref);
        messenger.showSnackBar(SnackBar(content: Text('「${goal.title}」已归档')));
        break;
      case 'delete':
        await _confirmDelete(context, ref);
        break;
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    // FR-1 验收：删除目标前必须二次确认，并明确提示将同时删除其任务。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除目标？'),
        content: Text('将删除「${goal.title}」及其全部任务。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final repo = ref.read(goalRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.deleteWithCascade(goal.id),
    );
    if (!ok) return;
    _refreshGoalRelated(ref);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('「${goal.title}」及其任务已删除')));
    }
  }

  /// 目标变更/删除后统一刷新：公共集合见 [invalidateAppData]，再追加目标
  /// 详情与重复模板族（级联删除会连带删模板，避免残留陈旧缓存）。保证跨页
  /// 数据一致（FR-3 验收）。
  void _refreshGoalRelated(WidgetRef ref) {
    invalidateAppData(ref.invalidate);
    ref.invalidate(goalDetailProvider);
    // 目标级联删除会连带删除其重复模板（recurrence_repository.deleteWithCascade），
    // 模板缓存必须同步失效，避免删除后残留陈旧模板数据。
    ref.invalidate(recurrenceTemplatesProvider);
  }
}

/// 卡片统计块：小号标题在上、加粗数值在下（Todoist/Linear 风格信息层级）。
///
/// 标题用次级色、数值用**该目标的撞色**，形成「先看数值、再看语义」的阅读
/// 顺序；数值统一等宽数字，完成数/时长逐日变化时列对齐不抖动。
class _CardStat extends StatelessWidget {
  const _CardStat({
    required this.title,
    required this.value,
    required this.tone,
  });

  final String title;
  final String value;

  /// 卡片所属撞色角色（与进度环/竖条同色，保证同一张卡一个情绪）。
  final ClashTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = ClashTones.of(context, tone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: t.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 卡片进度环：环底 = 撞色淡色（[ClashTones.tint]）、前景 = 撞色 ink，
/// 环心显示完成百分比。与卡内线性进度条同色，二者共同表达「总进度」。
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.progress,
    required this.percent,
    required this.tone,
  });

  final double progress;

  /// 完成百分比数值文本（不含 `%`，渲染时补上）。
  final String percent;
  final ClashTone tone;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 5,
              backgroundColor: ClashTones.tint(t.ink),
              valueColor: AlwaysStoppedAnimation<Color>(t.ink),
            ),
          ),
          Text(
            '$percent%',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: t.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
