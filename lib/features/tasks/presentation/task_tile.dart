import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/defer_service.dart';
import '../../../services/duration_format.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/recurrence_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'recurrence_task_dialog.dart';
import 'task_form_dialog.dart';

/// 跨目标任务条目（M2：今日页与日历选日面板共用）。
///
/// 支持：完成/取消完成、编辑、延期至下一可用日、指定日期延期、删除。
/// [onChanged] 由父级触发相关 Provider 刷新；任务内容/归属/预估时长
/// 在延期时保持不变（FR-3.3 验收）。
class TaskTile extends ConsumerWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onChanged,
    this.goalTitle,
  });

  final Task task;

  /// 变更后通知父级刷新（如 invalidate 相关 Provider）。
  final VoidCallback onChanged;

  /// 跨目标场景下展示目标名（如今日页）。
  final String? goalTitle;

  static const _defer = DeferService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = task.status == 'done';

    // 科目名：任务归属科目的名称；无科目或科目加载中则为空。
    final subjectName = ref
        .watch(subjectListProvider(task.goalId))
        .valueOrNull
        ?.where((s) => s.id == task.subjectId)
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
                ?goalTitle,
                ?subjectName,
                if (task.estimatedMinutes != null)
                  DurationFormat.minutes(task.estimatedMinutes!),
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
          onSelected: (action) => _handleAction(context, ref, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            const PopupMenuItem(value: 'deferNext', child: Text('延期至下一可用日')),
            const PopupMenuItem(value: 'deferPick', child: Text('延期…')),
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
    switch (action) {
      case 'edit':
        await _edit(context, ref);
      case 'deferNext':
        await _deferToNextAvailable(context, ref);
      case 'deferPick':
        await _deferPickDate(context, ref);
      case 'editRecurrence':
        await _editRecurrence(context, ref);
      case 'stopRecurrence':
        await _stopRecurrence(context, ref);
      case 'delete':
        await _delete(context, ref);
    }
  }

  /// 编辑重复规则（打开规则对话框，预填当前模板）。
  Future<void> _editRecurrence(BuildContext context, WidgetRef ref) async {
    final templateId = task.recurrenceTemplateId;
    if (templateId == null) return;
    final template = await ref.read(recurrenceTemplateProvider(templateId).future);
    if (template == null || !context.mounted) return;
    final subjects =
        ref.read(subjectListProvider(task.goalId)).valueOrNull ?? const <Subject>[];
    await RecurrenceTaskDialog.show(
      context,
      goalId: task.goalId,
      subjects: subjects,
      editTemplate: template,
    );
    onChanged();
  }

  /// 停止重复（确认后停用模板，历史实例保留，FR-4.5）。
  Future<void> _stopRecurrence(BuildContext context, WidgetRef ref) async {
    final templateId = task.recurrenceTemplateId;
    if (templateId == null) return;
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
    if (confirmed != true) return;
    final repo = ref.read(recurrenceRepositoryProvider);
    await repo.stop(templateId);
    ref.invalidate(recurrenceTemplatesProvider(task.goalId));
    onChanged();
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    // 编辑对话框需要该目标下的科目列表（含无科目选项）。
    final subjects = await ref.read(subjectListProvider(task.goalId).future);
    if (!context.mounted) return;
    await TaskFormDialog.show(
      context,
      goalId: task.goalId,
      task: task,
      subjects: subjects,
    );
    onChanged();
  }

  Future<void> _deferToNextAvailable(BuildContext context, WidgetRef ref) async {
    final settings = await ref.read(settingsProvider.future);
    final today = ref.read(clockProvider)();
    final next = _defer.nextAvailableDate(
      today: today,
      availableWeekdays: SettingsRepository.decodeWeekdays(
        settings.availableWeekdays,
      ),
    );
    final repo = ref.read(taskRepositoryProvider);
    await repo.defer(task.id, next);
    onChanged();
  }

  Future<void> _deferPickDate(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _parseDate(task.plannedDate),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: '选择延期日期',
    );
    if (picked == null) return;
    final repo = ref.read(taskRepositoryProvider);
    await repo.defer(task.id, DateFormat('yyyy-MM-dd').format(picked));
    onChanged();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
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
    if (confirmed != true) return;
    final repo = ref.read(taskRepositoryProvider);
    await repo.delete(task.id);
    onChanged();
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
