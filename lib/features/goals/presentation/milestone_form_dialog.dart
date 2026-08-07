import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/utils/date_text.dart';
import '../data/milestone_repository_provider.dart';

/// 添加/编辑里程碑对话框（FR-2.1）。
///
/// 字段：标题（必填）、日期（必填）。里程碑日期原则上不得晚于目标截止日
/// （FR-2.2）：日期晚于截止日时在保存前给出阻断提示，不写入。
/// 创建成功后返回 true，编辑保存返回 false；取消返回 null。
class MilestoneFormDialog extends ConsumerStatefulWidget {
  const MilestoneFormDialog({
    super.key,
    required this.goalId,
    required this.deadlineDate,
    this.milestone,
  });

  final int goalId;

  /// 目标截止日（`yyyy-MM-dd`），用于 FR-2.2 日期校验。
  final String deadlineDate;

  /// 为空表示创建，非空表示编辑。
  final Milestone? milestone;

  static Future<bool?> show(
    BuildContext context, {
    required int goalId,
    required String deadlineDate,
    Milestone? milestone,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => MilestoneFormDialog(
        goalId: goalId,
        deadlineDate: deadlineDate,
        milestone: milestone,
      ),
    );
  }

  @override
  ConsumerState<MilestoneFormDialog> createState() => _MilestoneFormDialogState();
}

class _MilestoneFormDialogState extends ConsumerState<MilestoneFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _dateFieldKey = GlobalKey<FormFieldState<DateTime>>();
  late final TextEditingController _titleController;
  DateTime? _date;
  bool _saving = false;

  bool get _isEdit => widget.milestone != null;

  @override
  void initState() {
    super.initState();
    final milestone = widget.milestone;
    _titleController = TextEditingController(text: milestone?.title ?? '');
    _date = milestone == null ? null : parseLocalDate(milestone.date);
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final field = _dateFieldKey.currentState;
    final picked = await showDatePicker(
      context: context,
      initialDate: field?.value ?? _date ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
      helpText: '选择里程碑日期',
    );
    if (picked != null) {
      setState(() => _date = picked);
      // 同步 FormField 内部值，让日期选择后的校验错误即时消除。
      field?.didChange(picked);
    }
  }

  /// FR-2.2 日期校验：晚于目标截止日时阻断保存。
  ///
  /// `yyyy-MM-dd` 文本同格式下字典序即日期序，直接与截止日文本比较。
  String? _validateDate(DateTime date) {
    final dateText = DateFormat('yyyy-MM-dd').format(date);
    if (dateText.compareTo(widget.deadlineDate) > 0) {
      return '里程碑日期晚于目标截止日（${widget.deadlineDate}），请调整';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    // 表单校验已保证日期必填且不晚于截止日（FormField validator），兜底防御。
    final date = _date;
    if (date == null) return;

    setState(() => _saving = true);
    try {
      final repo = ref.read(milestoneRepositoryProvider);
      final dateText = DateFormat('yyyy-MM-dd').format(date);
      final ok = await runDbAction(
        context,
        action: () async {
          if (_isEdit) {
            await repo.update(
              id: widget.milestone!.id,
              title: title,
              date: dateText,
            );
          } else {
            await repo.create(
              goalId: widget.goalId,
              title: title,
              date: dateText,
            );
          }
        },
      );
      if (!ok) return;
      ref.invalidate(milestoneListProvider(widget.goalId));
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑里程碑' : '添加里程碑'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '里程碑名称 *',
                  hintText: '例如：完成一轮复习',
                ),
                maxLength: 200,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入里程碑名称';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              // 日期为必填项；FormField 承载必填校验与 FR-2.2 截止日校验，
              // 不选日期直接提交时展示错误而非空值解包崩溃。
              FormField<DateTime>(
                key: _dateFieldKey,
                validator: (value) {
                  final date = _date;
                  if (date == null) return '请选择里程碑日期';
                  return _validateDate(date);
                },
                builder: (field) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: _pickDate,
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: '里程碑日期 *',
                          border: const OutlineInputBorder(),
                          errorText: field.errorText,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.event_outlined),
                            const SizedBox(width: 8),
                            Text(
                              _date == null
                                  ? '请选择日期'
                                  : DateFormat('yyyy-MM-dd').format(_date!),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_date != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _validateDate(_date!) == null
                            ? '目标截止日：${widget.deadlineDate}'
                            : '目标截止日：${widget.deadlineDate}（里程碑不应晚于它）',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _validateDate(_date!) == null
                                  ? Theme.of(context).colorScheme.outline
                                  : Theme.of(context).colorScheme.error,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '里程碑日期原则上不得晚于目标截止日（${widget.deadlineDate}）。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
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
          child: Text(_isEdit ? '保存' : '添加'),
        ),
      ],
    );
  }
}
