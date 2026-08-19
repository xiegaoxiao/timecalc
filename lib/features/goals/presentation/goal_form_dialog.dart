import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../data/goal_repository_provider.dart';

/// 创建/编辑目标对话框（FR-1.1：名称与截止日期为必填项）。
///
/// [goal] 为空表示创建，非空表示编辑。
/// 创建成功后通过返回值携带新目标 id（创建模式返回 `int`，编辑返回 null）。
class GoalFormDialog extends ConsumerStatefulWidget {
  const GoalFormDialog({super.key, this.goal});

  final Goal? goal;

  /// 返回创建出的目标 id；取消或编辑保存返回 null。
  static Future<int?> show(BuildContext context, {Goal? goal}) {
    return AppDialog.show<int>(
      context,
      title: goal == null ? '创建目标' : '编辑目标',
      titleIcon: Icons.flag_outlined,
      content: GoalFormDialog(goal: goal),
      barrierDismissible: false,
    );
  }

  @override
  ConsumerState<GoalFormDialog> createState() => _GoalFormDialogState();
}

class _GoalFormDialogState extends ConsumerState<GoalFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _deadlineFieldKey = GlobalKey<FormFieldState<DateTime>>();
  late final TextEditingController _titleController;
  final _descriptionController = TextEditingController();
  final _subjectController = TextEditingController();
  DateTime? _deadline;
  bool _saving = false;
  final List<String> _subjectNames = [];

  bool get _isEdit => widget.goal != null;

  @override
  void initState() {
    super.initState();
    final goal = widget.goal;
    _titleController = TextEditingController(text: goal?.title ?? '');
    _descriptionController.text = goal?.description ?? '';
    _deadline = goal == null ? null : parseLocalDate(goal.deadlineDate);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _subjectController.dispose();
    super.dispose();
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final field = _deadlineFieldKey.currentState;
    final picked = await showDatePicker(
      context: context,
      initialDate: field?.value ?? _deadline ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
      helpText: '选择截止日期',
    );
    if (picked != null) {
      setState(() => _deadline = picked);
      // 同步 FormField 内部值，让日期选择后的校验错误即时消除。
      field?.didChange(picked);
    }
  }

  void _addSubject() {
    final name = _subjectController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      if (!_subjectNames.contains(name)) {
        _subjectNames.add(name);
      }
      _subjectController.clear();
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    // 表单校验已保证截止日期必填（FormField validator），此处兜底防御。
    final deadline = _deadline;
    if (deadline == null) return;

    setState(() => _saving = true);
    try {
      final repo = ref.read(goalRepositoryProvider);
      final dateText = DateFormat('yyyy-MM-dd').format(deadline);
      int? createdId;
      final ok = await runDbAction(
        context,
        action: () async {
          if (_isEdit) {
            await repo.update(
              id: widget.goal!.id,
              title: title,
              deadlineDate: dateText,
              description: Value(_descriptionController.text.trim()),
            );
          } else {
            final goal = await repo.createWithSubjects(
              title: title,
              deadlineDate: dateText,
              description: _descriptionController.text.trim().isEmpty
                  ? null
                  : _descriptionController.text.trim(),
              subjectNames: _subjectNames,
            );
            createdId = goal.id;
          }
        },
      );
      if (!ok) return;
      ref.invalidate(goalListProvider);
      // 详情页独立缓存，编辑保存后必须同时刷新，标题/截止日期才能即时更新。
      if (_isEdit) {
        ref.invalidate(goalDetailProvider(widget.goal!.id));
      }
      if (mounted) Navigator.of(context).pop(createdId);
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
          // 目标名称
          AppFormField(
            controller: _titleController,
            label: '目标名称 *',
            hint: '例如：考研',
            autofocus: true,
            maxLength: 200,
            textInputAction: TextInputAction.next,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '请输入目标名称';
              }
              return null;
            },
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 截止日期
          FormField<DateTime>(
            key: _deadlineFieldKey,
            validator: (value) =>
                _deadline == null ? '请选择截止日期' : null,
            builder: (field) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppDateField(
                  label: '截止日期 *',
                  value: _deadline == null
                      ? null
                      : DateFormat('yyyy-MM-dd').format(_deadline!),
                  onTap: _pickDeadline,
                  errorText: field.errorText,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 描述
          AppFormField(
            controller: _descriptionController,
            label: '描述（可选）',
            hint: '目标背景、范围说明',
            maxLines: 2,
          ),

          if (!_isEdit) ...[
            const SizedBox(height: AppTokens.spaceLg),
            // 创建时批量添加科目
            Row(
              children: [
                Icon(
                  Icons.book_outlined,
                  size: 16,
                  color: AppTokens.neutralTextSecondaryLight,
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Text(
                  '科目（可选，可添加多个）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTokens.neutralTextSecondaryLight,
                      ),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Row(
              children: [
                Expanded(
                  child: AppFormField(
                    controller: _subjectController,
                    hint: '例如：政治',
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _addSubject(),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                IconButton.filled(
                  tooltip: '添加科目',
                  onPressed: _addSubject,
                  icon: const Icon(Icons.add, size: 20),
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                    ),
                  ),
                ),
              ],
            ),
            if (_subjectNames.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceMd),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceSm,
                children: [
                  for (final name in _subjectNames)
                    Chip(
                      label: Text(
                        name,
                        style: const TextStyle(fontSize: 13),
                      ),
                      backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                      side: BorderSide.none,
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () =>
                          setState(() => _subjectNames.remove(name)),
                      deleteButtonTooltipMessage: '移除科目「$name」',
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTokens.radiusSm),
                      ),
                    ),
                ],
              ),
            ],
          ],
          const SizedBox(height: AppTokens.spaceSm),

          // 底部按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_isEdit ? '保存' : '创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
