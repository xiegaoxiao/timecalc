import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/countdown_service.dart';
import '../../tasks/presentation/task_list_section.dart';
import '../data/goal_repository_provider.dart';
import '../data/subject_repository_provider.dart';
import 'goal_form_dialog.dart';
import 'subject_manager.dart';

/// 目标详情页：目标概览 → 科目 → 任务（PRD §7 层级）。
class GoalDetailPage extends ConsumerWidget {
  const GoalDetailPage({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalAsync = ref.watch(goalDetailProvider(goalId));
    return Scaffold(
      appBar: AppBar(title: const Text('目标详情')),
      body: goalAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (goal) {
          if (goal == null) {
            return const Center(child: Text('目标不存在'));
          }
          final subjectsAsync = ref.watch(subjectListProvider(goal.id));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _GoalHeader(goal: goal),
              const Divider(height: 32),
              SubjectManager(goalId: goal.id),
              const SizedBox(height: 24),
              subjectsAsync.maybeWhen(
                data: (subjects) => TaskListSection(
                  goalId: goal.id,
                  subjects: subjects,
                ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个目标的详情查询 Provider。
final goalDetailProvider = FutureProvider.family<Goal?, String>((ref, id) {
  return ref.watch(goalRepositoryProvider).byId(int.parse(id));
});

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
