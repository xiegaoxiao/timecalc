import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/utils/date_text.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../../goals/data/goal_repository_provider.dart';
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
  late DateTime _initialPlannedDate;
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
    // 记录进入对话框时的计划日期：保存守卫只在「用户改动日期」时校验，
    // 避免编辑历史任务（计划日期早于今天）改其他字段被卡住。
    _initialPlannedDate = task == null
        ? ref.read(clockProvider)()
        : parseLocalDate(task.plannedDate);
    _plannedDate = _initialPlannedDate;
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

  /// 目标截止日（本地日期）；目标加载中/被删返回 null（调用方回退宽松区间）。
  DateTime? _goalDeadline() {
    final goal = ref.read(goalDetailProvider(widget.goalId)).valueOrNull;
    if (goal == null) return null;
    return parseLocalDate(goal.deadlineDate);
  }

  /// 日期选择区间：[今天, 目标截止日]（截止日缺失时回退宽松上界）。
  ///
  /// 目标截止日已过（逾期目标仍可添加任务）时 `first > last` 会触发
  /// datepicker 断言——区间退化为只能选今天。
  (DateTime, DateTime) _dateRange() {
    final today = DateUtils.dateOnly(ref.read(clockProvider)());
    final deadline = _goalDeadline();
    final last = deadline ?? DateTime(today.year + 10);
    final effectiveLast = last.isBefore(today) ? today : last;
    return (today, effectiveLast);
  }

  Future<void> _pickDate() async {
    final (first, last) = _dateRange();
    final planned = _plannedDate ?? first;
    // initialDate 钳制到区间内（编辑历史任务时计划日期可能早于 today，
    // 越界会触发 datepicker 断言，release 下落到错误初值）。
    final initial = planned.isBefore(first)
        ? first
        : (planned.isAfter(last) ? last : planned);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: '选择计划日期',
    );
    if (picked != null) {
      setState(() => _plannedDate = picked);
    }
  }

  /// 日期越界提示（不静默失败）：SnackBar 明确告知原因。
  void _showDateError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 保存守卫：计划日期必须在 [今天, 目标截止日]。
  ///
  /// 选择器已把区间外日期置灰，这里兜底防「粘贴/默认值」等路径越界；
  /// 编辑模式仅当用户改动日期时才校验（未改动直接保存其他字段放行）。
  bool _validateDateRange() {
    // 统一为纯日期比较（clockProvider 带时刻，datepicker 产出午夜，
    // 混用会误判「今天早于今天」）。
    final today = DateUtils.dateOnly(ref.read(clockProvider)());
    final planned = _plannedDate!;
    final dateChanged = planned.isBefore(_initialPlannedDate) ||
        planned.isAfter(_initialPlannedDate);
    if (!dateChanged) return true;
    if (planned.isBefore(today)) {
      _showDateError('任务日期不能早于今天');
      return false;
    }
    final deadline = _goalDeadline();
    if (deadline != null && planned.isAfter(deadline)) {
      _showDateError(
        '任务日期不能晚于目标截止日（${DateFormat('yyyy-MM-dd').format(deadline)}）',
      );
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    // 0 分钟视为未设置（预估时长合法范围为 1～1440，FR-3 验收）。
    final minutes = _estimatedMinutes == 0 ? null : _estimatedMinutes;

    // 日期范围守卫：选择器已把越界日期置灰，这里兜底防数据层越界
    // （否则任务计划在截止日后，保存后从目标详情/日历消失且无提示）。
    if (!_validateDateRange()) return;

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
      // 跨页刷新（FR-3 验收）：创建/编辑影响今日页（列表与「目标剩余」）、
      // 进度页（剩余工作量/燃尽/耗时图）、日历与逾期横幅，走全量集合。
      invalidateAppData(ref);
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_isEdit ? '编辑任务' : '创建任务'),
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
                maxLength: 200,
                // 关闭内置右下角计数器（会与长输入文字/光标重叠），
                // 计数改在输入框外部下方单独右对齐展示。
                decoration: const InputDecoration(
                  labelText: '任务标题 *',
                  hintText: '例如：完成第一章复习',
                  counterText: '',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入任务标题';
                  }
                  return null;
                },
              ),
              // 字数计数：输入框外部下方右对齐，不与输入内容重叠。
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _titleController,
                builder: (context, value, _) => Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${value.text.length}/200',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ),
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
                // 完整弹窗提供快捷按钮：+15/30 分、+1 小时，免去点 150 次。
                showQuickButtons: true,
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
