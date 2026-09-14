import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../data/course_repository_provider.dart';
import '../domain/class_period.dart';
import '../domain/course_palette.dart';
import '../domain/course_week.dart';
import 'course_color.dart';

/// 课程表单（FR-10）：新建 / 编辑一门课。
///
/// 「第几周 + 星期几 + 第几节」是课表的四个正交维度，表单按此顺序排布
/// （星期 → 节次 → 教学周 → 单双周），并在底部实时回显换算结果
/// （如「每周三 第 5-7 节 · 14:00-16:20 · 2-17 周」），让用户在下笔时就能
/// 核对语义，而不是等到网格里发现放错格子。
class CourseFormDialog extends ConsumerStatefulWidget {
  const CourseFormDialog({super.key, this.initial});

  /// 编辑时传入既有课程；null 表示新建。
  final Course? initial;

  /// 保存成功返回 true（调用方据此刷新列表）。
  static Future<bool?> show(BuildContext context, {Course? initial}) {
    return AppDialog.show<bool>(
      context,
      title: initial == null ? '添加课程' : '编辑课程',
      titleIcon: initial == null
          ? Icons.add_circle_outline
          : Icons.edit_outlined,
      maxWidth: 460,
      content: CourseFormDialog(initial: initial),
      barrierDismissible: false,
    );
  }

  @override
  ConsumerState<CourseFormDialog> createState() => _CourseFormDialogState();
}

class _CourseFormDialogState extends ConsumerState<CourseFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _teacherController;
  late final TextEditingController _locationController;
  late final TextEditingController _categoryController;
  late final TextEditingController _noteController;

  late int _weekday;
  late int _startPeriod;
  late int _endPeriod;
  late int _startWeek;
  late int _endWeek;
  late String _weekParity;
  late String _color;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _titleController = TextEditingController(text: initial?.title ?? '');
    _teacherController = TextEditingController(text: initial?.teacher ?? '');
    _locationController = TextEditingController(text: initial?.location ?? '');
    _categoryController = TextEditingController(text: initial?.category ?? '');
    _noteController = TextEditingController(text: initial?.note ?? '');
    // 新建默认落在周一第 1-2 节、全学期每周：最常见的录入起点，改两下即可。
    _weekday = initial?.weekday ?? 1;
    _startPeriod = initial?.startPeriod ?? 1;
    _endPeriod = initial?.endPeriod ?? 2;
    _startWeek = initial?.startWeek ?? 1;
    _endWeek = initial?.endWeek ?? 18;
    _weekParity = initial?.weekParity ?? WeekParity.all;
    _color = initial?.color ?? CoursePalette.at(0);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _teacherController.dispose();
    _locationController.dispose();
    _categoryController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  /// 起止节次下拉的候选项：1 ~ 总节数。
  static List<int> get _periodOptions =>
      [for (var i = 1; i <= ClassPeriods.count; i++) i];

  /// 教学周下拉：1 ~ 30 周（与解析层上限一致）。
  static List<int> get _weekOptions => [for (var i = 1; i <= 30; i++) i];

  /// 起止周/节次联动：起点超过终点时把终点顶到起点（避免出现非法区间）。
  void _syncPeriods({bool startChanged = true}) {
    if (_startPeriod > _endPeriod) {
      if (startChanged) {
        _endPeriod = _startPeriod;
      } else {
        _startPeriod = _endPeriod;
      }
    }
  }

  void _syncWeeks({bool startChanged = true}) {
    if (_startWeek > _endWeek) {
      if (startChanged) {
        _endWeek = _startWeek;
      } else {
        _startWeek = _endWeek;
      }
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = ref.read(courseRepositoryProvider);
    final teacher = _teacherController.text.trim();
    final location = _locationController.text.trim();
    final category = _categoryController.text.trim();
    final note = _noteController.text.trim();
    final title = _titleController.text.trim();
    try {
      final initial = widget.initial;
      final ok = await runDbAction(
        context,
        action: () async {
          if (initial == null) {
            await repo.create(
              title: title,
              teacher: teacher.isEmpty ? null : teacher,
              location: location.isEmpty ? null : location,
              category: category.isEmpty ? null : category,
              note: note.isEmpty ? null : note,
              weekday: _weekday,
              startPeriod: _startPeriod,
              endPeriod: _endPeriod,
              startWeek: _startWeek,
              endWeek: _endWeek,
              weekParity: _weekParity,
              color: _color,
            );
            return;
          }
          await repo.update(
            initial.id,
            title: title,
            teacher: teacher.isEmpty ? null : teacher,
            location: location.isEmpty ? null : location,
            category: category.isEmpty ? null : category,
            note: note.isEmpty ? null : note,
            weekday: _weekday,
            startPeriod: _startPeriod,
            endPeriod: _endPeriod,
            startWeek: _startWeek,
            endWeek: _endWeek,
            weekParity: _weekParity,
            color: _color,
          );
        },
      );
      if (!ok) return;
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppFormField(
            controller: _titleController,
            label: '课程名 *',
            hint: '例如：算法设计与分析',
            autofocus: widget.initial == null,
            maxLength: 200,
            textInputAction: TextInputAction.next,
            validator: (value) =>
                (value == null || value.trim().isEmpty) ? '请输入课程名' : null,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Row(
            children: [
              Expanded(
                child: AppFormField(
                  controller: _teacherController,
                  label: '教师（可选）',
                  maxLength: 100,
                ),
              ),
              const SizedBox(width: AppTokens.spaceMd),
              Expanded(
                child: AppFormField(
                  controller: _locationController,
                  label: '地点（可选）',
                  maxLength: 100,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 星期：7 个选项全部铺开（比下拉更快，且一眼看到全周分布）。
          _FieldLabel(text: '星期', scheme: scheme),
          const SizedBox(height: AppTokens.spaceXs),
          Wrap(
            spacing: AppTokens.spaceXs,
            children: [
              for (var day = 1; day <= 7; day++)
                ChoiceChip(
                  label: Text('周${kWeekdayLabels[day - 1]}'),
                  selected: _weekday == day,
                  onSelected: (_) => setState(() => _weekday = day),
                ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 节次区间。
          _FieldLabel(text: '节次', scheme: scheme),
          const SizedBox(height: AppTokens.spaceXs),
          Row(
            children: [
              Expanded(
                child: _NumberDropdown(
                  label: '起始节',
                  value: _startPeriod,
                  options: _periodOptions,
                  suffix: '节',
                  semanticLabel: '起始节次',
                  onChanged: (value) => setState(() {
                    _startPeriod = value;
                    _syncPeriods();
                  }),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
                child: Text('至'),
              ),
              Expanded(
                child: _NumberDropdown(
                  label: '结束节',
                  value: _endPeriod,
                  options: _periodOptions,
                  suffix: '节',
                  semanticLabel: '结束节次',
                  onChanged: (value) => setState(() {
                    _endPeriod = value;
                    _syncPeriods(startChanged: false);
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 教学周区间。
          _FieldLabel(text: '教学周', scheme: scheme),
          const SizedBox(height: AppTokens.spaceXs),
          Row(
            children: [
              Expanded(
                child: _NumberDropdown(
                  label: '起始周',
                  value: _startWeek,
                  options: _weekOptions,
                  suffix: '周',
                  semanticLabel: '起始教学周',
                  onChanged: (value) => setState(() {
                    _startWeek = value;
                    _syncWeeks();
                  }),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
                child: Text('至'),
              ),
              Expanded(
                child: _NumberDropdown(
                  label: '结束周',
                  value: _endWeek,
                  options: _weekOptions,
                  suffix: '周',
                  semanticLabel: '结束教学周',
                  onChanged: (value) => setState(() {
                    _endWeek = value;
                    _syncWeeks(startChanged: false);
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 单双周。
          _FieldLabel(text: '单双周', scheme: scheme),
          const SizedBox(height: AppTokens.spaceXs),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: WeekParity.all, label: Text('每周')),
                ButtonSegment(value: WeekParity.odd, label: Text('单周')),
                ButtonSegment(value: WeekParity.even, label: Text('双周')),
              ],
              selected: {_weekParity},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  setState(() => _weekParity = selection.first),
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 类别（可选）。
          AppFormField(
            controller: _categoryController,
            label: '课程类别（可选）',
            hint: '例如：公共必修课 / 学科基础课 / 选修课',
            maxLength: 60,
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 配色。
          _FieldLabel(text: '配色', scheme: scheme),
          const SizedBox(height: AppTokens.spaceXs),
          _ColorSwatches(
            value: _color,
            onChanged: (hex) => setState(() => _color = hex),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 备注（可选）。
          AppFormField(
            controller: _noteController,
            label: '备注（可选）',
            maxLines: 2,
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 语义回显：把四个维度合成为一句人话，边填边核对。
          _SchedulePreview(
            weekday: _weekday,
            startPeriod: _startPeriod,
            endPeriod: _endPeriod,
            startWeek: _startWeek,
            endWeek: _endWeek,
            parity: _weekParity,
          ),
          const SizedBox(height: AppTokens.spaceLg),

          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(widget.initial == null ? '添加' : '保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 表单小标题（与 [?] 输入框的 label 视觉区分：这里是分组标题而非浮动标签）。
class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text, required this.scheme});

  final String text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 数字下拉（节次 / 教学周共用）。
class _NumberDropdown extends StatelessWidget {
  const _NumberDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.semanticLabel,
    this.suffix = '',
  });

  final String label;
  final int value;
  final List<int> options;
  final String suffix;
  final String semanticLabel;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      child: DropdownButtonFormField<int>(
        initialValue: value,
        isExpanded: true,
        decoration: AppFormField.defaultDecoration(
          label: label,
          scheme: scheme,
        ),
        items: [
          for (final option in options)
            DropdownMenuItem<int>(value: option, child: Text('$option$suffix')),
        ],
        onChanged: (selected) {
          if (selected == null) return;
          onChanged(selected);
        },
      ),
    );
  }
}

/// 配色选择：圆点色块行（选中态描边 + 勾）。
class _ColorSwatches extends StatelessWidget {
  const _ColorSwatches({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: AppTokens.spaceSm,
      children: [
        for (final hex in CoursePalette.hexes)
          Semantics(
            label: '配色 $hex',
            selected: hex.toLowerCase() == value.toLowerCase(),
            button: true,
            child: InkWell(
              onTap: () => onChanged(hex),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: courseColorOf(hex),
                  shape: BoxShape.circle,
                  border: hex.toLowerCase() == value.toLowerCase()
                      ? Border.all(color: scheme.onSurface, width: 2)
                      : null,
                ),
                child: hex.toLowerCase() == value.toLowerCase()
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// 表单底部的排程语义回显。
class _SchedulePreview extends StatelessWidget {
  const _SchedulePreview({
    required this.weekday,
    required this.startPeriod,
    required this.endPeriod,
    required this.startWeek,
    required this.endWeek,
    required this.parity,
  });

  final int weekday;
  final int startPeriod;
  final int endPeriod;
  final int startWeek;
  final int endWeek;
  final String parity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timeRange = ClassPeriods.timeRangeLabel(startPeriod, endPeriod);
    final text = '${weekRangeLabel(startWeek, endWeek, parity)}'
        '的${weekdayLabel(weekday)} '
        '${ClassPeriods.rangeLabel(startPeriod, endPeriod)}'
        '${timeRange == null ? '' : ' · $timeRange'}';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceMd,
        vertical: AppTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Row(
        children: [
          Icon(Icons.event_available_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
