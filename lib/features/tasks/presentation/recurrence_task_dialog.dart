import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/recurrence_service.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../data/recurrence_repository.dart';
import '../data/recurrence_repository_provider.dart';
import '../data/task_repository_provider.dart';
import '../domain/recurrence/recurrence_handler.dart';
import '../domain/recurrence/recurrence_rule.dart';
import '../domain/recurrence/recurrence_registry.dart';
import '../domain/recurrence/rule_param.dart';

/// 创建/编辑重复任务对话框（FR-4）。
///
/// - 规则类型遍历 RecurrenceRuleRegistry（可扩展，新增类型自动出现）；
/// - 参数区按 handler 的 RuleParam schema 动态渲染（int 步进 / 星期勾选 /
///   间隔序列可编辑），不写死字段；
/// - 实时预览未来发生日；
/// - 创建：单事务建模板 + 生成初始实例；编辑：[editTemplate] 非空时预填，
///   保存时弹出 FR-4.4「仅修改模板 / 仅修改未来实例」二选一。
class RecurrenceTaskDialog extends ConsumerStatefulWidget {
  const RecurrenceTaskDialog({
    super.key,
    required this.goalId,
    this.subjects = const [],
    this.editTemplate,
  });

  final int goalId;
  final List<Subject> subjects;

  /// 编辑模式：非空时预填该模板并走 FR-4.4 应用范围确认。
  final RecurrenceTemplate? editTemplate;

  static Future<void> show(
    BuildContext context, {
    required int goalId,
    List<Subject> subjects = const [],
    RecurrenceTemplate? editTemplate,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => RecurrenceTaskDialog(
        goalId: goalId,
        subjects: subjects,
        editTemplate: editTemplate,
      ),
    );
  }

  @override
  ConsumerState<RecurrenceTaskDialog> createState() =>
      _RecurrenceTaskDialogState();
}

class _RecurrenceTaskDialogState extends ConsumerState<RecurrenceTaskDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  final _offsetsController = TextEditingController();

  late RecurrenceRuleRegistry _registry;
  late String _ruleType;
  late Map<String, dynamic> _ruleJson;
  DateTime _startDate = DateTime.now();
  DateTime? _endDate;
  int? _subjectId;
  int? _estimatedMinutes;
  bool _saving = false;

  bool get _isEdit => widget.editTemplate != null;

  @override
  void initState() {
    super.initState();
    final template = widget.editTemplate;
    final today = ref.read(clockProvider)();

    _registry = RecurrenceRuleRegistry();
    _titleController = TextEditingController(text: template?.title ?? '');
    _subjectId = template?.subjectId;
    _estimatedMinutes = template?.estimatedMinutes;
    _startDate = template == null ? today : _parseDate(template.startDate);
    final endDate = template?.endDate;
    _endDate = endDate == null ? null : _parseDate(endDate);

    if (template != null) {
      // 兜底：模板 ruleType 未注册时回退到首个已注册类型，
      // 避免 SegmentedButton.selected 含不存在的 segment 触发断言崩溃。
      final handler = _registry.handlerFor(template.ruleType);
      if (handler != null) {
        _ruleType = template.ruleType;
        final rule = RecurrenceRule(
          ruleType: template.ruleType,
          ruleJson: template.ruleJson,
        );
        _ruleJson = Map<String, dynamic>.from(rule.jsonMap);
      } else {
        _ruleType = _registry.all.first.type;
        _ruleJson = Map<String, dynamic>.from(_registry.all.first.defaultJson());
      }
    } else {
      _ruleType = _registry.all.first.type;
      _ruleJson = Map<String, dynamic>.from(_registry.all.first.defaultJson());
    }
    _syncOffsetsController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _offsetsController.dispose();
    super.dispose();
  }

  void _syncOffsetsController() {
    final offsets = _ruleJson['offsets'];
    if (offsets is List) {
      _offsetsController.text = offsets.join(',');
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  /// 当前选中规则的 handler。
  RecurrenceRuleHandler? get _handler => _registry.handlerFor(_ruleType);

  /// 校验当前规则参数；合法返回 null，否则返回中文错误。
  String? get _ruleError {
    final handler = _handler;
    if (handler == null) return '未知的规则类型';
    return handler.validate(_ruleJson);
  }

  void _onRuleTypeChanged(String type) {
    final handler = _registry.handlerFor(type);
    if (handler == null) return;
    setState(() {
      _ruleType = type;
      _ruleJson = Map<String, dynamic>.from(handler.defaultJson());
      _syncOffsetsController();
    });
  }

  Future<void> _pickDate({required bool isEnd}) async {
    final now = DateTime.now();
    final current = isEnd ? (_endDate ?? _startDate) : _startDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
      helpText: isEnd ? '选择结束日期' : '选择起始日期',
    );
    if (picked == null) return;
    setState(() {
      if (isEnd) {
        _endDate = picked;
      } else {
        _startDate = picked;
      }
    });
  }

  /// 未来发生日预览（前 12 次，至多到起始日 + 30 天）。
  List<String> _previewDates() {
    final service = RecurrenceService();
    final start = DateFormat('yyyy-MM-dd').format(_startDate);
    return service
        .occurrences(
          ruleType: _ruleType,
          json: _ruleJson,
          startDate: start,
          to: _plusDays(start, 30),
        )
        .take(12)
        .toList();
  }

  static String _plusDays(String yyyyMMdd, int days) {
    final d = _parseDate(yyyyMMdd).add(Duration(days: days));
    return DateFormat('yyyy-MM-dd').format(d);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // 间隔序列输入从文本框回写。
    if (_offsetsController.text.isNotEmpty) {
      _ruleJson['offsets'] = _offsetsController.text
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();
    }
    final ruleError = _ruleError;
    if (ruleError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重复规则不合法：$ruleError')),
      );
      return;
    }

    final rule = RecurrenceRule.fromMap(ruleType: _ruleType, json: _ruleJson);
    final startDate = DateFormat('yyyy-MM-dd').format(_startDate);
    final endDate = _endDate == null
        ? null
        : DateFormat('yyyy-MM-dd').format(_endDate!);

    // 编辑模式：FR-4.4 二选一确认。
    RecurrenceApplyTo? applyTo;
    if (_isEdit) {
      final chosen = await showDialog<RecurrenceApplyTo>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('如何应用修改？'),
          content: const Text('修改重复规则时：'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(RecurrenceApplyTo.template),
              child: const Text('仅修改模板'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(RecurrenceApplyTo.future),
              child: const Text('仅修改未来实例'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (chosen == null || !mounted) return;
      applyTo = chosen;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(recurrenceRepositoryProvider);
      final today = ref.read(clockProvider)();
      if (_isEdit) {
        await repo.updateRule(
          templateId: widget.editTemplate!.id,
          rule: rule,
          endDate: endDate,
          applyTo: applyTo!,
          today: today,
          // 编辑模式的标题/科目/时长/起始日期在对话框中可编辑（FR-4）。
          title: _titleController.text.trim(),
          subjectId: Value(_subjectId),
          estimatedMinutes: Value(_estimatedMinutes),
          startDate: startDate,
        );
      } else {
        await repo.create(
          goalId: widget.goalId,
          subjectId: _subjectId,
          title: _titleController.text.trim(),
          estimatedMinutes: _estimatedMinutes,
          rule: rule,
          startDate: startDate,
          endDate: endDate,
          today: today,
        );
      }
      _refresh();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 变更后刷新：模板、目标任务列表、今日/日历/未完成缓存。
  void _refresh() {
    ref.invalidate(recurrenceTemplatesProvider(widget.goalId));
    ref.invalidate(taskListProvider(widget.goalId));
    ref.invalidate(tasksByDateProvider);
    ref.invalidate(tasksByMonthProvider);
    ref.invalidate(unfinishedBeforeProvider);
  }

  @override
  Widget build(BuildContext context) {
    final handler = _handler;
    return AlertDialog(
      title: Text(_isEdit ? '编辑重复任务' : '重复任务'),
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '任务标题 *',
                  hintText: '例如：背单词 / 真题',
                ),
                maxLength: 200,
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? '请输入任务标题' : null,
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
                    const DropdownMenuItem<int?>(value: null, child: Text('未分类')),
                    for (final s in widget.subjects)
                      DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (value) => setState(() => _subjectId = value),
                ),
              if (widget.subjects.isNotEmpty) const SizedBox(height: 12),
              DurationStepInput(
                label: '预估时长',
                value: _estimatedMinutes,
                allowEmpty: true,
                onChanged: (m) => setState(() => _estimatedMinutes = m),
              ),
              const SizedBox(height: 16),
              Text('重复规则', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              // 规则类型：遍历注册表，动态可扩展。
              SegmentedButton<String>(
                segments: [
                  for (final h in _registry.all)
                    ButtonSegment(value: h.type, label: Text(h.label)),
                ],
                selected: {_ruleType},
                onSelectionChanged: (selection) =>
                    _onRuleTypeChanged(selection.first),
              ),
              const SizedBox(height: 12),
              if (handler != null) _buildParams(handler),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _DateField(
                      label: '起始日期',
                      date: _startDate,
                      onTap: () => _pickDate(isEnd: false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DateField(
                      label: _endDate == null ? '结束日期（无限）' : '结束日期',
                      date: _endDate ?? _startDate,
                      onTap: () => _pickDate(isEnd: true),
                      highlight: _endDate != null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('未来发生日预览', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              if (_ruleError != null)
                Text(
                  _ruleError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else
                Text(
                  _previewDates().join('、'),
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
          child: Text(_isEdit ? '保存' : '创建'),
        ),
      ],
    );
  }

  /// 按 handler 的 RuleParam schema 动态渲染参数表单。
  Widget _buildParams(RecurrenceRuleHandler handler) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final param in handler.params) ...[
          if (param.type == RuleParamType.intValue)
            _IntStepField(
              label: param.label,
              value: (_ruleJson[param.key] as int?) ?? (param.defaultValue ?? 1),
              min: param.min ?? 1,
              max: param.max ?? 100,
              onChanged: (v) => setState(() => _ruleJson[param.key] = v),
            ),
          if (param.type == RuleParamType.intList && param.key == 'weekdays')
            _WeekdaysPicker(
              selected: ((_ruleJson['weekdays'] as List?) ?? []).cast<int>(),
              onChanged: (days) => setState(() => _ruleJson['weekdays'] = days),
            ),
          if (param.type == RuleParamType.intList && param.key == 'offsets')
            TextFormField(
              controller: _offsetsController,
              decoration: InputDecoration(
                labelText: param.label,
                hintText: param.hint,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return '请输入至少一个间隔天数';
                final parts = text
                    .split(',')
                    .map((s) => int.tryParse(s.trim()))
                    .whereType<int>()
                    .toList();
                if (parts.length != text.split(',').length) {
                  return '请输入用逗号分隔的整数';
                }
                if (parts.isEmpty) return '请输入至少一个间隔天数';
                return null;
              },
            ),
          if (param.type == RuleParamType.intList &&
              param.key != 'weekdays' &&
              param.key != 'offsets')
            // 其他 intList 参数暂不渲染（新增规则类型时按需扩展）。
            const SizedBox.shrink(),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// 单个整数步进输入（规则参数用）。
class _IntStepField extends StatelessWidget {
  const _IntStepField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: '$label减',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        Text('$value', style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          tooltip: '$label加',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

/// 每周可用日勾选（weekly 规则参数）。
class _WeekdaysPicker extends StatelessWidget {
  const _WeekdaysPicker({required this.selected, required this.onChanged});

  final List<int> selected;
  final ValueChanged<List<int>> onChanged;

  static const _labels = {1: '一', 2: '二', 3: '三', 4: '四', 5: '五', 6: '六', 7: '日'};

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final day in const [1, 2, 3, 4, 5, 6, 7])
          FilterChip(
            label: Text('周${_labels[day]}'),
            selected: selected.contains(day),
            onSelected: (on) {
              final next = [...selected];
              if (on) {
                if (!next.contains(day)) next.add(day);
              } else {
                next.remove(day);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}

/// 日期选择输入（起始/结束日期）。
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.date,
    required this.onTap,
    this.highlight = false,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.event_outlined),
        ),
        child: Text(
          DateFormat('yyyy-MM-dd').format(date),
          style: highlight ? TextStyle(color: scheme.primary) : null,
        ),
      ),
    );
  }
}
