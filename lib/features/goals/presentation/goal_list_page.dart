import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../tasks/data/recurrence_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../data/goal_repository_provider.dart';
import 'goal_form_dialog.dart';

/// 计划页：目标列表（FR-1 目标 CRUD 入口）。
///
/// [GoalListBody] 抽出无 Scaffold 的目标列表主体，供 M2 计划页
/// 「目标」分段内嵌复用；本页保留独立使用时的 Scaffold 与 FAB。
class GoalListPage extends ConsumerWidget {
  const GoalListPage({super.key});

  /// 打开创建对话框；创建成功后自动进入目标详情页，引导继续添加任务。
  Future<void> _createGoal(BuildContext context) async {
    final createdId = await GoalFormDialog.show(context);
    if (createdId != null && context.mounted) {
      context.push('/goals/$createdId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('计划')),
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
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: goals.length,
          itemBuilder: (context, index) {
            return _GoalCard(goal: goals[index]);
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
    // 数据为空时提供与当前页相关的首个操作（PRD §8）。
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.flag_outlined, size: 64),
          const SizedBox(height: 12),
          const Text('还没有目标'),
          const SizedBox(height: 4),
          const Text('创建一个目标，把截止日期变成今天的行动'),
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

class _GoalCard extends ConsumerWidget {
  const _GoalCard({required this.goal});

  final Goal goal;

  static const _countdown = CountdownService();

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

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(goal.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '截止 ${DateFormat('yyyy-MM-dd').format(parseLocalDate(goal.deadlineDate))}',
            ),
            const SizedBox(height: 2),
            // 状态不只依赖颜色（NFR-4）：阶段文案 + 图标。
            Row(
              children: [
                Icon(
                  phase == CountdownPhase.upcoming
                      ? Icons.schedule
                      : Icons.error_outline,
                  size: 14,
                  color: phaseColor,
                ),
                const SizedBox(width: 4),
                Text(
                  CountdownService.label(phase, days),
                  style: TextStyle(color: phaseColor),
                ),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: '目标操作',
          onSelected: (action) => _handleAction(context, ref, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            const PopupMenuItem(value: 'complete', child: Text('标记已完成')),
            const PopupMenuItem(value: 'abandon', child: Text('标记已放弃')),
            const PopupMenuItem(value: 'archive', child: Text('归档')),
            const PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
        // push 压入导航栈，详情页 AppBar 自动出现返回箭头。
        onTap: () => context.push('/goals/${goal.id}'),
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
