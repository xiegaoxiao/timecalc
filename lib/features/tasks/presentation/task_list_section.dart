import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../services/duration_format.dart';
import '../data/recurrence_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'batch_task_form_dialog.dart';
import 'recurrence_task_dialog.dart';
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
    this.currentTasks,
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

  /// JSON 导入将替换的目标当前任务清单（替换针对整个目标，父级可传入
  /// 全部任务；默认取本区域的 [tasks]）。
  final List<Task>? currentTasks;

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
                    // JSON 导入为「替换」语义：传入将被替换并保留为历史的
                    // 目标当前任务清单。
                    currentTasks: currentTasks ?? tasks,
                  ),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('JSON 导入'),
                ),
                TextButton.icon(
                  onPressed: () => RecurrenceTaskDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                  ),
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: const Text('重复任务'),
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
            final ok = await runDbAction(
              context,
              action: () => repo.setDone(task.id, value ?? false),
            );
            if (ok) onChanged();
          },
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                task.title,
                style: done
                    ? const TextStyle(decoration: TextDecoration.lineThrough)
                    : null,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (task.recurrenceTemplateId != null) ...[
              const SizedBox(width: 6),
              const Tooltip(
                message: '重复任务',
                child: Icon(Icons.autorenew, size: 16),
              ),
            ],
          ],
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
            if (task.recurrenceTemplateId != null) ...[
              const PopupMenuItem(value: 'editRecurrence', child: Text('编辑重复规则')),
              const PopupMenuItem(value: 'stopRecurrence', child: Text('停止重复')),
            ],
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
      case 'editRecurrence':
        final templateId = task.recurrenceTemplateId;
        if (templateId != null) {
          final template =
              await ref.read(recurrenceTemplateProvider(templateId).future);
          if (template != null && context.mounted) {
            await RecurrenceTaskDialog.show(
              context,
              goalId: goalId,
              subjects: subjects,
              editTemplate: template,
            );
            onChanged();
          }
        }
      case 'stopRecurrence':
        final templateId = task.recurrenceTemplateId;
        if (templateId != null) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('停止重复？'),
              content: const Text('停止后不再生成新的重复任务，已生成的任务保留。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('停止重复'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            if (!context.mounted) return;
            final ok = await runDbAction(
              context,
              action: () => ref.read(recurrenceRepositoryProvider).stop(templateId),
            );
            if (!ok) return;
            ref.invalidate(recurrenceTemplatesProvider(goalId));
            onChanged();
          }
        }
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
          if (!context.mounted) return;
          final ok = await runDbAction(
            context,
            action: () => repo.delete(task.id),
          );
          if (ok) onChanged();
        }
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
