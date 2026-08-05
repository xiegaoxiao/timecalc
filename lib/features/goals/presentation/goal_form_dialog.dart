import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../data/goal_repository_provider.dart';

/// 创建/编辑目标对话框（FR-1.1：名称与截止日期为必填项）。
///
/// [goal] 为空表示创建，非空表示编辑。
class GoalFormDialog extends ConsumerStatefulWidget {
  const GoalFormDialog({super.key, this.goal});

  final Goal? goal;

  static Future<void> show(BuildContext context, {Goal? goal}) {
    return showDialog<void>(
      context: context,
      builder: (_) => GoalFormDialog(goal: goal),
    );
  }

  @override
  ConsumerState<GoalFormDialog> createState() => _GoalFormDialogState();
}

class _GoalFormDialogState extends ConsumerState<GoalFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  final _descriptionController = TextEditingController();
  DateTime? _deadline;
  bool _saving = false;

  bool get _isEdit => widget.goal != null;

  @override
  void initState() {
    super.initState();
    final goal = widget.goal;
    _titleController = TextEditingController(text: goal?.title ?? '');
    _descriptionController.text = goal?.description ?? '';
    _deadline = goal == null ? null : _parseDate(goal.deadlineDate);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  static DateTime? _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    if (parts.length != 3) return null;
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
      helpText: '选择截止日期',
    );
    if (picked != null) {
      setState(() => _deadline = picked);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    final deadline = _deadline!;

    setState(() => _saving = true);
    try {
      final repo = ref.read(goalRepositoryProvider);
      final dateText = DateFormat('yyyy-MM-dd').format(deadline);
      if (_isEdit) {
        await repo.update(
          id: widget.goal!.id,
          title: title,
          deadlineDate: dateText,
          description: Value(_descriptionController.text.trim()),
        );
      } else {
        await repo.create(
          title: title,
          deadlineDate: dateText,
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
        );
      }
      ref.invalidate(goalListProvider);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑目标' : '创建目标'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '目标名称 *',
                hintText: '例如：考研数学',
              ),
              maxLength: 200,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '请输入目标名称';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDeadline,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '截止日期 *',
                  border: OutlineInputBorder(),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.event_outlined),
                    const SizedBox(width: 8),
                    Text(
                      _deadline == null
                          ? '请选择日期'
                          : DateFormat('yyyy-MM-dd').format(_deadline!),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: '描述（可选）',
                hintText: '目标背景、范围说明',
              ),
              maxLines: 2,
            ),
          ],
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
