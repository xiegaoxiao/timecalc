import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
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
    return AppDialog.show<bool>(
      context,
      title: milestone == null ? '添加里程碑' : '编辑里程碑',
      titleIcon: Icons.flag_outlined,
      maxWidth: 440,
      content: MilestoneFormDialog(
        goalId: goalId,
        deadlineDate: deadlineDate,
        milestone: milestone,
      ),
      barrierDismissible: false,
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
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 里程碑名称
          AppFormField(
            controller: _titleController,
            label: '里程碑名称 *',
            hint: '例如：完成一轮复习',
            autofocus: true,
            maxLength: 200,
            textInputAction: TextInputAction.next,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '请输入里程碑名称';
              }
              return null;
            },
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 日期
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
                AppDateField(
                  label: '里程碑日期 *',
                  value: _date == null
                      ? null
                      : DateFormat('yyyy-MM-dd').format(_date!),
                  onTap: _pickDate,
                  errorText: field.errorText,
                ),
                if (_date != null) ...[
                  const SizedBox(height: AppTokens.spaceSm),
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
          const SizedBox(height: AppTokens.spaceSm),

          // 提示文本
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            child: Text(
              '里程碑日期原则上不得晚于目标截止日（${widget.deadlineDate}）。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceSm),

          // 底部按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed:
                    _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_isEdit ? '保存' : '添加'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
