import 'package:flutter/material.dart';

import '../../../core/database/database.dart';
import 'batch_task_form_dialog.dart';
import 'recurrence_task_dialog.dart';
import 'task_form_dialog.dart';
import 'task_import_dialog.dart';

/// 任务区头部操作组（2026-08-18 从 TaskListSection 头部提取复用）：
/// 「添加任务」「批量添加」+ 折叠进「更多操作」的高级入口（JSON 导入/
/// 重复任务）。
///
/// 目标详情页/科目任务页的任务区改为可折叠后，操作组常驻折叠头部行
/// （CollapsibleSection.trailing），折叠列表时添加/导入入口不消失。
class TaskSectionActions extends StatelessWidget {
  const TaskSectionActions({
    super.key,
    required this.goalId,
    required this.subjects,
    this.defaultSubjectId,
    this.currentTasks,
  });

  final int goalId;
  final List<Subject> subjects;

  /// 新建任务默认归属的科目（科目任务页传当前科目，详情页不传）。
  final int? defaultSubjectId;

  /// JSON 导入为「替换」语义时的当前任务清单（对话框展示将被替换的清单）。
  final List<Task>? currentTasks;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        // 高级操作（JSON 导入/重复任务）折叠进「更多操作」：空态下主操作
        // 已覆盖绝大多数场景，避免一行四个按钮的视觉噪音与小屏溢出。
        PopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: (action) {
            switch (action) {
              case 'import':
                TaskImportDialog.show(
                  context,
                  goalId: goalId,
                  subjects: subjects,
                  // JSON 导入为「替换」语义：传入将被替换并保留为历史的
                  // 当前任务清单。
                  currentTasks: currentTasks ?? const [],
                );
                break;
              case 'recurrence':
                RecurrenceTaskDialog.show(
                  context,
                  goalId: goalId,
                  subjects: subjects,
                );
                break;
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'import', child: Text('JSON 导入')),
            PopupMenuItem(value: 'recurrence', child: Text('重复任务')),
          ],
        ),
      ],
    );
  }
}
