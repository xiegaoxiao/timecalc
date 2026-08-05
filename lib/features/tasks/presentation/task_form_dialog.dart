import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../data/task_repository_provider.dart';
import '../domain/duration_validator.dart';

/// 创建/编辑任务对话框（FR-3.1：标题、计划日期、预估分钟、状态、可选备注与科目）。
///
/// [task] 为空表示创建，非空表示编辑。
class TaskFormDialog extends ConsumerStatefulWidget {
  const TaskFormDialog({super.key, required this.goalId, this.task, this.subjects = const []});

  final int goalId;
  final Task? task;
  final List<Subject> subjects;

  static Future<void> show(
    BuildContext context, {
    required int goalId,
    Task? task,
    List<Subject> subjects = const [],
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => TaskFormDialog(
        goalId: goalId,
        task: task,
        subjects: subjects,
      ),
    );
  }

  @override
  ConsumerState<TaskFormDialog> createState() => _TaskFormDialogState();
}

class _TaskFormDialogState extends ConsumerState<TaskFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _minutesController;
  final _noteController = TextEditingController();
  DateTime? _plannedDate;
  int? _subjectId;
  bool _saving = false;

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _minutesController = TextEditingController(
      text: task?.estimatedMinutes?.toString() ?? '',
    );
    _noteController.text = task?.note ?? '';
    _plannedDate = task == null ? DateTime.now() : _parseDate(task.plannedDate);
    _subjectId = task?.subjectId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _minutesController.dispose();
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
    final minutesText = _minutesController.text.trim();
    final estimatedMinutes =
        minutesText.isEmpty ? null : int.parse(minutesText);

    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      final dateText = DateFormat('yyyy-MM-dd').format(_plannedDate!);
      if (_isEdit) {
        await repo.update(
          id: widget.task!.id,
          title: title,
          note: _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
          plannedDate: dateText,
          estimatedMinutes: Value(estimatedMinutes),
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
          estimatedMinutes: estimatedMinutes,
        );
      }
      ref.invalidate(taskListProvider(widget.goalId));
      if (mounted) Navigator.of(context).pop();
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
              const SizedBox(height: 12),
              TextFormField(
                controller: _minutesController,
                decoration: const InputDecoration(
                  labelText: '预估时长（分钟）',
                  hintText: '1～1440',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  return DurationValidator.validate(value);
                },
              ),
              const SizedBox(height: 12),
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
