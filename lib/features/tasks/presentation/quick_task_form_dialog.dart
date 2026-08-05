import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../data/task_repository_provider.dart';
import '../domain/duration_validator.dart';

/// 跨目标快速创建任务对话框（M2：今日页/日历选日面板「添加任务」）。
///
/// 在 [date]（本地日历日期）创建任务，需从 [goals] 选择一个目标
/// （FR-1.5：任务必须属于一个目标）。科目在此不选（可稍后编辑），
/// 保持快速录入的轻量路径。
class QuickTaskFormDialog extends ConsumerStatefulWidget {
  const QuickTaskFormDialog({
    super.key,
    required this.date,
    required this.goals,
    this.defaultGoalId,
  });

  final DateTime date;
  final List<Goal> goals;
  final int? defaultGoalId;

  static Future<void> show(
    BuildContext context, {
    required DateTime date,
    required List<Goal> goals,
    int? defaultGoalId,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => QuickTaskFormDialog(
        date: date,
        goals: goals,
        defaultGoalId: defaultGoalId,
      ),
    );
  }

  @override
  ConsumerState<QuickTaskFormDialog> createState() =>
      _QuickTaskFormDialogState();
}

class _QuickTaskFormDialogState extends ConsumerState<QuickTaskFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  final _minutesController = TextEditingController();
  final _noteController = TextEditingController();
  late int? _goalId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _goalId = widget.goals.isEmpty
        ? null
        : (widget.defaultGoalId ?? widget.goals.first.id);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _minutesController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final goalId = _goalId;
    if (goalId == null) return;
    final minutesText = _minutesController.text.trim();

    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      await repo.create(
        goalId: goalId,
        title: _titleController.text.trim(),
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        plannedDate: DateFormat('yyyy-MM-dd').format(widget.date),
        estimatedMinutes:
            minutesText.isEmpty ? null : int.parse(minutesText),
      );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加任务'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int?>(
                initialValue: _goalId,
                decoration: const InputDecoration(
                  labelText: '目标 *',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final g in widget.goals)
                    DropdownMenuItem<int?>(value: g.id, child: Text(g.title)),
                ],
                onChanged: (value) => setState(() => _goalId = value),
              ),
              const SizedBox(height: 12),
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
          child: const Text('创建'),
        ),
      ],
    );
  }
}
