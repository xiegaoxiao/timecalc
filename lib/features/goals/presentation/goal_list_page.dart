import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/countdown_service.dart';
import '../data/goal_repository_provider.dart';
import 'goal_form_dialog.dart';

/// 计划页：目标列表（FR-1 目标 CRUD 入口）。
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
    final goalsAsync = ref.watch(goalListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('计划')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createGoal(context),
        tooltip: '创建目标',
        child: const Icon(Icons.add),
      ),
      body: goalsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorView(error: error),
        data: (goals) {
          if (goals.isEmpty) {
            return const _EmptyView();
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: goals.length,
            itemBuilder: (context, index) {
              return _GoalCard(goal: goals[index]);
            },
          );
        },
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  Future<void> _createGoal(BuildContext context) async {
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

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 8),
          const Text('加载目标失败'),
          const SizedBox(height: 4),
          Text('$error'),
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
    final phaseColor = switch (phase) {
      CountdownPhase.upcoming => scheme.primary,
      CountdownPhase.today => scheme.error,
      CountdownPhase.overdue => scheme.error,
      CountdownPhase.terminated => scheme.outline,
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
            Text(
              '截止 ${DateFormat('yyyy-MM-dd').format(_parseDate(goal.deadlineDate))}',
            ),
            const SizedBox(height: 2),
            // 状态不只依赖颜色（NFR-4）：阶段文案 + 图标。
            Row(
              children: [
                Icon(phase == CountdownPhase.upcoming
                    ? Icons.schedule
                    : Icons.error_outline,
                    size: 14,
                    color: phaseColor),
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
      BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(goalRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'edit':
        await GoalFormDialog.show(context, goal: goal);
      case 'complete':
        await repo.update(id: goal.id, status: 'completed', completedAt: DateTime.now().toUtc());
        ref.invalidate(goalListProvider);
        messenger.showSnackBar(SnackBar(content: Text('「${goal.title}」已标记为完成')));
      case 'abandon':
        await repo.update(id: goal.id, status: 'abandoned');
        ref.invalidate(goalListProvider);
        messenger.showSnackBar(SnackBar(content: Text('「${goal.title}」已标记为放弃')));
      case 'archive':
        await repo.update(id: goal.id, status: 'archived');
        ref.invalidate(goalListProvider);
        messenger.showSnackBar(SnackBar(content: Text('「${goal.title}」已归档')));
      case 'delete':
        await _confirmDelete(context, ref);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    // FR-1 验收：删除目标前必须二次确认，并明确提示将同时删除其任务。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除目标？'),
        content: Text(
          '将删除「${goal.title}」及其全部任务。此操作不可撤销。',
        ),
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

    final repo = ref.read(goalRepositoryProvider);
    await repo.deleteWithCascade(goal.id);
    ref.invalidate(goalListProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${goal.title}」及其任务已删除')),
      );
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
