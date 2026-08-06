import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../data/task_repository_provider.dart';

/// 创建/编辑任务对话框（FR-3.1：标题、计划日期、预估时长、状态、可选备注与科目）。
///
/// [task] 为空表示创建，非空表示编辑。
/// [defaultSubjectId] 仅在创建模式生效：科目任务页创建任务时默认归属该科目。
class TaskFormDialog extends ConsumerStatefulWidget {
  const TaskFormDialog({
    super.key,
    required this.goalId,
    this.task,
    this.subjects = const [],
    this.defaultSubjectId,
  });

  final int goalId;
  final Task? task;
  final List<Subject> subjects;
  final int? defaultSubjectId;

  static Future<bool> show(
    BuildContext context, {
    required int goalId,
    Task? task,
    List<Subject> subjects = const [],
    int? defaultSubjectId,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => TaskFormDialog(
        goalId: goalId,
        task: task,
        subjects: subjects,
        defaultSubjectId: defaultSubjectId,
      ),
    ).then((saved) => saved ?? false);
  }

  @override
  ConsumerState<TaskFormDialog> createState() => _TaskFormDialogState();
}

class _TaskFormDialogState extends ConsumerState<TaskFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  final _noteController = TextEditingController();
  DateTime? _plannedDate;
  int? _subjectId;
  int? _estimatedMinutes;
  bool _saving = false;

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _noteController.text = task?.note ?? '';
    _plannedDate = task == null ? DateTime.now() : _parseDate(task.plannedDate);
    // 编辑模式沿用任务原科目；创建模式默认归属 defaultSubjectId（科目页入口）。
    _subjectId = task?.subjectId ?? widget.defaultSubjectId;
    _estimatedMinutes = task?.estimatedMinutes;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  static DateTime? _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    if (parts.length != 3) return null;
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _plannedDate ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
      helpText: '选择计划日期',
    );
    if (picked != null) {
      setState(() => _plannedDate = picked);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    // 0 分钟视为未设置（预估时长合法范围为 1～1440，FR-3 验收）。
    final minutes = _estimatedMinutes == 0 ? null : _estimatedMinutes;

    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      final dateText = DateFormat('yyyy-MM-dd').format(_plannedDate!);
      final ok = await runDbAction(
        context,
        action: () async {
          if (_isEdit) {
            await repo.update(
              id: widget.task!.id,
              title: title,
              // 空备注显式置空（Value(null)）：编辑时清空备注必须落库。
              note: Value(_noteController.text.trim().isEmpty
                  ? null
                  : _noteController.text.trim()),
              plannedDate: dateText,
              estimatedMinutes: Value(minutes),
              subjectId: Value(_subjectId),
            );
          } else {
            await repo.create(
              goalId: widget.goalId,
              subjectId: _subjectId,
              title: title,
              note: _noteController.text.trim().isEmpty
                  ? null
                  : _noteController.text.trim(),
              plannedDate: dateText,
              estimatedMinutes: minutes,
            );
          }
        },
      );
      if (!ok) return;
      // 跨页刷新（FR-3 验收）：任务日期/状态变更影响今天页、日历、逾期横幅。
      ref.invalidate(taskListProvider(widget.goalId));
      ref.invalidate(tasksByDateProvider);
      ref.invalidate(tasksByMonthProvider);
      ref.invalidate(unfinishedBeforeProvider);
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑任务' : '创建任务'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '任务标题 *',
                  hintText: '例如：完成第一章复习',
                ),
                maxLength: 200,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入任务标题';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '计划日期 *',
                    border: OutlineInputBorder(),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event_outlined),
                      const SizedBox(width: 8),
                      Text(DateFormat('yyyy-MM-dd').format(_plannedDate!)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DurationStepInput(
                label: '预估时长',
                value: _estimatedMinutes,
                allowEmpty: true,
                onChanged: (minutes) => setState(() => _estimatedMinutes = minutes),
                hourFieldKey: const Key('taskHourField'),
                minuteFieldKey: const Key('taskMinuteField'),
              ),
              const SizedBox(height: 16),
              if (widget.subjects.isNotEmpty)
                DropdownButtonFormField<int?>(
                  initialValue: _subjectId,
                  decoration: const InputDecoration(
                    labelText: '科目（可选）',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('（无）')),
                    for (final s in widget.subjects)
                      DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (value) => setState(() => _subjectId = value),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_isEdit ? '保存' : '创建'),
        ),
      ],
    );
  }
}
