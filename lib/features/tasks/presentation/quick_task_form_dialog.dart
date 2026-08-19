import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../data/task_repository_provider.dart';

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
  });

  final DateTime date;
  final List<Goal> goals;

  static Future<void> show(
    BuildContext context, {
    required DateTime date,
    required List<Goal> goals,
  }) {
    return AppDialog.show<void>(
      context,
      title: '快速添加任务',
      titleIcon: Icons.bolt_outlined,
      maxWidth: 440,
      content: QuickTaskFormDialog(
        date: date,
        goals: goals,
      ),
      barrierDismissible: false,
    );
  }

  @override
  ConsumerState<QuickTaskFormDialog> createState() =>
      _QuickTaskFormDialogState();
}

class _QuickTaskFormDialogState extends ConsumerState<QuickTaskFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  final _noteController = TextEditingController();
  late int? _goalId;
  int? _estimatedMinutes;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    // 默认选中第一个目标（历史 defaultGoalId 校验分支已删，无调用方）。
    _goalId = widget.goals.isEmpty ? null : widget.goals.firstOrNull?.id;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final goalId = _goalId;
    if (goalId == null) return;
    // 0 分钟视为未设置（预估时长合法范围为 1～1440，FR-3 验收）。
    final minutes = _estimatedMinutes == 0 ? null : _estimatedMinutes;

    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      final ok = await runDbAction(
        context,
        action: () => repo.create(
          goalId: goalId,
          title: _titleController.text.trim(),
          note: _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
          plannedDate: DateFormat('yyyy-MM-dd').format(widget.date),
          estimatedMinutes: minutes,
        ),
      );
      if (!ok) return;
      if (mounted) Navigator.of(context).pop();
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
          // 目标选择
          DropdownButtonFormField<int?>(
            initialValue: _goalId,
            decoration: AppFormField.defaultDecoration(
              label: '目标 *',
              prefixIcon: Icon(
                Icons.flag_outlined,
                size: 20,
                color: _goalId != null
                    ? Theme.of(context).colorScheme.primary
                    : AppTokens.neutralTextSecondaryLight,
              ),
              scheme: Theme.of(context).colorScheme,
            ),
            items: [
              for (final g in widget.goals)
                DropdownMenuItem<int?>(value: g.id, child: Text(g.title)),
            ],
            onChanged: (value) => setState(() => _goalId = value),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 任务标题
          AppFormField(
            controller: _titleController,
            label: '任务标题 *',
            hint: '例如：完成第一章复习',
            autofocus: true,
            maxLength: 200,
            textInputAction: TextInputAction.next,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '请输入任务标题';
              }
              return null;
            },
          ),
          const SizedBox(height: AppTokens.spaceLg),

          // 预估时长
          DurationStepInput(
            label: '预估时长',
            value: _estimatedMinutes,
            allowEmpty: true,
            onChanged: (minutes) =>
                setState(() => _estimatedMinutes = minutes),
            hourFieldKey: const Key('quickHourField'),
            minuteFieldKey: const Key('quickMinuteField'),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 备注
          AppFormField(
            controller: _noteController,
            label: '备注（可选）',
            maxLines: 2,
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
                child: const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
