import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../../plan_import/data/plan_file_picker.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/course_repository_provider.dart';
import '../domain/class_period.dart';
import '../domain/course_week.dart';
import '../domain/timetable_import_parser.dart';

/// 大文件后台解析的 isolate 入口（与完整计划导入同款大文件策略）。
///
/// `compute` 要求入口为顶层函数，且返回值可跨 isolate 传递：解析器是纯
/// Dart、[TimetableImportResult] 是纯数据类，满足条件。
TimetableImportResult _parseTimetableInIsolate(String source) {
  return const TimetableImportParser().parse(source);
}

/// 课表导入对话框（FR-10）。
///
/// 输入方式与「完整计划导入」一致：**选择文件**或**直接粘贴**，按内容判别
/// 格式（`BEGIN:VCALENDAR` 开头按 iCalendar，否则按课表 JSON）。400ms 防抖
/// 自动校验，通过后展示「第 N 周 · 周X 第 A-B 节」的分组预览；任一结构性
/// 错误不写入任何数据（NFR-2）。
///
/// 写入方式二选一：**替换**（先清空再写入，重复导入同一份课表不会翻倍）
/// 或**追加**（多学期/多来源课表并存）。两者都在单事务内完成。
class TimetableImportDialog extends ConsumerStatefulWidget {
  const TimetableImportDialog({super.key});

  /// 导入成功返回 true（调用方据此刷新课表与设置）。
  static Future<bool?> show(BuildContext context) {
    return AppDialog.show<bool>(
      context,
      title: '导入课表',
      titleIcon: Icons.upload_file_outlined,
      maxWidth: 640,
      content: const TimetableImportDialog(),
      barrierDismissible: false,
    );
  }

  @override
  ConsumerState<TimetableImportDialog> createState() =>
      _TimetableImportDialogState();
}

class _TimetableImportDialogState extends ConsumerState<TimetableImportDialog> {
  static const _parser = TimetableImportParser();

  /// 大文件解析阈值（字节）：超过后丢到后台 isolate，避免阻塞 UI。
  static const int _isolateThreshold = 256 * 1024;

  final _contentController = TextEditingController();

  /// 导入方式：true = 替换现有课表（默认），false = 追加。
  bool _replace = true;

  TimetableImportResult? _result;
  bool _importing = false;

  /// 自动校验防抖计时器与序号（丢弃过期校验结果）。
  Timer? _debounce;
  int _validateSeq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _contentController.dispose();
    super.dispose();
  }

  bool get _hasContent => _contentController.text.trim().isNotEmpty;

  void _scheduleAutoValidate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _validate);
  }

  /// 选择本地课表文件（.ics / .json）并读入输入框。
  ///
  /// 复用「完整计划导入」的文件选择器：两者读取的都是 JSON / iCalendar
  /// 文本，差别只在解析层，共用一个 Provider 也让测试只需替换一处假实现。
  Future<void> _pickFile() async {
    final String content;
    try {
      final picked = await ref.read(planFilePickerProvider).pickPlanFile();
      if (picked == null) return; // 用户取消。
      content = picked.content;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读取文件失败：$e')));
      return;
    }
    if (!mounted) return;
    _contentController.text = content;
    _contentController.selection = TextSelection.collapsed(
      offset: content.length,
    );
    _scheduleAutoValidate();
  }

  Future<TimetableImportResult?> _parse(String source) async {
    if (source.trim().isEmpty) return null;
    if (source.length >= _isolateThreshold) {
      return compute(_parseTimetableInIsolate, source);
    }
    return _parser.parse(source);
  }

  Future<void> _validate() async {
    final seq = ++_validateSeq;
    final result = await _parse(_contentController.text);
    if (!mounted || seq != _validateSeq) return; // 过期结果丢弃。
    setState(() => _result = result);
  }

  Future<void> _import() async {
    final result = await _parse(_contentController.text);
    if (!mounted) return;
    setState(() => _result = result);
    if (result == null || !result.isValid) return;

    setState(() => _importing = true);
    try {
      final stats = await ref
          .read(courseRepositoryProvider)
          .importCourses(result.courses, replace: _replace);

      // 学期基准：文件能推导出「第 1 周周一」时写回设置——没有它课表无法
      // 按教学周筛课，而让用户在导入后再手动设一遍是多余的步骤。已有值且
      // 与文件不一致时也更新（用户此刻导入的就是当前学期的课表），并在
      // 提示里如实说明，避免周号悄悄偏移。
      final semesterStart = result.semesterStart;
      String? semesterNote;
      if (semesterStart != null) {
        final settings = ref.read(settingsProvider).valueOrNull;
        final current = settings?.semesterStartDate;
        if (current != semesterStart) {
          await ref
              .read(settingsRepositoryProvider)
              .updateSemesterStartDate(semesterStart);
          semesterNote = '，学期起始设置为 $semesterStart'
              '（第 1 周周一）';
        }
      }

      if (!mounted) return;
      final skipped = result.skippedEvents > 0
          ? '，跳过 ${result.skippedEvents} 个非课程日程'
          : '';
      final removed = stats.removed > 0 ? '，替换掉原有 ${stats.removed} 门课' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导入 ${stats.inserted} 门课程$removed$skipped$semesterNote'),
          duration: const Duration(seconds: 6),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入失败'),
          content: Text('写入数据库时出错：$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _result;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '选择或粘贴课表文件。支持 **iCalendar（.ics）**——按周重复的日程会成为'
          '一门课，`DESCRIPTION` 里形如 `教师：X｜周次：2-18周｜节次：5-8节` '
          '的字段会被读取，缺失时由上课钟点推算节次与周次；'
          '也支持 **课表 JSON**——`{"timetable":{"semester_start":"2026-09-07"},'
          '"courses":[{"title":"算法设计与分析","teacher":"梁军","location":"教A309",'
          '"weekday":4,"start_period":5,"end_period":8,"start_week":2,"end_week":8,'
          '"week_parity":"all","category":"学科基础课"}]}`，字段直给节次与周次，'
          '无损往返。点「导入」前会先校验，校验不通过不会写入任何数据。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppTokens.spaceMd),
        SizedBox(
          height: 180,
          child: AppFormField(
            child: TextField(
              controller: _contentController,
              maxLines: null,
              expands: true,
              onChanged: (_) => _scheduleAutoValidate(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: AppFormField.defaultDecoration(
                hint: '粘贴课表 JSON 或 .ics 内容',
                contentPadding: const EdgeInsets.all(8),
                scheme: scheme,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppTokens.spaceSm),
        Row(
          children: [
            TextButton.icon(
              onPressed: _importing ? null : _pickFile,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('选择文件'),
            ),
            TextButton.icon(
              onPressed: _hasContent && !_importing ? _validate : null,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('校验'),
            ),
            if (result != null) ...[
              const SizedBox(width: AppTokens.spaceSm),
              Flexible(
                child: Text(
                  result.isValid
                      ? '校验通过：${result.courses.length} 门课程'
                      : '发现 ${result.issues.length} 个问题',
                  style: TextStyle(
                    color: result.isValid ? scheme.primary : scheme.error,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        if (result != null && result.issues.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final issue in result.issues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• ${issue.location != null ? '${issue.location}：' : ''}'
                        '${issue.message}',
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (result != null && result.isValid) ...[
          const SizedBox(height: AppTokens.spaceSm),
          _ImportModeSelector(
            replace: _replace,
            onChanged: (value) => setState(() => _replace = value),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          _CoursePreview(result: result),
        ],
        const SizedBox(height: AppTokens.spaceLg),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _importing ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: AppTokens.spaceSm),
            FilledButton(
              onPressed: _importing ||
                      result == null ||
                      !result.isValid
                  ? null
                  : _import,
              child: Text(_importing ? '导入中…' : '导入'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 写入方式选择：替换 / 追加。
class _ImportModeSelector extends StatelessWidget {
  const _ImportModeSelector({required this.replace, required this.onChanged});

  final bool replace;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('替换现有课表')),
            ButtonSegment(value: false, label: Text('追加到现有课表')),
          ],
          selected: {replace},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
        const SizedBox(width: AppTokens.spaceSm),
        Flexible(
          child: Text(
            replace ? '先清空再写入（重复导入不翻倍）' : '保留现有课程，仅追加新课',
            style: TextStyle(fontSize: 11, color: scheme.outline),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 校验通过后的课程预览：按星期分组列出「节次 · 周次」。
class _CoursePreview extends StatelessWidget {
  const _CoursePreview({required this.result});

  final TimetableImportResult result;

  /// 预览最多展示的课程行数（超出折叠，避免对话框被长课表撑爆）。
  static const int _maxRows = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final courses = result.courses;
    final shown = courses.take(_maxRows).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '将导入 ${courses.length} 门课程'
          '${result.calendarName == null ? '' : '（${result.calendarName}）'}'
          '${result.semesterStart == null ? '' : '，学期起始 ${result.semesterStart}'}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: AppTokens.spaceXs),
        for (final course in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '• ${course.title} · ${weekdayLabel(course.weekday) ?? ''} '
              '${ClassPeriods.rangeLabel(course.startPeriod, course.endPeriod)}'
              ' · ${weekRangeLabel(course.startWeek, course.endWeek, course.weekParity)}'
              '${course.location == null ? '' : ' · ${course.location}'}',
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (courses.length > shown.length)
          Text(
            '• …等 ${courses.length - shown.length} 门',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        if (result.skippedEvents > 0)
          Text(
            '跳过 ${result.skippedEvents} 个非课程日程（单次事件/无上课时刻）',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
      ],
    );
  }
}
