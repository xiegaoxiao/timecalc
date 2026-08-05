import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../services/duration_format.dart';
import '../data/task_repository_provider.dart';
import 'batch_task_form_dialog.dart';
import 'task_form_dialog.dart';
import 'task_import_dialog.dart';

/// 任务列表区域（FR-3.1/FR-3.2）：创建、编辑、删除、完成任务。
///
/// 父级负责按上下文过滤 [tasks]（如科目任务页只传该科目任务，
/// 目标详情页只传未分类任务），并处理 [onChanged] 触发数据刷新。
class TaskListSection extends ConsumerWidget {
  const TaskListSection({
    super.key,
    required this.goalId,
    required this.subjects,
    required this.tasks,
    required this.onChanged,
    this.title,
    this.description,
    this.emptyText = '还没有任务，点击「添加任务」开始安排',
    this.defaultSubjectId,
    this.showAddButton = true,
  });

  final int goalId;
  final List<Subject> subjects;
  final List<Task> tasks;
  final VoidCallback onChanged;
  final String? title;

  /// 标题下方的常驻说明（如未分类任务区的用途引导）。
  final String? description;
  final String emptyText;
  final int? defaultSubjectId;
  final bool showAddButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Row(
            children: [
              Text(title!, style: Theme.of(context).textTheme.titleMedium),
              if (showAddButton) ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: () => TaskFormDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                    defaultSubjectId: defaultSubjectId,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加任务'),
                ),
                TextButton.icon(
                  onPressed: () => BatchTaskFormDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                    defaultSubjectId: defaultSubjectId,
                  ),
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('批量添加'),
                ),
                TextButton.icon(
                  onPressed: () => TaskImportDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                  ),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('JSON 导入'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (description != null) ...[
          const SizedBox(height: 2),
          Text(
            description!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(emptyText),
          )
        else
          Column(
            children: [
              for (final task in tasks)
                _TaskTile(
                  goalId: goalId,
                  task: task,
                  subjects: subjects,
                  onChanged: onChanged,
                ),
            ],
          ),
      ],
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({
    required this.goalId,
    required this.task,
    required this.subjects,
    required this.onChanged,
  });

  final int goalId;
  final Task task;
  final List<Subject> subjects;
  final VoidCallback onChanged;

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
            onChanged();
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
                  DurationFormat.minutes(task.estimatedMinutes!),
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
        onChanged();
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
          onChanged();
        }
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
