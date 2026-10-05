import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/duration_format.dart';
import '../../../services/statistics_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../../shared/widgets/hoverable_card.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';

/// 热力图完成强度色阶不再使用固定的 LeetCode 绿：改为**单一撞色（冷）的明度
/// 递进**，由 [_HeatmapSection] 在 build 内按当前主题解析一次（见 `_heatRamp`），
/// 五档同色相、只差明度，三套撞色方案与深浅模式全自动跟随。

/// 复用单一 DateFormat 实例（Intl 格式化非 const 可构造，逐格/逐任务
/// 新建会引入不必要的日期符号与语言环境解析开销）。
final _ymd = DateFormat('yyyy-MM-dd');
final _md = DateFormat('M/d');
final _hm = DateFormat('HH:mm');

/// 进度页（M3）：基础统计、燃尽趋势与热力图（FR-7.1 / FR-7.2 / FR-7.3 / FR-7.4）。
///
/// 结构（自上而下）：
/// 1. 今日概览：今日完成数/总数、今日已完成预估时长、目标剩余工作量；
/// 2. 燃尽趋势（FR-7.3）：从今天起到最晚截止日的「剩余预估时长」计划燃尽
///    曲线（今日点 = 当前剩余；按最晚截止日线性递减），避免展示无意义的
///    历史平线；
/// 3. 热力图：按「完成日期」统计最近 26 周完成任务数量（**单一冷色明度递进**
///    色阶，tooltip 与图例文本，状态不只依赖颜色，NFR-4）；
/// 4. FR-7.4 说明：无预估时长的任务只计入任务数。
/// 进度页各图表的数据聚合（P 优化）。
///
/// 旧版 ProgressPage 在 build 里 watch 4 个任务类 provider、四层嵌套 .when，
/// 任一 provider 变化（如勾选一个任务 → invalidateAppData 全量失效）都会
/// 整页重算全部聚合。现拆为独立 provider：
/// - [progressTasksProvider]：把「全部未完成 + 26 周完成」合并为一次就绪，
///   页面只剩 goals + tasks 两层加载门；
/// - 概览/热力图/燃尽各 watch 自己依赖的子集，任一输入变化只重算
///   受影响区块（对应区块组件独立重建，互不连带）。
const _progressStats = StatisticsService();

/// 进度页任务数据：全部未完成 + 最近 26 周完成，一次就绪。
final progressTasksProvider = FutureProvider<({
  List<Task> todo,
  List<Task> completed,
})>((ref) async {
  // 并行发起两个查询（L38）：drift 查询各自在后台执行，避免串行等待。
  final todoFuture = ref.watch(allTodoTasksProvider.future);
  final completedFuture = ref.watch(completedTasksProvider.future);
  final todo = await todoFuture;
  final completed = await completedFuture;
  return (todo: todo, completed: completed);
});

/// 今日概览数据（FR-7.1）：仅依赖今日任务 + 进度任务。
final progressOverviewProvider = Provider<({
  DayCompletionStats stats,
  int remainingMinutes,
  bool hasAnyTask,
})?>((ref) {
  final todayStr = _ymd.format(ref.watch(clockProvider)());
  final todayTasks = ref.watch(tasksByDateProvider(todayStr)).valueOrNull;
  final tasks = ref.watch(progressTasksProvider).valueOrNull;
  if (todayTasks == null || tasks == null) return null;
  // 目标剩余工作量只统计进行中目标（2026-08-14 审查 #2，与今天页 L13
  // 口径一致）：已完成/放弃/归档目标的残留 todo 任务不再计入，避免
  // 两页显示不同数字。燃尽仍为全局趋势（不在此过滤）。
  final activeGoalIds = {
    for (final g in ref.watch(goalListProvider).valueOrNull ?? const <Goal>[])
      if (g.status != GoalStatus.completed &&
          g.status != GoalStatus.abandoned &&
          g.status != GoalStatus.archived)
        g.id,
  };
  final activeTodo = tasks.todo
      .where((t) => activeGoalIds.contains(t.goalId))
      .toList();
  return (
    stats: _progressStats.completionStats(todayTasks),
    remainingMinutes: _progressStats.remainingMinutes(activeTodo),
    hasAnyTask: tasks.todo.isNotEmpty || tasks.completed.isNotEmpty,
  );
});

/// 热力图数据（FR-7.2）：仅依赖已完成任务。
final progressHeatmapProvider = Provider<({
  Map<String, int> counts,
  Map<String, List<Task>> byDate,
  List<DateTime> weekStarts,
})?>((ref) {
  final completed = ref.watch(progressTasksProvider).valueOrNull?.completed;
  if (completed == null) return null;
  final byDate = _progressStats.completedTasksByLocalDate(completed);
  return (
    counts: {for (final e in byDate.entries) e.key: e.value.length},
    byDate: byDate,
    weekStarts: StatisticsService.recentWeekStarts(
      ref.watch(clockProvider)(),
    ),
  );
});

/// 燃尽趋势数据（FR-7.3）：仅依赖未完成 + 最晚截止日（前向燃尽）。
final progressBurndownProvider = Provider<({
  List<BurndownPoint> points,
  int? currentRemaining,
  DateTime today,
  DateTime endDate,
})?>((ref) {
  final tasks = ref.watch(progressTasksProvider).valueOrNull;
  if (tasks == null) return null;
  final today = ref.watch(clockProvider)();
  final goals = ref.watch(goalListProvider).valueOrNull ?? const <Goal>[];
  final endDate = _latestDeadline(goals) ?? today;
  final hasMinutes =
      tasks.todo.any(
        (t) => t.status != 'done' && t.estimatedMinutes != null,
      ) ||
      tasks.completed.any((t) => t.estimatedMinutes != null);
  final points = hasMinutes
      ? StatisticsService.burndownSeries(
          todoTasks: tasks.todo,
          today: today,
          endDate: endDate,
        )
      : const <BurndownPoint>[];
  return (
    points: points,
    currentRemaining: points.isEmpty ? null : points.first.remaining,
    today: today,
    endDate: endDate,
  );
});

/// 进行中目标的最晚截止日（yyyy-MM-dd 文本）；无进行中目标返回 null。
DateTime? _latestDeadline(List<Goal> goals) {
  DateTime? latest;
  for (final goal in goals) {
    if (goal.status == GoalStatus.completed ||
        goal.status == GoalStatus.abandoned ||
        goal.status == GoalStatus.archived) {
      continue;
    }
    final date = parseLocalDate(goal.deadlineDate);
    if (latest == null || date.isAfter(latest)) latest = date;
  }
  return latest;
}

class ProgressPage extends ConsumerWidget {
  const ProgressPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(goalListProvider);
    // 任务类数据合并为一次就绪（todo + completed），首载/出错整页占位；
    // 就绪后各图表区块各自 watch 自己的聚合 provider，互不连带重算。
    final tasksAsync = ref.watch(progressTasksProvider);

    return Scaffold(
      // 无 AppBar（与今天页一致，左上角干净）。
      body: goalsAsync.when(
        loading: () => PageSkeletons.progressPage(),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(goalListProvider),
        ),
        data: (_) => tasksAsync.when(
          loading: () => PageSkeletons.progressPage(),
          error: (error, _) => AppErrorView(
            error: error,
            onRetry: () {
              ref.invalidate(allTodoTasksProvider);
              ref.invalidate(completedTasksProvider);
            },
          ),
          data: (_) => _buildBody(context),
        ),
      ),
    );
  }

  /// 整页纵向滚动（概览 + 燃尽 + 热力图 + 说明统一滚动）。
  ///
  /// 各图表区块为 const 构造、各自 watch 自己的聚合 provider：页面 build
  /// （仅由 goals/tasks 加载态驱动）重建时不连带重建区块；区块只在自身
  /// 依赖的 provider 变化时独立重算（旧版在 _buildBody 里全量聚合 + 整页
  /// 一次性构建全部区块）。
  Widget _buildBody(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 水平边距按容器宽度比例（约 5%，夹取 12~48px），其余交给内容铺满。
        final hPad = (constraints.maxWidth * 0.05).clamp(12.0, 48.0);

        return SingleChildScrollView(
          key: const ValueKey('progressPageScroll'),
          padding: EdgeInsets.fromLTRB(
            hPad,
            AppTokens.spaceLg,
            hPad,
            AppTokens.spaceXl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              // 数据开场（2026-08-16 编排）：概览/燃尽/热力图依次
              // 呈现，「进度」页以数据为主角；设置类入口沉底（原首屏第一张
              // 是计划偏好入口卡，抢了数据卡的主角位）。
              _TodayOverviewCard(),
              SizedBox(height: AppTokens.spaceMd),
              // 空态 CTA（无可归属目标时不显示按钮）：燃尽图需要
              // 「带预估时长」的数据，点「去设置预估时长」跳转到计划页排期，
              // 语义比「随便加一个任务」更贴合图表；热力图无完成记录时
              // 渲染全灰网格，不放引导按钮。
              _BurndownSection(ctaLabel: '去设置预估时长'),
              SizedBox(height: AppTokens.spaceMd),
              _HeatmapSection(),
              SizedBox(height: AppTokens.spaceMd),
              // 计划偏好入口卡：偏好是解读进度（今日概览完成率/剩余工作量）
              // 的上下文，点击进入独立编辑页（设置页已移除该区块）。
              _PlanPreferenceEntryCard(),
              SizedBox(height: AppTokens.spaceMd),
              // 数据统计说明：默认折叠，点击展开（不霸占底部留白）。
              _StatNote(),
            ],
          ),
        );
      },
    );
  }
}

/// 折叠的数据统计说明（底部信息默认收起，避免大段低对比文字喧宾夺主）。
///
/// 一行「数据统计说明」+ 展开/收起 chevron，点击用 [AnimatedSize] 平滑
/// 展开全文；默认折叠。文案沿用原 FR-7.4 说明，不丢失信息。
class _StatNote extends StatefulWidget {
  const _StatNote();

  @override
  State<_StatNote> createState() => _StatNoteState();
}

class _StatNoteState extends State<_StatNote> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 说明属于「统计」语义：图标取冷撞色 ink（压在暖奶油底/白卡上 ≥4.5:1），
    // 文字用 onSurfaceVariant（比旧 outline 对比度更高）。
    final noteInk = ClashTones.of(context, ClashTone.cool).ink;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppTokens.spaceXs,
              horizontal: 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline, size: 16, color: noteInk),
                const SizedBox(width: 6),
                Text(
                  '数据统计说明',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(width: AppTokens.spaceXs),
                Icon(
                  _expanded
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 16,
                  color: noteInk,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(
                    left: 2,
                    right: 2,
                    top: AppTokens.spaceXs,
                  ),
                  child: Text(
                    // 只更新与实际渲染不符的描述性文案（Lead 批准）：
                    // ①图里已无灰色虚线参考线，剩余线本身就是按最晚截止日
                    //   匀速递减到 0 的计划燃尽线；
                    // ②方向纠正：「今天」在 X 轴**最左端**——已核对渲染路径
                    //   （_BurndownChart: minX=0 处 index==0 固定标注「今天」，
                    //   maxX 处标注截止日；数据 points[0]=today 向右递增），
                    //   轴方向与数据方向一致，原「最右端=今天」才是笔误。
                    '无预估时长的任务只计入任务数，不计入时长（FR-7.4）。'
                    '剩余工作量图展示还没做完的工作量随日期的变化（最左端=今天，'
                    '对应当前剩余），曲线按最晚截止日匀速递减到 0；'
                    '热力图按任务完成日期统计。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 统一图例色块：圆角方块 12×12，可带描边（燃尽曲线节点描边用 surface，
/// 让撞色节点在卡片底上有清晰边界）。
class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, this.borderColor});

  final Color color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: 1.5),
      ),
    );
  }
}

/// 计划偏好入口卡。
///
/// 展示当前每日可用时长与每周可用日摘要；点击进入独立「计划偏好」页编辑
/// （计划偏好是负载计算规则，也是解读进度数据的上下文；编辑细节收敛到
/// 独立页，保持进度页视觉整洁）。
class _PlanPreferenceEntryCard extends ConsumerWidget {
  const _PlanPreferenceEntryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 「计划偏好」是主动作入口（点了要去排期），取**暖色实心撞色块**：
    // 与相邻的热力图（冷）与统计说明（冷）形成暖/冷对冲。
    final warm = ClashTones.of(context, ClashTone.warm);
    final settingsAsync = ref.watch(settingsProvider);
    return HoverableCard(
      // 计划偏好入口卡可点：hover 边框加深 + 阴影增强 + 微上浮。
      // 设置加载失败时退化为普通容器（错误态点击无意义）。
      onTap: settingsAsync.hasValue
          ? () => context.push('/plan-preference')
          : null,
      child: settingsAsync.when(
        loading: () =>
            const ListTile(title: Text('计划偏好'), subtitle: Text('加载中…')),
        error: (error, _) => ListTile(
          title: const Text('计划偏好'),
          subtitle: Text('加载失败：$error'),
        ),
        data: (settings) {
          final weekdays = SettingsRepository.decodeWeekdays(
            settings.availableWeekdays,
          );
          final weekdayText = weekdays.length == 7
              ? '每周 7 天'
              : '每周 ${weekdays.map(_weekdayShort).join('、')}';
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceLg,
              vertical: AppTokens.spaceMd,
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    // 实心撞色块必须配 onFill（深色模式下 primaryContainer
                    // 与 primary 的对比不足，这正是拆分色彩角色的原因）。
                    color: warm.fill,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.tune, size: 18, color: warm.onFill),
                ),
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '计划偏好',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '每日可用 ${DurationFormat.minutes(settings.dailyAvailableMinutes)} · $weekdayText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: warm.ink,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _weekdayShort(int iso) {
    return switch (iso) {
      1 => '一',
      2 => '二',
      3 => '三',
      4 => '四',
      5 => '五',
      6 => '六',
      7 => '日',
      _ => '?',
    };
  }
}

/// 今日概览卡（FR-7.1，撞色 KPI 行）。
///
/// 三个 [ClashStatTile] 构成撞色 KPI 行（数值由 ClashStatTile 统一承载，
/// headlineSmall + w700）：
/// - **暖（实心）＝已完成时长**：今天真正投入的量，视觉重量最高；
/// - **冷（浅底）＝目标剩余工作量**：与燃尽图同源的「还剩多少」数据；
/// - **点缀（浅底）＝今日完成 N/M + 完成率**：完成徽标语义（契约中
///   citrus＝成就/完成徽标），N/M 与完成率同格承载，不再另外占一格。
/// 密集排布统一用 `filled: false` 浅底变体（仅暖块实心），避免三块实心
/// 互相抢戏。
///
/// 无数据语义（与「计划已满但全部完成」区分，避免 0 误导）：
/// - 今日没有任务（totalCount==0）：今日完成 `--`、已完成时长 `-- 分`；
/// - 应用完全没有任务（[hasAnyTask] 为 false）：目标剩余工作量 `-- 分`。
class _TodayOverviewCard extends ConsumerWidget {
  const _TodayOverviewCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todayStr = _ymd.format(ref.watch(clockProvider)());
    final todayAsync = ref.watch(tasksByDateProvider(todayStr));
    final data = ref.watch(progressOverviewProvider);
    if (data == null) {
      // 今日任务数据未就绪：首载由页面加载门处理；出错给局部重试，
      // 刷新间隙保留占位，不塌陷整页。
      if (todayAsync.hasError) {
        return AppErrorView(
          error: todayAsync.error!,
          onRetry: () => ref.invalidate(tasksByDateProvider),
        );
      }
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final stats = data.stats;
    final remainingMinutes = data.remainingMinutes;
    final hasAnyTask = data.hasAnyTask;

    final hasTodayTask = stats.totalCount > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 数据/统计类区块头 → 冷撞色。
            const ClashSectionHeader(
              icon: Icons.insights,
              title: '今日概览',
              tone: ClashTone.cool,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            // IntrinsicHeight：三个 KPI 块等高对齐（只有 3 个子节点，
            // 一次额外测量，开销可忽略）。
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClashStatTile(
                      tone: ClashTone.warm,
                      icon: Icons.timer_outlined,
                      label: '已完成时长',
                      value: hasTodayTask
                          ? DurationFormat.minutes(stats.doneMinutes)
                          : '-- 分',
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceMd),
                  Expanded(
                    child: ClashStatTile(
                      tone: ClashTone.cool,
                      filled: false,
                      icon: Icons.hourglass_bottom,
                      label: '目标剩余工作量',
                      value: hasAnyTask
                          ? DurationFormat.minutes(remainingMinutes)
                          : '-- 分',
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceMd),
                  Expanded(
                    child: ClashStatTile(
                      tone: ClashTone.citrus,
                      filled: false,
                      icon: Icons.check_circle_outline,
                      label: '今日完成',
                      value: hasTodayTask
                          ? '${stats.doneCount}/${stats.totalCount}'
                          : '--',
                      hint: hasTodayTask
                          ? '完成率 ${(stats.doneCount / stats.totalCount * 100).round()}%'
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 燃尽趋势区（FR-7.3）：从今天到最晚截止日的「剩余预估时长」计划燃尽曲线
/// （fl_chart 图表，撞色重构）。
///
/// - 实际剩余（实线 + 面积填充）：今日点 = 当前剩余（与 FR-7.1 口径一致），
///   随日期往后按最晚截止日线性递减到 0；
/// - Header 右侧展示「当前剩余」大字（燃尽核心信息）；副标题为一句话结论；
///   悬停 tooltip + 图例文本 + 整体读屏语义（NFR-4，不只依赖颜色）。
///
/// 撞色映射（统一取 [ClashTones.chartSeries]）：
/// - 主序列「剩余工作量」＝暖色（`series[0]`），面积填充同色低透明度；
/// - 第三序列点缀＝今日锚点节点（`series[2]`）：前向燃尽的起点是「今天」，
///   用点缀色把起点从曲线上拎出来，并在图例中以文本标注（NFR-4）。
class _BurndownSection extends ConsumerWidget {
  const _BurndownSection({this.ctaLabel = '去添加任务'});

  /// 空态按钮文案（默认「去添加任务」；燃尽图用「去设置预估时长」）。
  final String ctaLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 图表三序列撞色一次取好（纯查表，无分配压力；不要下沉到 itemBuilder）。
    final series = ClashTones.chartSeries(context);
    final remainingColor = series[0]; // 暖：主序列（剩余工作量）
    final todayDotColor = series[2]; // 点缀：今日锚点
    // 面积填充：主序列同色 28% → 透明（纵向淡出，网格线仍可见）。
    final areaGradient = [
      ClashTones.tint(remainingColor, alpha: 0.28),
      ClashTones.tint(remainingColor, alpha: 0.0),
    ];
    // 节点/图例描边：用卡片表面色兜住撞色节点（浅色下即白色，深色下自动
    // 跟随深色表面），不再硬编码 Colors.white。
    final dotBorder = scheme.surface;

    // 数据聚合由 progressBurndownProvider 完成（独立区块，输入变化只重算
    // 本区块）；空态 CTA 的目标归属列表同样自查，避免父级传参导致本区块
    // 被无关页面重建连带。
    final data = ref.watch(progressBurndownProvider);
    if (data == null) {
      return const SizedBox.shrink(); // 首载由页面加载门处理
    }
    final activeGoals = ref
            .watch(goalListProvider)
            .valueOrNull
            ?.where(
              (g) =>
                  g.status != GoalStatus.completed &&
                  g.status != GoalStatus.abandoned &&
                  g.status != GoalStatus.archived,
            )
            .toList() ??
        const <Goal>[];
    final onAddTask =
        activeGoals.isEmpty ? null : () => context.go('/plan');
    final today = data.today;
    final points = data.points;
    final currentRemaining = data.currentRemaining;
    // provider 已按「是否有带时长数据」决定是否生成序列：有序列即有数据。
    final hasMinutes = points.isNotEmpty;

    // 结论句（白话）：说明这张图展示的是从今天到截止日的计划燃尽曲线。
    final String summary;
    if ((currentRemaining ?? 0) > 0) {
      final deadlineText = _md.format(data.endDate);
      summary =
          '从 ${_md.format(today)} 到 $deadlineText，'
          '计划燃尽 ${DurationFormat.minutes(currentRemaining!)}';
    } else {
      summary = '当前没有剩余工作量';
    }

    return Card(
      // 底部留出额外空间：给 X 轴旋转 45° 后的日期标签与悬停 tooltip
      // 预留展示区域，避免贴到卡片边缘。
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 数据/统计类区块头 → 冷撞色（与暖色曲线形成对照）。
            ClashSectionHeader(
              icon: Icons.trending_down,
              title: '剩余工作量趋势',
              tone: ClashTone.cool,
              subtitle: summary,
              // Header 右侧：当前剩余大字（燃尽核心信息直接呈现）。
              // 无带时长数据时显示 `-- 分`（与顶部今日概览无数据语义一致），
              // 只有真有任务且剩余为 0（全部完成）才用点缀色表达完成状态。
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '当前剩余',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  Text(
                    currentRemaining == null
                        ? '-- 分'
                        : DurationFormat.minutes(currentRemaining),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: currentRemaining == null
                          ? scheme.onSurfaceVariant
                          : currentRemaining == 0
                          ? ClashTones.of(context, ClashTone.citrus).ink
                          : scheme.onSurface,
                      fontWeight: currentRemaining == null
                          ? FontWeight.w400
                          : FontWeight.w700,
                      // 等宽数字：剩余量逐日变化时数字列对齐不抖动。
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            if (!hasMinutes)
              ClashEmptyState(
                icon: Icons.trending_down,
                title: '还没有可展示的剩余工作量数据',
                message:
                    '给任务设置预估时长并开始完成后，'
                    '这里会展示剩余工作量随时间的变化',
                tone: ClashTone.cool,
                compact: true,
                action: onAddTask == null
                    ? null
                    : OutlinedButton.icon(
                        onPressed: onAddTask,
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(ctaLabel),
                      ),
              )
            else ...[
              // RepaintBoundary：fl_chart 每帧 repaint 开销大，隔离成独立
              // 图层，滚动经过时避免整页连带重绘。
              RepaintBoundary(
                child: _BurndownChart(
                  points: points,
                  today: today,
                  remainingColor: remainingColor,
                  todayDotColor: todayDotColor,
                  areaGradient: areaGradient,
                  endDate: data.endDate,
                ),
              ),
              const SizedBox(height: AppTokens.spaceLg),
              // Footer 图例：色块 + 文字（与其它图表统一；无数据时不渲染）。
              // 每个撞色都带文本标签（NFR-4：信息不只靠颜色）。
              Row(
                children: [
                  _LegendDot(color: remainingColor, borderColor: dotBorder),
                  const SizedBox(width: AppTokens.spaceSm),
                  const Text('剩余工作量', style: TextStyle(fontSize: 10)),
                  const SizedBox(width: AppTokens.spaceLg),
                  _LegendDot(color: todayDotColor, borderColor: dotBorder),
                  const SizedBox(width: AppTokens.spaceSm),
                  const Text('今日节点', style: TextStyle(fontSize: 10)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 燃尽折线图（fl_chart）：计划剩余量（平滑曲线 + 面积填充 + 表面色描边
/// 节点）+ 浅色网格 + 日期轴（最左端标注「今天」、最右端标注截止日）
/// + 悬停 tooltip。
///
/// 撞色：
/// - 曲线/节点/面积＝主序列暖色（由 _BurndownSection 传入）；
/// - 今日锚点节点＝点缀色（`todayDotColor`），与 X 轴「今天」标注呼应；
/// - 网格用 `scheme.outlineVariant`，轴标签用 `scheme.onSurfaceVariant`，
///   tooltip 用 `scheme.inverseSurface` / `onInverseSurface`（对比度达标）；
/// - 入场动画：TweenAnimationBuilder 淡入 + 上移；
/// - 整体 Semantics（NFR-4）+ 悬停 tooltip（日期 + 剩余）。
class _BurndownChart extends StatelessWidget {
  const _BurndownChart({
    required this.points,
    required this.today,
    required this.remainingColor,
    required this.todayDotColor,
    required this.areaGradient,
    required this.endDate,
  });

  final List<BurndownPoint> points;
  final DateTime today;

  /// 最晚截止日，用于在 X 轴最右端标注。
  final DateTime endDate;

  /// 实际剩余线/节点色（撞色主序列暖色，由 _BurndownSection 传入）。
  final Color remainingColor;

  /// 今日锚点节点色（撞色点缀色，由 _BurndownSection 传入）。
  final Color todayDotColor;

  /// 面积填充渐变（主序列同色淡出，由 _BurndownSection 传入）。
  final List<Color> areaGradient;

  static const _chartHeight = 220.0;

  /// 数据点最大值（Y 轴顶），0 时回退 1。
  int get _maxMinutes {
    var max = 0;
    for (final point in points) {
      if (point.remaining > max) max = point.remaining;
      if (point.ideal > max) max = point.ideal;
    }
    return max <= 0 ? 1 : max;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = points.first.date;
    // fl_chart X 轴用「距窗口起点的天数」而非绝对日期，便于 interval=1。
    double xOf(DateTime date) => date.difference(first).inDays.toDouble();

    final remainingSpots = [
      for (final p in points) FlSpot(xOf(p.date), p.remaining.toDouble()),
    ];

    final axisStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 10,
      color: scheme.onSurfaceVariant,
    );

    // 网格线颜色在 build 顶层算好：getDrawingHorizontalLine/VerticalLine 是
    // 绘制期回调，若在其中做 withValues 就会每帧每条网格线重算一次。
    final gridLineColorH = scheme.outlineVariant.withValues(alpha: 0.4);
    final gridLineColorV = scheme.outlineVariant.withValues(alpha: 0.3);

    // Y 轴最大值（含 10% 顶部余量）：gridData 水平间隔与刻度统一用它。
    final maxY = _maxMinutes * 1.1;

    // 图整体读屏语义（NFR-4）：状态不只依赖颜色，辅以文本说明。
    final semanticLabel = StringBuffer(
      '剩余工作量趋势，从今日起到截止日的计划燃尽曲线。',
    );
    semanticLabel.write(
      '今日剩余 ${DurationFormat.minutes(points.first.remaining)}，',
    );
    semanticLabel.write(
      '预计 ${_md.format(endDate)} 燃尽。',
    );

    return Semantics(
      label: semanticLabel.toString(),
      child: SizedBox(
        height: _chartHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 旋转 45° 的日期标签水平投影约 30px；按图表实际宽度动态放大
            // 标签间隔，保证相邻标签中心距 ≥ 48px，窄窗不再互相覆盖。
            final perDayPx = constraints.maxWidth / (points.length - 1);
            const minLabelSpacing = 48.0;
            var labelInterval = 5;
            while (perDayPx * labelInterval < minLabelSpacing &&
                labelInterval < points.length) {
              labelInterval += 5;
            }
            return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          // 入场动画改用不裁剪的淡入 + 上移：ClipRect 会把浮出图表区域的
          // 悬停 tooltip 裁掉（问题 3），故取消裁剪。
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 24),
              child: child,
            ),
          ),
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (points.length - 1).toDouble(),
              minY: 0,
              // Y 轴顶留 10% 余量，避免文字贴顶。
              maxY: maxY,
              // 绘图区不裁剪：让 tooltip 可完整浮出图表边界（问题 3）。
              clipData: FlClipData.none(),
              // 淡虚线网格（水平 + 垂直）：用户可直观看出每天/每档的落差。
              // horizontalInterval 按 Y 轴最大值均分（4 档），verticalInterval
              // 与 X 轴标签同步（labelInterval 随宽度动态调整）。
              gridData: FlGridData(
                show: true,
                drawVerticalLine: true,
                drawHorizontalLine: true,
                horizontalInterval: maxY / 4,
                verticalInterval: labelInterval.toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: gridLineColorH,
                  strokeWidth: 1,
                  dashArray: [4, 4],
                ),
                getDrawingVerticalLine: (_) => FlLine(
                  color: gridLineColorV,
                  strokeWidth: 1,
                  dashArray: [4, 4],
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                // 左轴刻度：reservedSize 预留足够宽度把文字完全推出图表区，
                // SideTitleWidget.space 提供文字与绘图区之间的额外间隙，
                // 文本右对齐后与绿色填充区彻底分离。interval 显式设为
                // maxY/4（与水平网格线同步、均匀分布）——否则 fl_chart 自动
                // 刻度可能恰好落在数据点/曲线顶部高度，文字贴线重叠。
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 96,
                    interval: maxY / 4,
                    getTitlesWidget: (value, meta) {
                      final text = value == 0
                          ? '0'
                          : DurationFormat.minutes(value.round());
                      return SideTitleWidget(
                        meta: meta,
                        space: 12,
                        child: Align(
                          alignment: Alignment.centerRight,
                          // FittedBox 缩放长时长文本到槽位内，防溢出压线。
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(text, style: axisStyle),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // X 轴：interval 随宽度动态放大（labelInterval），
                // getTitlesWidget 内对非标签刻度返回空；最左端固定显示
                // 「今天」、最右端显示截止日（均水平不旋转，避免与斜标签叠压）。
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 56,
                    interval: labelInterval.toDouble(),
                    getTitlesWidget: (value, meta) {
                      final index = value.round();
                      // 最左端（今天）优先：水平显示「今天」，日期标签跳过
                      // 与「今天」距离不足 labelInterval 的紧邻项，避免重叠。
                      if (index == 0) {
                        return SideTitleWidget(
                          meta: meta,
                          space: 12,
                          child: Text('今天', style: axisStyle),
                        );
                      }
                      // 最右端标注截止日，水平显示。
                      if (index == points.length - 1) {
                        return SideTitleWidget(
                          meta: meta,
                          space: 12,
                          child: Text(_md.format(endDate), style: axisStyle),
                        );
                      }
                      if (index <= 0 ||
                          index % labelInterval != 0 ||
                          points.length - 1 - index < labelInterval) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        space: 12,
                        child: Transform.rotate(
                          angle: -math.pi / 4, // -45°，向左下倾斜
                          child: Text(
                            _md.format(points[index].date),
                            style: axisStyle,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // 悬停 tooltip：Windows 桌面鼠标悬停触发。
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  // 关键：让 tooltip 绘制在图表盒区域之上，可完整浮出图表
                  // 边界（配合外层 Card clipBehavior: Clip.none 与
                  // clipData: FlClipData.none()，边缘数据点的气泡不再被截断）。
                  showOnTopOfTheChartBoxArea: true,
                  getTooltipColor: (_) => scheme.inverseSurface,
                  tooltipBorderRadius: BorderRadius.circular(8),
                  getTooltipItems: (touchedSpots) {
                    return touchedSpots.map((spot) {
                      final index = spot.x.round();
                      if (index < 0 || index >= points.length) {
                        return LineTooltipItem('', const TextStyle());
                      }
                      final point = points[index];
                      return LineTooltipItem(
                        '${_ymd.format(point.date)}\n'
                        '剩余 ${DurationFormat.minutes(point.remaining)}',
                        TextStyle(
                          color: scheme.onInverseSurface,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    }).toList();
                  },
                ),
              ),
              lineBarsData: [
                // 实际剩余线：实线 + 面积填充 + 表面色描边节点。
                LineChartBarData(
                  spots: remainingSpots,
                  isCurved: true,
                  curveSmoothness: 0.3,
                  color: remainingColor,
                  barWidth: 2.5,
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      colors: areaGradient,
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  dotData: FlDotData(
                    show: true,
                    getDotPainter: (spot, percent, bar, index) =>
                        FlDotCirclePainter(
                          radius: 3.5,
                          // 今日锚点（index 0，X 轴「今天」位置）用点缀色，
                          // 其余节点用主序列暖色；图例有对应文本（NFR-4）。
                          color: index == 0 ? todayDotColor : remainingColor,
                          strokeWidth: 2,
                          // 描边取卡片表面色，兜住撞色节点（浅色下即白色，
                          // 深色下自动跟随深色表面），不硬编码颜色。
                          strokeColor: scheme.surface,
                        ),
                  ),
                ),
              ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 热力图区（FR-7.2）：最近 26 周，周一开头。
///
/// **色阶＝单一撞色（冷）的明度递进**：从 `tint(cool, 0.12)`（0 档，几乎
/// 为空）到 `cool` 满色（10+ 档），五档同色相只差明度，全图一致；不再使用
/// 固定 LeetCode 绿，三套撞色方案与深浅模式自动跟随。
/// 分级逻辑仍由 [StatisticsService.heatLevel] 决定（0 / 1-3 / 4-6 / 7-9 / 10+）。
/// 小圆角 + 色块间距不变；悬停 tooltip 与底部图例文本始终保留（NFR-4）。
/// 无完成记录时网格照常渲染（0 档），把「还没开始」当作真实状态直观呈现，
/// 不放空态引导（与燃尽图的「去添加任务」空态区分）。
class _HeatmapSection extends ConsumerWidget {
  const _HeatmapSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 数据聚合由 progressHeatmapProvider 完成（独立区块，只随 completed 变化
    // 重算）；目标名映射在格子点击弹窗内自查，本区块不依赖 goals。
    final data = ref.watch(progressHeatmapProvider);
    if (data == null) {
      return const SizedBox.shrink(); // 首载由页面加载门处理
    }
    final today = ref.watch(clockProvider)();
    final todayStr = _ymd.format(today);
    final weekStarts = data.weekStarts;
    final completedCounts = data.counts;
    final completedByDate = data.byDate;
    // 五档色阶在区块 build 顶层算一次（tint 只是 withValues，无插值开销），
    // 逐格只做数组取值——不在格子构建路径里做任何颜色计算。
    final heatColors = _heatRamp(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 「完成热力图」是页面的**成就/积累**视角（完成了多少）→ 点缀撞色
            // 区块头；其余纯统计块用冷色，主动作入口卡用暖色，形成撞色节奏。
            const ClashSectionHeader(
              icon: Icons.local_fire_department_outlined,
              title: '完成热力图',
              tone: ClashTone.citrus,
              subtitle: '最近 26 周，按完成日期统计完成任务数量',
            ),
            const SizedBox(height: AppTokens.spaceMd),
            // RepaintBoundary：热力图区域相对独立，滚动经过时只重绘本层，
            // 不连带整页其它图表/列表一起 repaint（进度页整页单滚动视图）。
            RepaintBoundary(
              child: _HeatmapGrid(
                todayStr: todayStr,
                weekStarts: weekStarts,
                completedCounts: completedCounts,
                completedByDate: completedByDate,
                colors: heatColors,
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            // 图例始终渲染：0 档色块需要解释（与有数据时一致，不再只在
            // 有数据时出现）；每档都带分桶文本（NFR-4：不只靠颜色）。
            _CompactLegend(
              colors: heatColors,
              labels: const ['0', '1-3', '4-6', '7-9', '10+'],
            ),
          ],
        ),
      ),
    );
  }
}

/// 热力图五档色阶：**冷撞色的单色明度递进**（0 档近乎空白 → 4 档满色）。
///
/// 用同一个基准色（`ClashTones.cool.ink`，深色模式下自动换成亮青）叠加
/// 递增透明度：浅色下是「白卡上的浅青 → 深青」，深色下是「深卡上的暗青
/// → 亮青」，两种模式都是单调加深/加亮，不会出现档位反转。
List<Color> _heatRamp(BuildContext context) {
  final base = ClashTones.of(context, ClashTone.cool).ink;
  return [
    ClashTones.tint(base, alpha: 0.12),
    ClashTones.tint(base, alpha: 0.34),
    ClashTones.tint(base, alpha: 0.56),
    ClashTones.tint(base, alpha: 0.78),
    base,
  ];
}

/// 紧凑图例：一行色块 + 对应分桶文本，直接对应上方图表颜色。
class _CompactLegend extends StatelessWidget {
  const _CompactLegend({required this.colors, required this.labels});

  final List<Color> colors;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < colors.length; i++) ...[
          if (i > 0) const SizedBox(width: AppTokens.spaceSm),
          _LegendDot(color: colors[i]),
          const SizedBox(width: AppTokens.spaceXs),
          Text(labels[i], style: const TextStyle(fontSize: 10)),
        ],
      ],
    );
  }
}

/// 热力图网格：小圆角 + 色块间距 + 悬停 tooltip，点击色块查看当天完成
/// 的具体任务。
///
/// 用 LayoutBuilder 按父级宽度动态计算色块尺寸：26 周横向铺满卡片内容区
/// （宽屏下色块自动放大，消除右侧留白），窄窗口自动收缩并出现横向滚动。
class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({
    required this.todayStr,
    required this.weekStarts,
    required this.completedCounts,
    required this.completedByDate,
    required this.colors,
  });

  final String todayStr;
  final List<DateTime> weekStarts;
  final Map<String, int> completedCounts;
  final Map<String, List<Task>> completedByDate;

  /// 五档撞色色阶（由 _HeatmapSection 在 build 顶层算好传入）。
  final List<Color> colors;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// 星期标签列宽、标签列与网格间距、周间距、色块上下间距、月份标签高。
  static const _labelColumnWidth = 14.0;
  static const _labelGap = 6.0;
  static const _weekGap = 3.0;
  static const _cellVTopGap = 2.0;
  static const _monthLabelHeight = 18.0;

  /// 色块行高 = 色块尺寸 + 上下间距（月份标签区同高，保持列对齐）。
  static double _cellRowHeight(double cellSize) => cellSize + _cellVTopGap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final daysInWeek = 7;
    final maxWeek = weekStarts.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 横向可用宽度 = 父级宽度 - 星期标签列 - 间距。
        final available = constraints.maxWidth - _labelColumnWidth - _labelGap;
        // 色块尺寸：26 周 + 周间距正好铺满剩余宽度（下限 6px 防极端窄窗）。
        final cellSize = (available - _weekGap * (maxWeek - 1)) / maxWeek;
        final size = cellSize < 6 ? 6.0 : cellSize;
        final rowHeight = _cellRowHeight(size);
        final weekColumnWidth = size + _weekGap;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 星期标签列。
              Column(
                children: [
                  const SizedBox(height: _monthLabelHeight),
                  for (var row = 0; row < daysInWeek; row++)
                    SizedBox(
                      height: rowHeight,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          _weekdayLabels[row],
                          style: TextStyle(
                            fontSize: 9,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: _labelGap),
              // 每周一列（列宽随色块尺寸变化，铺满时总宽 = 可用宽度）。
              Row(
                children: [
                  for (var week = 0; week < maxWeek; week++)
                    SizedBox(
                      width: weekColumnWidth,
                      child: Column(
                        children: [
                          _monthLabel(
                            weekStart: weekStarts[week],
                            labelStyle: TextStyle(
                              fontSize: 9,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          for (var row = 0; row < daysInWeek; row++)
                            _buildCell(context, weekStarts[week], row, size),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _monthLabel({
    required DateTime weekStart,
    required TextStyle labelStyle,
  }) {
    final firstDay = weekStart;
    // 只在本周首日是一号，或与上一周跨月时显示月份。
    // 上一周用纯日历减法（date_text）：防 DST 切换日偏移导致跨月判断错位。
    if (firstDay.day != 1 &&
        weekStart.month ==
            addLocalDays(weekStart, -7).month) {
      return const SizedBox(height: _monthLabelHeight);
    }
    return SizedBox(
      height: _monthLabelHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        // FittedBox 缩放月份文本适配列宽（列宽可能仅 10px 左右，「10月」
        // 两个字符更宽），避免溢出盖到右侧格子。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('${firstDay.month}月', style: labelStyle),
        ),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    DateTime weekStart,
    int row,
    double size,
  ) {
    // 纯日历加法（date_text）：防 DST 切换日「加 row 天偏移一小时」导致
    // 日期错位（与 statistics_service 周窗口口径一致）。
    final date = addLocalDays(weekStart, row);
    final dateStr = _ymd.format(date);
    final count = completedCounts[dateStr] ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final isToday = dateStr == todayStr;
    final level = StatisticsService.heatLevel(count);

    // 色阶＝冷撞色单色明度递进（0 档 also 用同一色相的最浅档，
    // 深浅模式一致，不再有「暗色下额外换灰」的特例）。
    final color = colors[level];

    // 点击色块：查看当天完成的具体任务（含 0 档：弹窗内展示空提示）。
    // 已按日期预分桶，此处 O(1) 取当天任务，避免逐格全量扫描。
    final dayTasks = completedByDate[dateStr] ?? const <Task>[];

    return Tooltip(
      message: '$dateStr：完成 $count 项',
      child: Semantics(
        // 屏幕阅读器可读（NFR-4）：日期 + 完成项数，状态不只依赖颜色。
        label: '$dateStr：完成 $count 项',
        child: InkWell(
          onTap: () => _showDayTasks(context, dateStr: dateStr, tasks: dayTasks),
          borderRadius: BorderRadius.circular(3),
          child: Container(
            width: size,
            height: size,
            margin: const EdgeInsets.only(top: _cellVTopGap),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              border: isToday
                  ? Border.all(color: scheme.onSurface, width: 1.5)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// 弹窗展示 [dateStr] 当天完成的任务清单。
  void _showDayTasks(
    BuildContext context, {
    required String dateStr,
    required List<Task> tasks,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => _DayTasksDialog(dateStr: dateStr, tasks: tasks),
    );
  }
}

/// 热力图某天完成任务的查看对话框：当天完成的任务清单（标题、目标、
/// 科目、时长、完成时刻），以及完成数量的汇总文案。
class _DayTasksDialog extends ConsumerWidget {
  const _DayTasksDialog({required this.dateStr, required this.tasks});

  /// 当天日期（yyyy-MM-dd）。
  final String dateStr;

  /// 当天完成的任务（已完成且 completedAt 落于当天）。
  final List<Task> tasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 目标名映射在弹窗内自查（只在打开弹窗时计算，不参与热力图网格的
    // 常规构建路径）。
    final goalsById = {
      for (final g in ref.watch(goalListProvider).valueOrNull ?? const <Goal>[])
        g.id: g,
    };
    return AlertDialog(
      title: Text('$dateStr 完成的任务'),
      content: SizedBox(
        width: 420,
        child: tasks.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '这一天没有完成任务',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: tasks.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _buildTaskTile(context, ref, tasks[index], goalsById),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildTaskTile(
    BuildContext context,
    WidgetRef ref,
    Task task,
    Map<int, Goal> goalsById,
  ) {
    final goal = goalsById[task.goalId];
    // 科目名经 subjectListProvider 自查（避免父级传参）。
    final subjectName = task.subjectId == null
        ? null
        : ref
            .watch(subjectListProvider(task.goalId))
            .valueOrNull
            ?.where((s) => s.id == task.subjectId)
            .map((s) => s.name)
            .firstOrNull;

    final completedAt = task.completedAt?.toLocal();
    final parts = <String>[
      ?goal?.title,
      ?subjectName,
      if (task.estimatedMinutes != null)
        DurationFormat.minutes(task.estimatedMinutes!),
      if (completedAt != null)
        '完成于 ${_hm.format(completedAt)}',
    ];

    return ListTile(
      dense: true,
      // 完成徽标语义 → 点缀撞色（契约：citrus＝成就/完成徽标）。
      leading: Icon(
        Icons.check_circle,
        size: 20,
        color: ClashTones.of(context, ClashTone.citrus).ink,
      ),
      title: Text(task.title),
      subtitle: parts.isEmpty ? null : Text(parts.join(' · ')),
    );
  }
}
