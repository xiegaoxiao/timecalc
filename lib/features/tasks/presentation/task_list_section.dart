import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../data/task_repository_provider.dart';
import 'task_form_dialog.dart';

/// 任务列表区域（FR-3.1/FR-3.2）：目标详情页内创建、编辑、删除、完成任务。
class TaskListSection extends ConsumerWidget {
  const TaskListSection({super.key, required this.goalId, required this.subjects});

  final int goalId;
  final List<Subject> subjects;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(taskListProvider(goalId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('任务', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => TaskFormDialog.show(
                context,
                goalId: goalId,
                subjects: subjects,
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加任务'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        tasksAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Text('任务加载失败：$error'),
          data: (tasks) {
            if (tasks.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('还没有任务，点击「添加任务」开始安排'),
              );
            }
            return Column(
              children: [
                for (final task in tasks)
                  _TaskTile(
                    goalId: goalId,
                    task: task,
                    subjects: subjects,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.goalId, required this.task, required this.subjects});

  final int goalId;
  final Task task;
  final List<Subject> subjects;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = task.status == 'done';
    final subjectName = task.subjectId == null
        ? null
        : subjects
            .where((s) => s.id == task.subjectId)
            .map((s) => s.name)
            .firstOrNull;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Checkbox(
          value: done,
          onChanged: (value) async {
            final repo = ref.read(taskRepositoryProvider);
            await repo.setDone(task.id, value ?? false);
            ref.invalidate(taskListProvider(goalId));
          },
        ),
        title: Text(
          task.title,
          style: done
              ? const TextStyle(decoration: TextDecoration.lineThrough)
              : null,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                DateFormat('yyyy-MM-dd').format(_parseDate(task.plannedDate)),
                if (task.estimatedMinutes != null)
                  '${task.estimatedMinutes} 分钟',
                ?subjectName,
              ].join(' · '),
            ),
            if (task.note?.isNotEmpty ?? false)
              Text(
                task.note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '任务操作',
          onSelected: (action) =>
              _handleAction(context, ref, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            const PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAction(
      BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(taskRepositoryProvider);
    switch (action) {
      case 'edit':
        await TaskFormDialog.show(
          context,
          goalId: goalId,
          task: task,
          subjects: subjects,
        );
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除任务「${task.title}」？'),
            content: const Text('此操作不可撤销。'),
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
        if (confirmed == true) {
          await repo.delete(task.id);
          ref.invalidate(taskListProvider(goalId));
        }
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
