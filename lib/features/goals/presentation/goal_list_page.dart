import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../plan_import/presentation/plan_import_dialog.dart';
import '../../tasks/data/recurrence_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../data/goal_repository_provider.dart';
import '../data/milestone_repository_provider.dart';
import '../data/subject_repository_provider.dart';
import 'goal_form_dialog.dart';

/// 各目标任务完成统计（目标卡片进度条与统计行用）。
///
/// 依赖 [goalListProvider] 的目标集合，一次批量 SQL（[TaskRepository.completionByGoals]）
/// 避免逐卡查询的 N+1；目标变更（invalidateAppData）时随 goalList 一同失效。
final goalCompletionProvider = FutureProvider<
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
            ? const <int,
                ({int total, int done, int totalMinutes, int doneMinutes})>{}
            : ref.watch(goalCompletionProvider).valueOrNull ?? const {};
        // 顶部统计（进行中 / 已完成 / 全部）：把「目标页」从孤零零的
        // 卡片列表升级为 Dashboard——一眼看清目标池规模（Todoist 式）。
        final activeCount =
            goals.where((g) => g.status == GoalStatus.active).length;
        final completedCount =
            goals.where((g) => g.status == GoalStatus.completed).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 区块头（Dashboard 语言）：页面主标题 + 导入完整计划 + 新建
            // 目标入口（取代原 FAB 与 AppBar actions，桌面宽窗下比悬浮
            // 按钮更醒目、更接近列表页惯例）。始终显示——空态也要能
            // 导入完整计划/新建目标。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Text('我的目标',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  if (onImportPlan != null)
                    IconButton(
                      tooltip: '导入完整计划',
                      onPressed: onImportPlan,
                      icon: const Icon(Icons.upload_file_outlined),
                    ),
                  // 空态时不重复放「新建目标」（空态大按钮是唯一主入口，
                  // 避免两个『创建目标』tooltip 歧义）；非空态显示。
                  if (goals.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    // tooltip 保留旧语义，兼容既有测试与无障碍。
                    Tooltip(
                      message: '创建目标',
                      child: FilledButton.icon(
                        onPressed: onCreateGoal ?? () => _defaultCreate(context),
                        icon: const Icon(Icons.add),
                        label: const Text('新建目标'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (goals.isEmpty)
              Expanded(child: _EmptyView(onCreateGoal: onCreateGoal))
            else ...[
              // 顶部统计胶囊：进行中 / 已完成 / 全部。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    _GoalCountPill(count: activeCount, label: '进行中'),
                    const SizedBox(width: 8),
                    _GoalCountPill(count: completedCount, label: '已完成'),
                    const SizedBox(width: 8),
                    _GoalCountPill(count: goals.length, label: '全部'),
                  ],
                ),
              ),
              // 目标卡片网格：单目标时通栏大卡（避免孤卡占小角 + 大片留白，
              // Dashboard 首页感）；多目标时按 maxCrossAxisExtent 自适应
              // 双列（桌面内容区约 1200px → 每卡约 580px 宽），消除下方大留白。
              // 用固定列数（单目标 1 列）而非 maxCrossAxisExtent 传超大值，
              // 避免依赖 SDK 对极值的解析行为。
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: goals.length == 1
                      ? const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 1,
                          mainAxisExtent: 268,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        )
                      : const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 720,
                          mainAxisExtent: 268,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                  itemCount: goals.length,
                  itemBuilder: (context, index) {
                    return _GoalCard(
                      goal: goals[index],
                      completion: completion[goals[index].id],
                    );
                  },
                ),
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
    final scheme = Theme.of(context).colorScheme;
    // 数据为空时提供与当前页相关的首个操作（PRD §8）。
    // 圆底图标语言与今天页/图表空态统一（v1.11 空态规范）。
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.flag_outlined, size: 32, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          Text('还没有目标', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '创建一个目标，把截止日期变成今天的行动',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // tooltip 与区块头「新建目标」一致，供既有测试与无障碍定位。
          Tooltip(
            message: '创建目标',
            child: FilledButton.icon(
              onPressed: () => _createGoal(context),
              icon: const Icon(Icons.add),
              label: const Text('创建目标'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 目标卡片（v1.13 Dashboard 大卡 + 信息层级重构）。
///
/// 结构（自上而下）：
/// 1. 标题行：目标专属色圆点 + 标题（2 行）｜右侧 ⋮ 操作菜单；
/// 2. 进度行：大号完成度 %（无任务灰 `0%`）+ 右侧倒计时胶囊徽标；
/// 3. 彩色粗进度条（8px，目标专属色，与 % 构成同一信息块）；
/// 4. 起止日期区间 `yyyy.MM.dd → yyyy.MM.dd`；
/// 5. 数据行（标题 + 数值结构）：已完成 x/y · 学习时长 · 剩余时间；
/// 6. 底部「查看详情 →」引导性主操作。
///
/// 状态颜色跟随倒计时阶段（进行中=目标色/今天=琥珀/逾期=红/已结束=灰），
/// 每张卡以目标专属稳定色板区分，双列网格中靠色块快速定位目标。
/// 描述刻意不在卡片展示（卡片信息密度优先，详情页可见），避免卡片
/// 中部出现大段空白/冗余文本。
class _GoalCard extends ConsumerWidget {
  const _GoalCard({required this.goal, this.completion});

  final Goal goal;

  /// 该目标任务完成统计（null = 数据未就绪，进度显示 0% 占位）。
  final ({int total, int done, int totalMinutes, int doneMinutes})? completion;

  static const _countdown = CountdownService();

  /// 目标专属稳定色板（按 goal.id 取色）：柔和高辨识度色相，
  /// 同目标在各处（圆点/进度条/百分比）颜色一致。
  static const _accentColors = <Color>[
    Color(0xFF3F6C51), // 品牌深绿
    Color(0xFF6B5B95), // 紫
    Color(0xFF2E7D8A), // 青
    Color(0xFFC0564D), // 砖红
    Color(0xFF8A6D2F), // 赭石
    Color(0xFF3F7C5A), // 墨绿
    Color(0xFF5C6BC0), // 靛蓝
    Color(0xFF8C5E9E), // 藕紫
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(clockProvider)();
    final (phase, days) = _countdown.evaluate(
      deadlineDate: goal.deadlineDate,
      today: today,
      status: goal.status,
    );

    final scheme = Theme.of(context).colorScheme;
    final warning = AppSemanticColors.of(context).warning;
    final phaseColor = switch (phase) {
      CountdownPhase.upcoming => scheme.primary,
      // 今天截止 = 行动提醒（警告色）；已逾期 = 错误（红色）。
      CountdownPhase.today => warning,
      CountdownPhase.overdue => scheme.error,
      CountdownPhase.terminated => scheme.outline,
    };
    // 目标专属强调色：进度条/圆点/百分比共用（同目标跨卡一致）。
    // abs 防御（L4）：负 id 理论上不可达（autoIncrement），取模负值越界。
    final accent = _accentColors[goal.id.abs() % _accentColors.length];

    final done = completion?.done ?? 0;
    final total = completion?.total ?? 0;
    final progress = total == 0 ? 0.0 : done / total;
    final percent = (progress * 100).round();
    final doneMinutes = completion?.doneMinutes ?? 0;
    final totalMinutes = completion?.totalMinutes ?? 0;
    final remainingMinutes = totalMinutes - doneMinutes;

    return Card(
      // 网格间距由 GridView delegate 控制，卡片自身不带 margin。
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // push 压入导航栈，详情页 AppBar 自动出现返回箭头。
        onTap: () {
          // 预热详情页数据源（后台 isolate 并行查询，不阻塞 UI）：进入
          // 详情页时数据多已就绪，首帧不再等待 spinner/骨架（P3.5 卡顿
          // 排查：详情页目标/任务/科目/里程碑各一次独立查询，逐项填充
          // 造成首载观感慢）。
          _prefetchDetail(ref, goal.id);
          context.push('/goals/${goal.id}');
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // —— 第 1 行：色点 + 标题 + 操作菜单（信息层级最高）——
              Row(
                children: [
                  // 目标专属色圆点（状态定位色标）。
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      goal.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '目标操作',
                    icon: const Icon(Icons.more_horiz),
                    iconSize: 20,
                    onSelected: (action) =>
                        _handleAction(context, ref, action),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(
                        value: 'complete',
                        child: Text('标记已完成'),
                      ),
                      const PopupMenuItem(
                        value: 'abandon',
                        child: Text('标记已放弃'),
                      ),
                      const PopupMenuItem(value: 'archive', child: Text('归档')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // —— 进度行：大号完成度 % 与进度条构成同一信息块 ——
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 大号完成度数字：视觉权重第一；无任务时灰字 `0%`
                  // 占位（区分「没计划」与「0 完成」）。
                  Text(
                    '$percent%',
                    style: TextStyle(
                      fontSize: 32,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: total == 0 ? scheme.outline : accent,
                    ),
                  ),
                  const Spacer(),
                  // 倒计时徽标：胶囊底色 + 阶段文案（文字不只依赖颜色）。
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: phaseColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      CountdownService.label(phase, days),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: phaseColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // —— 彩色粗进度条（8px，目标专属色，mhabit 式）——
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: scheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  valueColor: AlwaysStoppedAnimation(accent),
                ),
              ),
              const SizedBox(height: 14),
              // —— 起止日期区间（创建日 → 截止日）——
              Row(
                children: [
                  Icon(Icons.schedule_outlined, size: 14, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text(
                    '${_dotDate(goal.createdAt.toLocal())} → '
                    '${_dotDate(parseLocalDate(goal.deadlineDate))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // —— 数据行：已完成 / 学习时长 / 剩余时间（标题+数值结构）——
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CardStat(
                    title: '已完成',
                    value: total == 0 ? '-- / --' : '$done / $total',
                  ),
                  _CardStat(
                    title: '学习时长',
                    value: total == 0
                        ? '--'
                        : DurationFormat.minutes(doneMinutes),
                  ),
                  _CardStat(
                    title: '剩余时间',
                    value: total == 0
                        ? '--'
                        : DurationFormat.minutes(remainingMinutes),
                  ),
                ],
              ),
              // —— 底部：查看详情（引导性主操作）——
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () {
                    _prefetchDetail(ref, goal.id);
                    context.push('/goals/${goal.id}');
                  },
                  child: const Text('查看详情 →'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 本地日期 → `yyyy.MM.dd` 点分格式（区间展示更紧凑）。
  static String _dotDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}.$mm.$dd';
  }  /// 预热详情页数据源（P3.5 卡顿排查）。
  ///
  /// 详情页首载同时 watch 目标详情/任务列表/科目列表/里程碑列表四个
  /// provider，各自独立查询库（后台 isolate 不阻塞 UI，但逐项填充的
  /// 时间窗会造成「点卡片 → 详情页首帧空/慢」的观感）。在点击瞬间
  /// 提前触发查询，页面进入时数据多已缓存，首帧直接渲染内容。
  void _prefetchDetail(WidgetRef ref, int goalId) {
    ref.read(goalDetailProvider(goalId).future);
    ref.read(taskListProvider(goalId).future);
    ref.read(subjectListProvider(goalId).future);
    ref.read(milestoneListProvider(goalId).future);
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
            completedAt: DateTime.now().toUtc(),
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
  /// 详情、归档任务列表与重复模板族（级联删除会连带删模板，避免残留陈旧
  /// 缓存）。保证跨页数据一致（FR-3 验收）。
  void _refreshGoalRelated(WidgetRef ref) {
    invalidateAppData(ref);
    ref.invalidate(goalDetailProvider);
    ref.invalidate(archivedTaskListProvider);
    // 目标级联删除会连带删除其重复模板（recurrence_repository.deleteWithCascade），
    // 模板缓存必须同步失效，避免删除后残留陈旧模板数据。
    ref.invalidate(recurrenceTemplatesProvider);
  }
}

/// 卡片统计块：小号标题在上、加粗数值在下（Todoist/Linear 风格信息层级）。
///
/// 三块等宽（Expanded）排布，标题用次级色、数值用主文字色，形成
/// 「先看数值、再看语义」的阅读顺序，替代旧版一长串平铺文字。
class _CardStat extends StatelessWidget {
  const _CardStat({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
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
                ),
          ),
        ],
      ),
    );
  }
}

/// 目标页顶部统计胶囊：计数 + 标签（进行中 / 已完成 / 全部）。
///
/// 浅色圆角底 + 计数粗体，页面顶部一眼看清目标池规模（Todoist 式
/// Dashboard 模块化的第一步；后续可扩展为可点击筛选）。
class _GoalCountPill extends StatelessWidget {
  const _GoalCountPill({required this.count, required this.label});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$count',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
