import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../plan_import/presentation/plan_import_dialog.dart';
import '../../tasks/data/recurrence_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../data/goal_repository_provider.dart';
import 'goal_form_dialog.dart';

/// 各目标的任务完成统计（目标列表进度环用）。
///
/// 依赖 [goalListProvider] 的目标集合，一次批量 SQL（[TaskRepository.completionByGoals]）
/// 避免逐卡查询的 N+1；目标变更（invalidateAppData）时随 goalList 一同失效。
final goalCompletionProvider = FutureProvider<
  Map<int, ({int total, int done})>
>((ref) async {
  final goals = await ref.watch(goalListProvider.future);
  final ids = goals.map((g) => g.id).toList();
  if (ids.isEmpty) return const {};
  return ref.watch(taskRepositoryProvider).completionByGoals(ids);
});

/// 目标页：目标列表（FR-1 目标 CRUD 入口）。
///
/// v1.12 起从计划页拆分为独立一级导航：底部导航「目标」进入本页，
/// 计划页退化为纯日历。AppBar 承载「导入完整计划」入口（原计划页
/// 目标段 AppBar 迁移至此），FAB 创建目标。
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
      appBar: AppBar(
        title: const Text('目标'),
        actions: [
          IconButton(
            tooltip: '导入完整计划',
            onPressed: () => _importPlan(context),
            icon: const Icon(Icons.upload_file_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createGoal(context),
        tooltip: '创建目标',
        child: const Icon(Icons.add),
      ),
      body: GoalListBody(onCreateGoal: () => _createGoal(context)),
    );
  }
}

/// 目标列表主体（无 Scaffold）：空态 / 错误 / 目标卡片列表。
///
/// [onCreateGoal] 为空时，空态按钮回退为内置的创建流程。
class GoalListBody extends ConsumerWidget {
  const GoalListBody({super.key, this.onCreateGoal});

  final Future<void> Function()? onCreateGoal;

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
        if (goals.isEmpty) {
          return _EmptyView(onCreateGoal: onCreateGoal);
        }
        // 各目标任务完成统计：父级一次性预取（批量 SQL，避免逐卡 N+1），
        // 供卡片进度环使用；数据未就绪时卡片进度环显示 0% 占位。
        final completion =
            ref.watch(goalCompletionProvider).valueOrNull ?? const {};
        // 宽屏双列网格、窄窗自动回落单列（maxCrossAxisExtent）：
        // 消除单列列表在目标较少时的下方大片空白，视觉更紧凑。
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 560,
            mainAxisExtent: 132,
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
        );
      },
    );
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
          FilledButton.icon(
            onPressed: () => _createGoal(context),
            icon: const Icon(Icons.add),
            label: const Text('创建目标'),
          ),
        ],
      ),
    );
  }
}

/// 目标卡片（v1.12 进度环卡，借鉴 mhabit / streak 的开源设计）。
///
/// 结构（自上而下）：
/// 1. 上段：目标专属色圆点 + 标题（2 行）｜右侧任务完成度进度环（42px，
///    中心小号 %，无任务时 0% 灰环）；
/// 2. 细分隔线（fitness 统计卡的分段手法）；
/// 3. 下段：截止日期 + 倒计时徽标（剩余/今天/逾期，文字不只依赖颜色
///    NFR-4）+ 操作菜单。
/// 状态颜色跟随倒计时阶段（进行中=目标色/今天=琥珀/逾期=红/已结束=灰），
/// 每张卡以目标专属稳定色板区分，双列网格中靠色块快速定位目标。
class _GoalCard extends ConsumerWidget {
  const _GoalCard({required this.goal, this.completion});

  final Goal goal;

  /// 该目标任务完成统计（null = 数据未就绪，环显示 0% 占位）。
  final ({int total, int done})? completion;

  static const _countdown = CountdownService();

  /// 目标专属稳定色板（按 goal.id 取色）：柔和高辨识度色相，
  /// 同目标在各处（圆点/进度环）颜色一致。
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
    // 目标专属强调色：环与圆点共用（同目标跨卡一致）。
    final accent = _accentColors[goal.id % _accentColors.length];

    final done = completion?.done ?? 0;
    final total = completion?.total ?? 0;
    final progress = total == 0 ? 0.0 : done / total;
    final percent = (progress * 100).round();

    return Card(
      // 网格间距由 GridView delegate 控制，卡片自身不带 margin。
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // push 压入导航栈，详情页 AppBar 自动出现返回箭头。
        onTap: () => context.push('/goals/${goal.id}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // —— 上段：目标标题 + 完成度进度环 ——
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
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
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      goal.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(height: 1.25),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 任务完成度进度环：mhabit 式（strokeWidth 4、round cap、
                  // 中心小号 %），完成时环满 + 数字 100%。
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 4,
                          strokeCap: StrokeCap.round,
                          color: accent,
                          backgroundColor: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                        ),
                        Center(
                          child: Text(
                            '$percent%',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: total == 0 ? scheme.outline : accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // —— 细分隔线：截止区与进度区切分（fitness 手法）——
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 8),
              // —— 下段：截止日期 + 倒计时徽标 + 操作菜单 ——
              Row(
                children: [
                  Icon(Icons.schedule, size: 14, color: scheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '截止 ${formatLocalDate(parseLocalDate(goal.deadlineDate))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  // 倒计时徽标：胶囊底色 + 阶段文案（文字不只依赖颜色）。
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: phaseColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      CountdownService.label(phase, days),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: phaseColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  PopupMenuButton<String>(
                    tooltip: '目标操作',
                    padding: const EdgeInsets.all(4),
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
            ],
          ),
        ),
      ),
    );
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
