import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/countdown_service.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/task_list_section.dart';
import '../data/goal_repository_provider.dart';
import '../data/subject_repository_provider.dart';
import 'goal_form_dialog.dart';
import 'subject_manager.dart';

/// 目标详情页：目标概览 → 科目列表 → 未分类任务（PRD §7 层级）。
///
/// 点击科目进入该科目的任务列表页；未归属科目的任务在本页「未分类」区管理。
class GoalDetailPage extends ConsumerWidget {
  const GoalDetailPage({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalAsync = ref.watch(goalDetailProvider(int.parse(goalId)));
    return Scaffold(
      appBar: AppBar(title: const Text('目标详情')),
      body: goalAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (goal) {
          if (goal == null) {
            return const Center(child: Text('目标不存在'));
          }
          return GoalDetailBody(goal: goal);
        },
      ),
    );
  }
}

class GoalDetailBody extends ConsumerWidget {
  const GoalDetailBody({super.key, required this.goal});

  final Goal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(subjectListProvider(goal.id));
    final tasksAsync = ref.watch(taskListProvider(goal.id));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _GoalHeader(goal: goal),
        const Divider(height: 32),
        SubjectManager(goalId: goal.id),
        const Divider(height: 32),
        // 未归属科目的任务在详情页直接管理（无科目页可进）。
        subjectsAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (subjects) => tasksAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (tasks) {
              final unassigned =
                  tasks.where((t) => t.subjectId == null).toList();
              return TaskListSection(
                goalId: goal.id,
                subjects: subjects,
                tasks: unassigned,
                title: '未分类任务',
                description: '不归属特定科目的安排，如科目复习/复盘、考研报名等',
                emptyText: '还没有此类任务。可点「添加任务」或「批量添加」创建',
                onChanged: () => ref.invalidate(taskListProvider(goal.id)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GoalHeader extends ConsumerWidget {
  const _GoalHeader({required this.goal});

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
    final (phaseColor, phaseIcon) = switch (phase) {
      CountdownPhase.upcoming => (scheme.primary, Icons.schedule),
      CountdownPhase.today => (scheme.error, Icons.today),
      CountdownPhase.overdue => (scheme.error, Icons.error_outline),
      CountdownPhase.terminated => (scheme.outline, Icons.flag_outlined),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                goal.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: '编辑目标',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => GoalFormDialog.show(context, goal: goal),
            ),
          ],
        ),
        if (goal.description?.isNotEmpty ?? false) ...[
          const SizedBox(height: 8),
          Text(goal.description!),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(phaseIcon, size: 18, color: phaseColor),
            const SizedBox(width: 6),
            Text(
              '${CountdownService.label(phase, days)} · 截止 ${DateFormat('yyyy-MM-dd').format(_parseDate(goal.deadlineDate))}',
              style: TextStyle(
                color: phaseColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
