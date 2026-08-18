import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../data/milestone_repository_provider.dart';
import 'milestone_form_dialog.dart';

/// 里程碑共享操作（2026-08-18 从 MilestoneSection 提取）：详情页与
/// 全部里程碑页共用同一套「表单/勾选完成/删除」流程，避免复制漂移。
///
/// 数据刷新语义：成功后均 invalidate `milestoneListProvider(goalId)`，
/// 详情页/全部页/首页「下一里程碑」卡片随之更新。

/// 打开添加/编辑弹窗；[milestone] 为空表示添加，非空表示编辑。
/// 返回是否保存成功（null = 取消），供调用方决定「添加后自动展开」等行为。
Future<bool?> showMilestoneForm(
  BuildContext context, {
  required int goalId,
  required String deadlineDate,
  Milestone? milestone,
}) {
  return MilestoneFormDialog.show(
    context,
    goalId: goalId,
    deadlineDate: deadlineDate,
    milestone: milestone,
  );
}

/// 勾选/取消勾选完成。失败（runDbAction 拒绝）返回 false。
Future<bool> toggleMilestoneDone(
  BuildContext context,
  WidgetRef ref, {
  required int goalId,
  required Milestone milestone,
}) async {
  final done = milestone.status == MilestoneStatus.done;
  final repo = ref.read(milestoneRepositoryProvider);
  final ok = await runDbAction(
    context,
    action: () => repo.update(id: milestone.id, done: !done),
  );
  if (!ok) return false;
  ref.invalidate(milestoneListProvider(goalId));
  return true;
}

/// 二次确认后删除。未确认/删除失败返回 false。
Future<bool> confirmDeleteMilestone(
  BuildContext context,
  WidgetRef ref, {
  required int goalId,
  required Milestone milestone,
}) async {
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
  if (confirmed != true) return false;
  if (!context.mounted) return false;

  final repo = ref.read(milestoneRepositoryProvider);
  final ok = await runDbAction(
    context,
    action: () => repo.delete(milestone.id),
  );
  if (!ok) return false;
  ref.invalidate(milestoneListProvider(goalId));
  return true;
}
