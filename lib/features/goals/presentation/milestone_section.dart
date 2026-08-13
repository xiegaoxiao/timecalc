import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/utils/date_text.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../data/milestone_repository_provider.dart';
import 'milestone_form_dialog.dart';

/// 里程碑管理组件（FR-2）：目标下的阶段性节点列表。
///
/// 每个里程碑显示日期与标题，支持添加、编辑、标记完成、删除（FR-2.1）；
/// 日期晚于目标截止日的保存被阻断（FR-2.2，见 MilestoneFormDialog）。
/// 完整里程碑列表在此展示（FR-2.3）。
class MilestoneSection extends ConsumerWidget {
  const MilestoneSection({
    super.key,
    required this.goalId,
    required this.deadlineDate,
  });

  final int goalId;

  /// 目标截止日（`yyyy-MM-dd`），传给表单做 FR-2.2 校验。
  final String deadlineDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final milestonesAsync = ref.watch(milestoneListProvider(goalId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('里程碑', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _addMilestone(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加里程碑'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        milestonesAsync.when(
          // 静态占位（非 spinner）：首载窗口与页面过渡动画叠加会造成
          // 闪烁/掉帧（Windows 实测），数据到达即被真实列表替换。
          loading: () => const Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [Text('正在加载里程碑…')],
              ),
            ),
          ),
          error: (error, _) => AppErrorView(error: error),
          data: (milestones) {
            if (milestones.isEmpty) {
              // 空态内容横向居中：本列 start 对齐，需给全宽内部才能居中。
              return const SizedBox(
                width: double.infinity,
                child: ChartEmptyState(
                  icon: Icons.flag_outlined,
                  title: '还没有里程碑，点击「添加里程碑」设定阶段性节点',
                ),
              );
            }
            return Column(
              children: [
                for (final milestone in milestones)
                  _MilestoneCard(
                    milestone: milestone,
                    onEdit: () => _editMilestone(context, ref, milestone),
                    onToggleDone: () => _toggleDone(context, ref, milestone),
                    onDelete: () => _deleteMilestone(context, ref, milestone),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _addMilestone(BuildContext context, WidgetRef ref) async {
    // 保存成功后表单内部已 invalidate milestoneListProvider，无需再刷新。
    await MilestoneFormDialog.show(
      context,
      goalId: goalId,
      deadlineDate: deadlineDate,
    );
  }

  Future<void> _editMilestone(
    BuildContext context,
    WidgetRef ref,
    Milestone milestone,
  ) async {
    await MilestoneFormDialog.show(
      context,
      goalId: goalId,
      deadlineDate: deadlineDate,
      milestone: milestone,
    );
  }

  Future<void> _toggleDone(
    BuildContext context,
    WidgetRef ref,
    Milestone milestone,
  ) async {
    final done = milestone.status == MilestoneStatus.done;
    final repo = ref.read(milestoneRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.update(id: milestone.id, done: !done),
    );
    if (!ok) return;
    ref.invalidate(milestoneListProvider(goalId));
  }

  Future<void> _deleteMilestone(
    BuildContext context,
    WidgetRef ref,
    Milestone milestone,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除里程碑「${milestone.title}」？'),
        content: const Text('删除后不可恢复。'),
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

    final repo = ref.read(milestoneRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.delete(milestone.id),
    );
    if (!ok) return;
    ref.invalidate(milestoneListProvider(goalId));
  }
}

class _MilestoneCard extends StatelessWidget {
  const _MilestoneCard({
    required this.milestone,
    required this.onEdit,
    required this.onToggleDone,
    required this.onDelete,
  });

  final Milestone milestone;
  final VoidCallback onEdit;
  final VoidCallback onToggleDone;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final done = milestone.status == MilestoneStatus.done;
    final scheme = Theme.of(context).colorScheme;
    final date = parseLocalDate(milestone.date);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Checkbox(
          value: done,
          // NFR-4：完成状态不只依赖颜色（划线 + Checkbox）。
          semanticLabel: '标记里程碑「${milestone.title}」为${done ? '未完成' : '已完成'}',
          onChanged: (_) => onToggleDone(),
        ),
        title: Text(
          milestone.title,
          style: done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: scheme.outline,
                )
              : null,
        ),
        subtitle: Text(
          '${formatLocalDate(date)}'
          '${done ? ' · 已完成' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '编辑里程碑「${milestone.title}」',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: onEdit,
            ),
            PopupMenuButton<String>(
              tooltip: '里程碑操作',
              onSelected: (action) {
                if (action == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
