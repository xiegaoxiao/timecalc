import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/duration_format.dart';
import '../data/task_repository_provider.dart';
import '../domain/task_import_parser.dart';

/// 批量添加的升级版：JSON 导入任务对话框。
///
/// 支持按科目分组与未分类任务隔离导入。粘贴 JSON 后点「导入」会自动校验
/// （JSON 合法性、日期不得早于今天、不得出现非法日期），校验通过即单事务
/// 写入；校验失败展示错误列表，不写入任何任务。也可先点「校验」预览分组。
/// 目标下不存在的科目自动创建；整个导入在单事务内完成（NFR-2）。

class TaskImportDialog extends ConsumerStatefulWidget {
  const TaskImportDialog({
    super.key,
    required this.goalId,
    this.subjects = const [],
    this.currentTasks = const [],
  });

  final int goalId;

  /// 目标下已有科目（预览时标记「将新建」）。
  final List<Subject> subjects;

  /// 目标下当前未归档任务（导入将替换它们，保留为历史记录）。
  final List<Task> currentTasks;

  static Future<void> show(
    BuildContext context, {
    required int goalId,
    List<Subject> subjects = const [],
    List<Task> currentTasks = const [],
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => TaskImportDialog(
        goalId: goalId,
        subjects: subjects,
        currentTasks: currentTasks,
      ),
    );
  }

  @override
  ConsumerState<TaskImportDialog> createState() => _TaskImportDialogState();
}

class _TaskImportDialogState extends ConsumerState<TaskImportDialog> {
  static const _parser = TaskImportParser();
  late final TextEditingController _jsonController;
  TaskImportResult? _result;
  bool _importing = false;

  /// 自动校验防抖计时器：内容连续变化时只在校验最后一次。
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _jsonController = TextEditingController(text: _buildSample());
  }

  /// 示例 JSON 使用「明天」的日期，保证任何时候打开都能校验通过
  /// （导入规则：日期不得早于今天）。
  String _buildSample() {
    final today = ref.read(clockProvider)();
    final tomorrow =
        DateFormat('yyyy-MM-dd').format(today.add(const Duration(days: 1)));
    return '''
{
  "subjects": {
    "数学": [
      { "title": "真题 2013", "date": "$tomorrow", "minutes": 180 }
    ]
  },
  "unclassified": [
    { "title": "复盘本周错题", "date": "$tomorrow" }
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

  void _validate() {
    final today = ref.read(clockProvider)();
    setState(() => _result = _parser.parse(_jsonController.text, today: today));
  }

  Future<void> _import() async {
    // 点击导入时兜底校验：校验失败展示错误，不写入任何任务。
    final today = ref.read(clockProvider)();
    final result = _parser.parse(_jsonController.text, today: today);
    setState(() => _result = result);
    final plan = result.plan;
    if (plan == null) return;

    // 替换确认：导入会替换当前任务的计划，旧任务保留为历史记录。
    final replacing = widget.currentTasks.isNotEmpty;
    if (replacing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('替换当前任务计划？'),
          content: Text(
            '导入后，当前目标的 ${widget.currentTasks.length} 个任务将从计划中移除，'
            '并保留在「历史任务」中（可手动恢复）。确定继续导入？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('导入并替换'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _importing = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      final stats = await repo.importPlan(
        goalId: widget.goalId,
        items: plan.items,
        replaceExisting: true,
      );
      // 跨页刷新（FR-3 验收）：目标详情、今日页、日历同步。
      ref.invalidate(taskListProvider(widget.goalId));
      ref.invalidate(archivedTaskListProvider(widget.goalId));
      ref.invalidate(tasksByDateProvider);
      ref.invalidate(tasksByMonthProvider);
      ref.invalidate(unfinishedBeforeProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '导入 ${stats.createdTasks} 个任务'
              '${stats.createdSubjects > 0 ? '，新建 ${stats.createdSubjects} 个科目' : ''}'
              '${stats.replacedTasks > 0 ? '；${stats.replacedTasks} 个旧任务已归档到历史任务' : ''}',
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _result;

    return AlertDialog(
      title: const Text('JSON 导入任务'),
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '批量添加的升级版：按科目分组与未分类任务隔离。'
              '任务日期不得早于今天，且必须是有效日期。'
              '点「导入」会自动校验，校验不通过不会写入任何任务。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
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
                  onPressed: _validate,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('校验'),
                ),
                if (result != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    result.isValid
                        ? '校验通过：${result.plan!.items.length} 个任务'
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
              _ImportPreview(plan: result.plan!, existingSubjects: widget.subjects),
            if (widget.currentTasks.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                '当前任务（将被替换并保留为历史）',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final task in widget.currentTasks)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 2),
                          child: Text(
                            '• ${task.title} · ${task.plannedDate}'
                            '${task.estimatedMinutes != null ? ' · ${DurationFormat.minutes(task.estimatedMinutes!)}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
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

/// 校验通过后的分组预览：科目（隔离）与未分类任务。
class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.plan, required this.existingSubjects});

  final TaskImportPlan plan;
  final List<Subject> existingSubjects;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final existingNames = existingSubjects.map((s) => s.name).toSet();
    final unclassified = plan.items.where((i) => i.subjectName == null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        for (final name in plan.subjectOrder) ...[
          Text(
            '科目「$name」${existingNames.contains(name) ? '' : '（将新建）'}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: existingNames.contains(name) ? null : scheme.primary,
            ),
          ),
          for (final item in plan.items.where((i) => i.subjectName == name))
            _PreviewRow(item: item),
        ],
        if (unclassified.isNotEmpty) ...[
          const Text('未分类', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final item in unclassified) _PreviewRow(item: item),
        ],
      ],
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.item});

  final ImportedTaskItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 2),
      child: Text(
        '• ${item.title} · ${item.date}'
        '${item.minutes != null ? ' · ${DurationFormat.minutes(item.minutes!)}' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
