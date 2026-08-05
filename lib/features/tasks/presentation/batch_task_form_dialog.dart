import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../data/last_minutes_provider.dart';
import '../data/task_repository_provider.dart';

/// 批量添加任务对话框：多行输入，一次创建多个任务（单事务）。
///
/// 日期策略：
/// - 全部同一天：适用于批量章节任务；
/// - 每 N 天一个：适用于套卷递推（真题每天一套、模拟卷每周一套）。
/// 统一预估时长并记忆上次输入（lastMinutesProvider）。
class BatchTaskFormDialog extends ConsumerStatefulWidget {
  const BatchTaskFormDialog({
    super.key,
    required this.goalId,
    this.subjects = const [],
    this.defaultSubjectId,
  });

  final int goalId;
  final List<Subject> subjects;
  final int? defaultSubjectId;

  static Future<void> show(
    BuildContext context, {
    required int goalId,
    List<Subject> subjects = const [],
    int? defaultSubjectId,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => BatchTaskFormDialog(
        goalId: goalId,
        subjects: subjects,
        defaultSubjectId: defaultSubjectId,
      ),
    );
  }

  @override
  ConsumerState<BatchTaskFormDialog> createState() => _BatchTaskFormDialogState();
}

class _BatchTaskFormDialogState extends ConsumerState<BatchTaskFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titlesController = TextEditingController();
  final _intervalController = TextEditingController(text: '1');
  DateTime _startDate = DateTime.now();
  bool _useInterval = false;
  int _intervalDays = 1;
  int? _subjectId;
  int? _estimatedMinutes;
  bool _saving = false;

  List<String> get _lines => _titlesController.text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  @override
  void initState() {
    super.initState();
    _subjectId = widget.defaultSubjectId;
    // 起始日期默认取注入时钟的今天，测试可固定时间。
    _startDate = ref.read(clockProvider)();
    _estimatedMinutes = ref.read(lastMinutesProvider);
  }

  @override
  void dispose() {
    _titlesController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(_startDate.year - 2),
      lastDate: DateTime(_startDate.year + 2),
      helpText: '选择起始日期',
    );
    if (picked != null) {
      setState(() => _startDate = picked);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final lines = _lines;
    // 0 分钟视为未设置（预估时长合法范围为 1～1440，FR-3 验收）。
    final minutes = _estimatedMinutes == 0 ? null : _estimatedMinutes;

    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      await repo.batchCreate(
        goalId: widget.goalId,
        subjectId: _subjectId,
        titles: lines,
        startDate: DateFormat('yyyy-MM-dd').format(_startDate),
        dateIntervalDays: _useInterval ? _intervalDays : 0,
        estimatedMinutes: minutes,
      );
      if (minutes != null) {
        ref.read(lastMinutesProvider.notifier).state = minutes;
      }
      // 跨页刷新（FR-3 验收）：批量新增影响今天页、日历、逾期横幅。
      ref.invalidate(taskListProvider(widget.goalId));
      ref.invalidate(tasksByDateProvider);
      ref.invalidate(tasksByMonthProvider);
      ref.invalidate(unfinishedBeforeProvider);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final totalMinutes = _estimatedMinutes == null
        ? 0
        : lines.length * _estimatedMinutes!;

    return AlertDialog(
      title: const Text('批量添加任务'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _titlesController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '任务标题（每行一个）*',
                  hintText: '例如：\n真题 2013\n真题 2014\n真题 2015',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                validator: (_) {
                  if (lines.isEmpty) return '请至少输入一个任务标题';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              if (widget.subjects.isNotEmpty)
                DropdownButtonFormField<int?>(
                  initialValue: _subjectId,
                  decoration: const InputDecoration(
                    labelText: '科目',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('未分类')),
                    for (final s in widget.subjects)
                      DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (value) => setState(() => _subjectId = value),
                ),
              const SizedBox(height: 12),
              Text('日期安排', style: Theme.of(context).textTheme.bodySmall),
              RadioGroup<bool>(
                groupValue: _useInterval,
                onChanged: (value) =>
                    setState(() => _useInterval = value ?? false),
                child: const Column(
                  children: [
                    RadioListTile<bool>(
                      value: false,
                      title: Text('全部同一天'),
                      dense: true,
                    ),
                    RadioListTile<bool>(
                      value: true,
                      title: Text('每 N 天一个（按顺序排列）'),
                      dense: true,
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _pickStartDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '起始日期',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(DateFormat('yyyy-MM-dd').format(_startDate)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_useInterval)
                    Expanded(
                      child: TextFormField(
                        controller: _intervalController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '间隔天数',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n >= 1) {
                            _intervalDays = n;
                          }
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              DurationStepInput(
                label: '预估时长',
                value: _estimatedMinutes,
                allowEmpty: true,
                onChanged: (minutes) =>
                    setState(() => _estimatedMinutes = minutes),
                hourFieldKey: const Key('batchHourField'),
                minuteFieldKey: const Key('batchMinuteField'),
              ),
              const SizedBox(height: 12),
              // 实时预览：生成数量与日期范围（不写库，用户确认后单事务创建）。
              Text(
                lines.isEmpty
                    ? '输入标题后将在此预览'
                    : '将创建 ${lines.length} 个任务'
                        '${_useInterval ? '，自 ${DateFormat('yyyy-MM-dd').format(_startDate)} 起每 $_intervalDays 天一个' : '，日期 ${DateFormat('yyyy-MM-dd').format(_startDate)}'}'
                        '${totalMinutes > 0 ? '，共 ${DurationFormat.minutes(totalMinutes)}' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
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
          child: Text(_saving ? '创建中…' : '创建'),
        ),
      ],
    );
  }
}
