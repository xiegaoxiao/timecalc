import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../data/plan_import_repository_provider.dart';
import '../data/plan_file_picker.dart';
import '../domain/ics_plan_parser.dart';
import '../domain/plan_import_parser.dart';

/// 大 JSON（≥256KB）解析的后台 isolate 入口（M9）。
///
/// `compute` 要求入口为顶层/静态函数；解析器均为纯 Dart 无依赖，
/// 可直接在 isolate 内执行。结果对象均为纯数据类，可在 isolate 组内传递。
PlanImportResult _parsePlanInIsolate((String, String) args) {
  return const PlanImportParser().parse(
    args.$1,
    today: DateTime.parse(args.$2),
  );
}

/// iCalendar 解析的后台 isolate 入口（与 JSON 同款大文件策略）。
PlanImportResult _parseIcsInIsolate((String, String, String) args) {
  return const IcsPlanParser().parse(
    args.$1,
    today: DateTime.parse(args.$2),
    fallbackTitle: args.$3,
  );
}

/// 完整计划导入对话框：粘贴「计划书」式 JSON（plan_name/stages/
/// weekly_plan/subjects/daily_breakdown/daily_must_do/unclassified），
/// 一次落成目标 + 里程碑 + 科目 + 任务 + 重复模板 + 未分类任务。
///
/// 也接受 **iCalendar（.ics）**：内容以 `BEGIN:VCALENDAR` 开头时按日历
/// 解析（每个 VEVENT → 一条任务，DTSTART 的钟点落到 startTime，
/// DTEND−DTSTART → 预估时长），从而支持从 Google 日历 / Outlook /
/// 系统日历导出的日历直接导入。
///
/// 与 [TaskImportDialog] 同构：粘贴后 400ms 防抖自动校验，校验通过展示
/// 分组预览；任一结构性错误不写入任何数据。导入成功后返回新建目标 id
/// （供调用方跳转详情），取消/失败返回 null。
class PlanImportDialog extends ConsumerStatefulWidget {
  const PlanImportDialog({super.key});

  /// 通过统一卡片式 [AppDialog] 展示（与添加任务/批量添加/快速任务等
  /// 表单对话框同一套组件、同一种视觉，而非常规 AlertDialog）。
  static Future<int?> show(BuildContext context) {
    return AppDialog.show<int>(
      context,
      title: '导入完整计划',
      titleIcon: Icons.article_outlined,
      maxWidth: 680,
      content: const PlanImportDialog(),
      barrierDismissible: false,
    );
  }

  @override
  ConsumerState<PlanImportDialog> createState() => _PlanImportDialogState();
}

class _PlanImportDialogState extends ConsumerState<PlanImportDialog> {
  static const _parser = PlanImportParser();
  static const _icsParser = IcsPlanParser();

  /// 大文件解析阈值（字节）：超过后丢到后台 isolate，避免阻塞 UI（M9）。
  static const int _isolateThreshold = 256 * 1024;

  late final TextEditingController _contentController;
  PlanImportResult? _result;
  bool _importing = false;

  /// 从文件导入时的文件名（无日历名时作目标标题）。
  String? _pickedFileName;

  /// 自动校验防抖计时器：内容连续变化时只在校验最后一次。
  Timer? _debounce;

  /// 校验序号：丢弃「防抖期间输入又变化」产生的过期校验结果。
  int _validateSeq = 0;

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: _buildSample());
  }

  /// 内容是否为 iCalendar 文本（文件与粘贴内容统一按内容判别格式）。
  static bool _looksLikeIcs(String source) =>
      source.trimLeft().toUpperCase().startsWith('BEGIN:VCALENDAR');

  /// 示例 JSON 使用「今天/明天」的日期，保证任何时候打开都能校验通过
  /// （历史日期任务会被跳过并统计，示例不含历史日期）。所有任务均带
  /// `minutes` 预估时长（进度页剩余工作量趋势只统计带时长的
  /// 任务，FR-7.4）：daily_breakdown 用对象写法、daily_must_do 用对象
  /// 写法（时长继承到每天实例）、unclassified 直接带 minutes。其中一条
  /// 带 `time`，示范小时级排程（排进日历）。
  String _buildSample() {
    final today = ref.read(clockProvider)();
    final todayStr = DateFormat('yyyy-MM-dd').format(today);
    final tomorrow = DateFormat('yyyy-MM-dd').format(addLocalDays(today, 1));
    final weekEnd = DateFormat('yyyy-MM-dd').format(addLocalDays(today, 6));
    return '''
{
  "plan_name": "示例：考研数学备考计划",
  "start_date": "$todayStr",
  "end_date": "$weekEnd",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "$todayStr ~ $weekEnd",
          "focus": "真题套卷",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "$tomorrow": { "title": "武忠祥讲义：三重积分（听课+例题）", "minutes": 180, "time": "08:30" }
              }
            },
            "daily_must_do": [
              { "title": "完成《三大计算》积分专项", "minutes": 30, "time": "20:00" }
            ]
          }
        }
      ]
    }
  ],
  "unclassified": [
    { "title": "复盘本周错题", "date": "$tomorrow", "note": "每周日复盘", "minutes": 90 }
  ]
}''';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _contentController.dispose();
    super.dispose();
  }

  /// 内容变化后 400ms 自动校验（粘贴即触发）。
  void _scheduleAutoValidate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _validate);
  }

  /// 选择本地计划文件（.json / .ics）并读取内容填入输入框，随后自动校验。
  ///
  /// 取消选择（返回 null）不动输入；读取失败提示 SnackBar，不清空已有内容。
  Future<void> _pickFile() async {
    final String content;
    try {
      final picked = await ref.read(planFilePickerProvider).pickPlanFile();
      if (picked == null) return; // 用户取消。
      content = picked.content;
      // 文件名留给 ics 解析兜底目标标题（日历无 X-WR-CALNAME 时用）。
      _pickedFileName = picked.fileName;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读取文件失败：$e')));
      return;
    }
    if (!mounted) return;
    _contentController.text = content;
    // 光标置于末尾，后续粘贴/查看不打断。
    _contentController.selection = TextSelection.collapsed(
      offset: content.length,
    );
    _scheduleAutoValidate();
  }

  /// 解析计划内容：按内容判别 JSON / iCalendar；小文件同步（即时反馈），
  /// 大文件后台 isolate（M9，避免数百 KB 文本在 UI 线程阻塞）。
  Future<PlanImportResult> _parse(String source) async {
    final today = ref.read(clockProvider)();
    final isIcs = _looksLikeIcs(source);
    final fallbackTitle = _pickedFileName;
    if (source.length >= _isolateThreshold) {
      final todayStr = DateFormat('yyyy-MM-dd').format(today);
      return isIcs
          ? compute(_parseIcsInIsolate, (source, todayStr, fallbackTitle ?? ''))
          : compute(_parsePlanInIsolate, (source, todayStr));
    }
    return isIcs
        ? _icsParser.parse(source, today: today, fallbackTitle: fallbackTitle)
        : _parser.parse(source, today: today);
  }

  Future<void> _validate() async {
    final seq = ++_validateSeq;
    final result = await _parse(_contentController.text);
    if (!mounted || seq != _validateSeq) return; // 过期结果丢弃
    setState(() => _result = result);
  }

  Future<void> _import() async {
    // 点击导入时兜底校验：校验失败展示错误，不写入任何数据。
    final result = await _parse(_contentController.text);
    if (!mounted) return;
    setState(() => _result = result);
    final plan = result.plan;
    if (plan == null) return;

    setState(() => _importing = true);
    try {
      final repo = ref.read(planImportRepositoryProvider);
      final stats = await repo.importPlan(plan);
      // 新建目标/里程碑/科目/模板，全量失效各页缓存。
      invalidateAllAppData(ref.invalidate);
      if (!mounted) return;
      // 跳过统计：历史任务/整周已过去的例行项不写入，如实提示用户。
      final skipped = <String>[
        if (stats.skippedTasks > 0) '跳过 ${stats.skippedTasks} 个历史任务',
        if (stats.skippedTemplates > 0)
          '跳过 ${stats.skippedTemplates} 个已过去的每周例行',
      ].join('；');
      final templatePart = stats.templateCount > 0
          ? '，${stats.templateCount} 个每天重复任务（已生成 ${stats.instanceCount} 个实例）'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '导入完成：目标 + ${stats.milestoneCount} 个里程碑 + '
            '${stats.subjectCount} 个科目 + ${stats.taskCount} 个任务'
            '$templatePart$skipped',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      Navigator.of(context).pop(stats.goalId);
    } catch (e) {
      // 兜底捕获 Exception 与 Error（TypeError 等），统一展示可读提示。
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
          '粘贴「计划书」式 JSON（plan_name / stages / weekly_plan / '
          'subjects / daily_breakdown / daily_must_do / unclassified），'
          '一次创建目标、里程碑、科目、任务与每天重复模板。'
          '任务可带预估时长 `minutes`（1～1440，进度页统计需要）与计划时刻 '
          '`time`（如 "20:30"，排进日历）：'
          'unclassified 条目直接加 "minutes": 90 / "time": "20:30"，'
          'daily_breakdown 用 { "title": ..., "minutes": 180 } 对象，'
          'daily_must_do 用 { "title": ..., "minutes": 30 }（时长与时刻'
          '继承到每天实例）。'
          '也可以直接粘贴或选择 iCalendar（.ics）文件——'
          '每个日程会变成一条任务，跨日期的钟点自动保留。'
          '点「导入」会自动校验，校验不通过不会写入任何数据。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: AppFormField(
            // 子组件模式：JSON 用等宽字体 + 撑满可滚动，复用统一表单边框样式。
            child: TextField(
              controller: _contentController,
              maxLines: null,
              expands: true,
              onChanged: (_) => _scheduleAutoValidate(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: AppFormField.defaultDecoration(
                hint: '粘贴 JSON 计划或 .ics 日历内容',
                contentPadding: const EdgeInsets.all(8),
                scheme: scheme,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: _importing ? null : _pickFile,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('选择文件'),
            ),
            TextButton.icon(
              onPressed: _validate,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('校验'),
            ),
            if (result != null) ...[
              const SizedBox(width: 8),
              Text(
                result.isValid
                    ? '校验通过：${result.plan!.tasks.length} 个任务'
                    : '发现 ${result.issues.length} 个问题',
                style: TextStyle(
                  color: result.isValid ? scheme.primary : scheme.error,
                ),
              ),
            ],
          ],
        ),
        if (result != null && result.issues.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final issue in result.issues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• ${issue.location != null ? '${issue.location}：' : ''}${issue.message}',
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (result != null && result.isValid) _PlanPreview(plan: result.plan!),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _importing ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _importing ? null : _import,
              child: Text(_importing ? '导入中…' : '导入'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 校验通过后的分组预览：目标 → 里程碑 → 科目任务 → 重复模板 → 未分类。
class _PlanPreview extends StatelessWidget {
  const _PlanPreview({required this.plan});

  final ImportedPlan plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 一次遍历分组（L35）：替代逐科目对任务列表做 O(科目×任务) 线性扫描，
    // 大计划（多科目多任务）预览不再重复扫描。
    final unclassified = <ImportedPlanTask>[];
    final bySubject = <String, List<ImportedPlanTask>>{};
    for (final t in plan.tasks) {
      final name = t.subjectName;
      if (name == null) {
        unclassified.add(t);
      } else {
        bySubject.putIfAbsent(name, () => []).add(t);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        _PreviewRow(
          icon: Icons.flag_outlined,
          text: '目标「${plan.goalTitle}」· 截止 ${plan.deadlineDate}',
          emphasize: true,
        ),
        if (plan.milestones.isNotEmpty)
          _PreviewRow(
            icon: Icons.flag,
            text:
                '${plan.milestones.length} 个里程碑'
                '（${plan.milestones.take(3).map((m) => m.title).join('、')}'
                '${plan.milestones.length > 3 ? ' 等' : ''}）',
          ),
        for (final name in plan.subjectOrder) ...[
          _PreviewRow(
            icon: Icons.category_outlined,
            text:
                '科目「$name」${(bySubject[name] ?? const <ImportedPlanTask>[]).length} 个任务',
          ),
          for (final t in (bySubject[name] ?? const <ImportedPlanTask>[]).take(
            3,
          ))
            _PreviewRow(text: '• ${_taskText(t)}', indent: true),
          if ((bySubject[name] ?? const <ImportedPlanTask>[]).length > 3)
            _PreviewRow(text: '• …等任务', indent: true),
        ],
        if (unclassified.isNotEmpty) ...[
          _PreviewRow(
            icon: Icons.category_outlined,
            text: '未分类任务 ${unclassified.length} 个',
          ),
          for (final t in unclassified.take(3))
            _PreviewRow(text: '• ${_taskText(t)}', indent: true),
          if (unclassified.length > 3)
            _PreviewRow(text: '• …等任务', indent: true),
        ],
        if (plan.templates.isNotEmpty) ...[
          _PreviewRow(
            icon: Icons.autorenew,
            text: '${plan.templates.length} 个每天重复任务（每周例行）',
          ),
          for (final t in plan.templates.take(3))
            _PreviewRow(text: '• ${_templateText(t)}', indent: true),
          if (plan.templates.length > 3)
            _PreviewRow(text: '• …等例行', indent: true),
        ],
        if (plan.skippedTasks > 0 || plan.skippedTemplates > 0)
          Text(
            '将跳过：${plan.skippedTasks} 个历史任务'
            '${plan.skippedTemplates > 0 ? '、${plan.skippedTemplates} 个已过去的每周例行' : ''}',
            style: TextStyle(color: scheme.outline, fontSize: 12),
          ),
      ],
    );
  }

  /// 预览任务行文本：标题 · 日期（有时刻则「日期 时刻」），带预估时长时
  /// 追加时长（与任务条目一致）。
  static String _taskText(ImportedPlanTask task) {
    final minutes = task.minutes;
    final time = task.time;
    return '${task.title} · ${task.date}${time == null ? '' : ' $time'}'
        '${minutes == null ? '' : ' · ${DurationFormat.minutes(minutes)}'}';
  }

  /// 预览例行模板行文本：标题 · 每天 N 分钟（时长与时刻继承到每条实例）。
  static String _templateText(ImportedPlanTemplate template) {
    final minutes = template.minutes;
    final time = template.time;
    return '${template.title} · ${template.startDate} ~ ${template.endDate}'
        '${time == null ? '' : ' · 每天 $time'}'
        '${minutes == null ? '' : ' · 每天 ${DurationFormat.minutes(minutes)}'}';
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    this.icon,
    required this.text,
    this.emphasize = false,
    this.indent = false,
  });

  final IconData? icon;
  final String text;
  final bool emphasize;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: indent ? 24 : 0, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
                color: emphasize ? scheme.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
