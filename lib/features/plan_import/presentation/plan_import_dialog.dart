import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/clock_provider.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../services/duration_format.dart';
import '../data/plan_import_repository_provider.dart';
import '../data/plan_json_picker.dart';
import '../domain/plan_import_parser.dart';

/// 完整计划导入对话框：粘贴「计划书」式 JSON（plan_name/stages/
/// weekly_plan/subjects/daily_breakdown/daily_must_do/unclassified），
/// 一次落成目标 + 里程碑 + 科目 + 任务 + 重复模板 + 未分类任务。
///
/// 与 [TaskImportDialog] 同构：粘贴后 400ms 防抖自动校验，校验通过展示
/// 分组预览；任一结构性错误不写入任何数据。导入成功后返回新建目标 id
/// （供调用方跳转详情），取消/失败返回 null。
class PlanImportDialog extends ConsumerStatefulWidget {
  const PlanImportDialog({super.key});

  static Future<int?> show(BuildContext context) {
    return showDialog<int>(
      context: context,
      builder: (_) => const PlanImportDialog(),
    );
  }

  @override
  ConsumerState<PlanImportDialog> createState() => _PlanImportDialogState();
}

class _PlanImportDialogState extends ConsumerState<PlanImportDialog> {
  static const _parser = PlanImportParser();
  late final TextEditingController _jsonController;
  PlanImportResult? _result;
  bool _importing = false;

  /// 自动校验防抖计时器：内容连续变化时只在校验最后一次。
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _jsonController = TextEditingController(text: _buildSample());
  }

  /// 示例 JSON 使用「今天/明天」的日期，保证任何时候打开都能校验通过
  /// （历史日期任务会被跳过并统计，示例不含历史日期）。所有任务均带
  /// `minutes` 预估时长（进度页剩余工作量趋势/任务耗时图只统计带时长的
  /// 任务，FR-7.4）：daily_breakdown 用对象写法、daily_must_do 用对象
  /// 写法（时长继承到每天实例）、unclassified 直接带 minutes。
  String _buildSample() {
    final today = ref.read(clockProvider)();
    final todayStr = DateFormat('yyyy-MM-dd').format(today);
    final tomorrow = DateFormat('yyyy-MM-dd').format(
      today.add(const Duration(days: 1)),
    );
    final weekEnd = DateFormat('yyyy-MM-dd').format(
      today.add(const Duration(days: 6)),
    );
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
                "$tomorrow": { "title": "武忠祥讲义：三重积分（听课+例题）", "minutes": 180 }
              }
            },
            "daily_must_do": [
              { "title": "完成《三大计算》积分专项", "minutes": 30 }
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
    _jsonController.dispose();
    super.dispose();
  }

  /// 内容变化后 400ms 自动校验（粘贴即触发）。
  void _scheduleAutoValidate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _validate);
  }

  /// 选择本地 JSON 文件并读取内容填入输入框，随后自动校验。
  ///
  /// 取消选择（返回 null）不动输入；读取失败提示 SnackBar，不清空已有内容。
  Future<void> _pickFile() async {
    final String content;
    try {
      final picked = await ref.read(planJsonPickerProvider).pickJson();
      if (picked == null) return; // 用户取消。
      content = picked;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取文件失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    _jsonController.text = content;
    // 光标置于末尾，后续粘贴/查看不打断。
    _jsonController.selection = TextSelection.collapsed(
      offset: content.length,
    );
    _scheduleAutoValidate();
  }

  void _validate() {
    final today = ref.read(clockProvider)();
    setState(() => _result = _parser.parse(_jsonController.text, today: today));
  }

  Future<void> _import() async {
    // 点击导入时兜底校验：校验失败展示错误，不写入任何数据。
    final today = ref.read(clockProvider)();
    final result = _parser.parse(_jsonController.text, today: today);
    setState(() => _result = result);
    final plan = result.plan;
    if (plan == null) return;

    setState(() => _importing = true);
    try {
      final repo = ref.read(planImportRepositoryProvider);
      final stats = await repo.importPlan(plan);
      // 新建目标/里程碑/科目/模板，全量失效各页缓存。
      invalidateAllAppData(ref);
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
    } on Exception catch (e) {
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

    return AlertDialog(
      title: const Text('导入完整计划'),
      constraints: const BoxConstraints(maxWidth: 680, maxHeight: 640),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '粘贴「计划书」式 JSON（plan_name / stages / weekly_plan / '
              'subjects / daily_breakdown / daily_must_do / unclassified），'
              '一次创建目标、里程碑、科目、任务与每天重复模板。'
              '任务可带预估时长 `minutes`（1～1440，进度页统计需要）：'
              'unclassified 条目直接加 "minutes": 90，daily_breakdown 用 '
              '{ "title": ..., "minutes": 180 } 对象，daily_must_do 用 '
              '{ "title": ..., "minutes": 30 }（时长继承到每天实例）。'
              '点「导入」会自动校验，校验不通过不会写入任何数据。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _jsonController,
                maxLines: null,
                expands: true,
                onChanged: (_) => _scheduleAutoValidate(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '粘贴 JSON',
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
            if (result != null && result.isValid)
              _PlanPreview(plan: result.plan!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _importing ? null : _import,
          child: Text(_importing ? '导入中…' : '导入'),
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
    final unclassified = plan.tasks.where((t) => t.subjectName == null).toList();
    final subjectTasks = plan.tasks.where((t) => t.subjectName != null).toList();

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
            text: '${plan.milestones.length} 个里程碑'
                '（${plan.milestones.take(3).map((m) => m.title).join('、')}'
                '${plan.milestones.length > 3 ? ' 等' : ''}）',
          ),
        for (final name in plan.subjectOrder) ...[
          _PreviewRow(
            icon: Icons.category_outlined,
            text: '科目「$name」${subjectTasks.where((t) => t.subjectName == name).length} 个任务',
          ),
          for (final t in subjectTasks.where((t) => t.subjectName == name).take(3))
            _PreviewRow(text: '• ${_taskText(t)}', indent: true),
          if (subjectTasks.where((t) => t.subjectName == name).length > 3)
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

  /// 预览任务行文本：标题 · 日期，带预估时长时追加时长（与任务条目一致）。
  static String _taskText(ImportedPlanTask task) {
    final minutes = task.minutes;
    return '${task.title} · ${task.date}'
        '${minutes == null ? '' : ' · ${DurationFormat.minutes(minutes)}'}';
  }

  /// 预览例行模板行文本：标题 · 每天 N 分钟（时长继承到每条实例）。
  static String _templateText(ImportedPlanTemplate template) {
    final minutes = template.minutes;
    return '${template.title} · ${template.startDate} ~ ${template.endDate}'
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
