import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../../goals/data/goal_repository_provider.dart';
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
    return AppDialog.show<void>(
      context,
      title: '批量添加任务',
      titleIcon: Icons.playlist_add_outlined,
      maxWidth: 520,
      content: BatchTaskFormDialog(
        goalId: goalId,
        subjects: subjects,
        defaultSubjectId: defaultSubjectId,
      ),
      barrierDismissible: false,
    );
  }

  @override
  ConsumerState<BatchTaskFormDialog> createState() =>
      _BatchTaskFormDialogState();
}

class _BatchTaskFormDialogState extends ConsumerState<BatchTaskFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titlesController = TextEditingController();
  final _intervalController = TextEditingController(text: '1');
  late DateTime _startDate;
  bool _useInterval = false;
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
    final (first, last) = _dateRange();
    final initial = _startDate.isBefore(first)
        ? first
        : (_startDate.isAfter(last) ? last : _startDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: '选择起始日期',
    );
    if (picked != null) {
      setState(() => _startDate = picked);
    }
  }

  /// 目标截止日（本地日期）；目标加载中/被删返回 null（调用方回退宽松区间）。
  DateTime? _goalDeadline() {
    final goal = ref.read(goalDetailProvider(widget.goalId)).valueOrNull;
    if (goal == null) return null;
    return parseLocalDate(goal.deadlineDate);
  }

  /// 日期选择区间：[今天, 目标截止日]（截止日缺失时回退宽松上界）。
  ///
  /// 截止日已过时区间退化为只能选今天（datepicker 不允许 first > last）。
  (DateTime, DateTime) _dateRange() {
    final today = DateUtils.dateOnly(ref.read(clockProvider)());
    final deadline = _goalDeadline();
    final last = deadline ?? DateTime(today.year + 10);
    final effectiveLast = last.isBefore(today) ? today : last;
    return (today, effectiveLast);
  }

  /// 起始日期越界提示（不静默失败）。
  void _showDateError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 保存守卫：起始日期与递推的最后一个任务日期都必须在 [今天, 目标截止日]。
  ///
  /// 选择器只约束起始日期，递推（每 N 天一个）可能把后续任务铺到截止日
  /// 之后——这里一并兜底校验，避免任务静默消失。
  bool _validateDateRange() {
    // 统一为纯日期比较（clockProvider 带时刻，addLocalDays 产出午夜，
    // 混用会误判「今天早于今天」）。
    final today = DateUtils.dateOnly(ref.read(clockProvider)());
    final deadline = _goalDeadline();
    final lines = _lines;
    final intervalDays =
        _useInterval ? (int.tryParse(_intervalController.text.trim()) ?? 1) : 0;
    // 最后一个任务的计划日期（纯日历加法，同 batchCreate 语义）。
    final lastTaskDate = addLocalDays(
      _startDate,
      intervalDays * (lines.length - 1),
    );
    if (_startDate.isBefore(today) || lastTaskDate.isBefore(today)) {
      _showDateError('任务日期不能早于今天');
      return false;
    }
    if (deadline != null &&
        (lastTaskDate.isAfter(deadline) || _startDate.isAfter(deadline))) {
      _showDateError(
        '任务日期不能晚于目标截止日（${DateFormat('yyyy-MM-dd').format(deadline)}）',
      );
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final lines = _lines;
    // 0 分钟视为未设置（预估时长合法范围为 1～1440，FR-3 验收）。
    final minutes = _estimatedMinutes == 0 ? null : _estimatedMinutes;

    // 日期范围守卫：起始/递推日期不得早于今天或晚于目标截止日
    // （否则任务从目标详情/日历静默消失且无提示）。
    if (!_validateDateRange()) return;

    // 间隔天数以输入框为准重新解析（validator 已保证合法）；状态 _intervalDays
    // 仅为未提交时的旧值，此处直接解析避免「所见≠所存」。
    final intervalDays = int.tryParse(_intervalController.text.trim()) ?? 1;

    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      final ok = await runDbAction(
        context,
        action: () => repo.batchCreate(
          goalId: widget.goalId,
          subjectId: _subjectId,
          titles: lines,
          startDate: DateFormat('yyyy-MM-dd').format(_startDate),
          dateIntervalDays: _useInterval ? intervalDays : 0,
          estimatedMinutes: minutes,
        ),
      );
      if (!ok) return;
      if (minutes != null) {
        ref.read(lastMinutesProvider.notifier).state = minutes;
      }
      // 跨页刷新（FR-3 验收）：批量新增影响今日页（列表与「目标剩余」）、
      // 进度页（剩余工作量/耗时图）、日历与逾期横幅，走全量集合。
      invalidateAppData(ref.invalidate);
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
    // 间隔天数取输入框实时解析值，保证「所见即所存」。
    final intervalDays =
        int.tryParse(_intervalController.text.trim()) ?? 1;

    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 任务标题（多行输入）
          AppFormField(
            controller: _titlesController,
            label: '任务标题（每行一个）*',
            hint: '例如：\n真题 2013\n真题 2014\n真题 2015',
            autofocus: true,
            maxLines: 6,
            maxLength: null,
            contentPadding: const EdgeInsets.all(AppTokens.spaceMd),
            validator: (_) {
              if (lines.isEmpty) return '请至少输入一个任务标题';
              return null;
            },
            // 输入变化时重建预览（下方「将创建 N 个任务」实时更新）。
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 科目选择
          if (widget.subjects.isNotEmpty) ...[
            DropdownButtonFormField<int?>(
              initialValue: _subjectId,
              decoration: AppFormField.defaultDecoration(
                label: '科目',
                prefixIcon: Icon(
                  Icons.book_outlined,
                  size: 20,
                  color: _subjectId != null
                      ? Theme.of(context).colorScheme.primary
                      : AppTokens.neutralTextSecondaryLight,
                ),
                scheme: Theme.of(context).colorScheme,
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('未分类'),
                ),
                for (final s in widget.subjects)
                  DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
              ],
              onChanged: (value) => setState(() => _subjectId = value),
            ),
            const SizedBox(height: AppTokens.spaceMd),
          ],

          // 日期安排标题
          Row(
            children: [
              Icon(
                Icons.calendar_today_outlined,
                size: 16,
                color: AppTokens.neutralTextSecondaryLight,
              ),
              const SizedBox(width: AppTokens.spaceSm),
              Text(
                '日期安排',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTokens.neutralTextSecondaryLight,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceSm),

          // 日期安排选项
          RadioGroup<bool>(
            groupValue: _useInterval,
            onChanged: (value) =>
                setState(() => _useInterval = value ?? false),
            child: Row(
              children: [
                Expanded(
                  child: RadioListTile<bool>(
                    value: false,
                    title: const Text('全部同一天', style: TextStyle(fontSize: 13)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                Expanded(
                  child: RadioListTile<bool>(
                    value: true,
                    title: const Text('每 N 天一个', style: TextStyle(fontSize: 13)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.spaceSm),

          // 日期选择行
          Row(
            children: [
              Expanded(
                flex: _useInterval ? 1 : 2,
                child: AppDateField(
                  label: '起始日期',
                  value: DateFormat('yyyy-MM-dd').format(_startDate),
                  onTap: _pickStartDate,
                ),
              ),
              if (_useInterval) ...[
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: AppFormField(
                    controller: _intervalController,
                    label: '间隔天数',
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final text = (value ?? '').trim();
                      if (text.isEmpty) return '请输入间隔天数';
                      final n = int.tryParse(text);
                      if (n == null || n < 1) {
                        return '间隔天数必须是 ≥1 的整数';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 预估时长
          DurationStepInput(
            label: '预估时长',
            value: _estimatedMinutes,
            allowEmpty: true,
            onChanged: (minutes) =>
                setState(() => _estimatedMinutes = minutes),
            hourFieldKey: const Key('batchHourField'),
            minuteFieldKey: const Key('batchMinuteField'),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 实时预览
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            child: Text(
              lines.isEmpty
                  ? '输入标题后将在此预览'
                  : '将创建 ${lines.length} 个任务'
                      '${_useInterval ? '，自 ${DateFormat('yyyy-MM-dd').format(_startDate)} 起每 $intervalDays 天一个' : '，日期 ${DateFormat('yyyy-MM-dd').format(_startDate)}'}'
                      '${totalMinutes > 0 ? '，共 ${DurationFormat.minutes(totalMinutes)}' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
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
                child: Text(_saving ? '创建中…' : '创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
