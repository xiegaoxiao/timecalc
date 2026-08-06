import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../services/duration_format.dart';
import '../data/recurrence_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'batch_task_form_dialog.dart';
import 'recurrence_task_dialog.dart';
import 'task_form_dialog.dart';
import 'task_import_dialog.dart';

/// 任务列表区域（FR-3.1/FR-3.2）：创建、编辑、删除、完成任务。
///
/// 父级负责按上下文过滤 [tasks]（如科目任务页只传该科目任务，
/// 目标详情页只传未分类任务），并处理 [onChanged] 触发数据刷新。
class TaskListSection extends ConsumerWidget {
  const TaskListSection({
    super.key,
    required this.goalId,
    required this.subjects,
    required this.tasks,
    required this.onChanged,
    this.title,
    this.description,
    this.emptyText = '还没有任务，点击「添加任务」开始安排',
    this.defaultSubjectId,
    this.showAddButton = true,
    this.currentTasks,
  });

  final int goalId;
  final List<Subject> subjects;
  final List<Task> tasks;
  final VoidCallback onChanged;
  final String? title;

  /// 标题下方的常驻说明（如未分类任务区的用途引导）。
  final String? description;
  final String emptyText;
  final int? defaultSubjectId;
  final bool showAddButton;

  /// JSON 导入将替换的目标当前任务清单（替换针对整个目标，父级可传入
  /// 全部任务；默认取本区域的 [tasks]）。
  final List<Task>? currentTasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Row(
            children: [
              Text(title!, style: Theme.of(context).textTheme.titleMedium),
              if (showAddButton) ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: () => TaskFormDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                    defaultSubjectId: defaultSubjectId,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加任务'),
                ),
                TextButton.icon(
                  onPressed: () => BatchTaskFormDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                    defaultSubjectId: defaultSubjectId,
                  ),
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('批量添加'),
                ),
                TextButton.icon(
                  onPressed: () => TaskImportDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                    // JSON 导入为「替换」语义：传入将被替换并保留为历史的
                    // 目标当前任务清单。
                    currentTasks: currentTasks ?? tasks,
                  ),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('JSON 导入'),
                ),
                TextButton.icon(
                  onPressed: () => RecurrenceTaskDialog.show(
                    context,
                    goalId: goalId,
                    subjects: subjects,
                  ),
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: const Text('重复任务'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (description != null) ...[
          const SizedBox(height: 2),
          Text(
            description!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(emptyText),
          )
        else
          Column(
            children: [
              // 重复任务折叠（手风琴）：同一模板实例数 ≥ 2 时合并为父卡片，
              // 其余保持普通任务行；整体按最早计划日期升序。
              for (final unit in _groupTasks(tasks))
                if (unit.isGroup)
                  RecurrenceGroupTile(
                    goalId: goalId,
                    templateId: unit.templateId!,
                    instances: unit.instances,
                    subjects: subjects,
                    onChanged: onChanged,
                  )
                else
                  _TaskTile(
                    goalId: goalId,
                    task: unit.task!,
                    subjects: subjects,
                    onChanged: onChanged,
                  ),
            ],
          ),
      ],
    );
  }

  /// 把任务列表按重复模板分组（FR-4 迭代：手风琴折叠）。
  ///
  /// - 同一模板的实例数 ≥ 2 → 折叠为一个父卡片单元；
  /// - 单实例重复任务与普通任务 → 各自保持独立任务行；
  /// - 输出按「每组/每任务最早计划日期」升序，保持列表按日期递增观感。
  static List<_ListUnit> _groupTasks(List<Task> tasks) {
    final groups = <int?, List<Task>>{};
    for (final task in tasks) {
      groups.putIfAbsent(task.recurrenceTemplateId, () => []).add(task);
    }

    final units = <_ListUnit>[];
    for (final entry in groups.entries) {
      final templateId = entry.key;
      final instances = entry.value
        ..sort((a, b) => a.plannedDate.compareTo(b.plannedDate));
      if (templateId != null && instances.length >= 2) {
        units.add(_ListUnit.group(templateId, instances));
      } else {
        for (final task in instances) {
          units.add(_ListUnit.single(task));
        }
      }
    }
    units.sort((a, b) => a.minDate.compareTo(b.minDate));
    return units;
  }
}

/// 任务列表展示单元：单个任务行或一组重复实例（父卡片）。
class _ListUnit {
  const _ListUnit.single(Task this.task)
      : instances = const [],
        templateId = null;

  const _ListUnit.group(this.templateId, this.instances) : task = null;

  final Task? task;
  final int? templateId;
  final List<Task> instances;

  bool get isGroup => templateId != null;

  /// 最早计划日期（`yyyy-MM-dd`，字符串序即时间序）。
  String get minDate => task?.plannedDate ?? instances.first.plannedDate;
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({
    required this.goalId,
    required this.task,
    required this.subjects,
    required this.onChanged,
  });

  final int goalId;
  final Task task;
  final List<Subject> subjects;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = task.status == 'done';
    final subjectName = task.subjectId == null
        ? null
        : subjects
            .where((s) => s.id == task.subjectId)
            .map((s) => s.name)
            .firstOrNull;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Checkbox(
          value: done,
          // 读屏可读的名称（NFR-4）：任务完成复选框不依赖相邻文本推断。
          semanticLabel: done ? '标记未完成' : '标记完成',
          onChanged: (value) async {
            final repo = ref.read(taskRepositoryProvider);
            final ok = await runDbAction(
              context,
              action: () => repo.setDone(task.id, value ?? false),
            );
            if (ok) onChanged();
          },
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                task.title,
                style: done
                    ? const TextStyle(decoration: TextDecoration.lineThrough)
                    : null,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (task.recurrenceTemplateId != null) ...[
              const SizedBox(width: 6),
              const Tooltip(
                message: '重复任务',
                child: Icon(Icons.autorenew, size: 16),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                DateFormat('yyyy-MM-dd').format(_parseDate(task.plannedDate)),
                if (task.estimatedMinutes != null)
                  DurationFormat.minutes(task.estimatedMinutes!),
                ?subjectName,
              ].join(' · '),
            ),
            if (task.note?.isNotEmpty ?? false)
              Text(
                task.note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '任务操作',
          onSelected: (action) =>
              _handleAction(context, ref, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            if (task.recurrenceTemplateId != null) ...[
              const PopupMenuItem(value: 'editRecurrence', child: Text('编辑重复规则')),
              const PopupMenuItem(value: 'stopRecurrence', child: Text('停止重复')),
            ],
            const PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAction(
      BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(taskRepositoryProvider);
    switch (action) {
      case 'edit':
        final saved = await TaskFormDialog.show(
          context,
          goalId: goalId,
          task: task,
          subjects: subjects,
        );
        if (saved) onChanged();
      case 'editRecurrence':
        final templateId = task.recurrenceTemplateId;
        if (templateId != null) {
          final template =
              await ref.read(recurrenceTemplateProvider(templateId).future);
          if (template != null && context.mounted) {
            final saved = await RecurrenceTaskDialog.show(
              context,
              goalId: goalId,
              subjects: subjects,
              editTemplate: template,
            );
            if (saved) onChanged();
          }
        }
      case 'stopRecurrence':
        final templateId = task.recurrenceTemplateId;
        if (templateId != null) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('停止重复？'),
              content: const Text('停止后不再生成新的重复任务，已生成的任务保留。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('停止重复'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            if (!context.mounted) return;
            final ok = await runDbAction(
              context,
              action: () => ref.read(recurrenceRepositoryProvider).stop(templateId),
            );
            if (!ok) return;
            ref.invalidate(recurrenceTemplatesProvider(goalId));
            onChanged();
          }
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除任务「${task.title}」？'),
            content: const Text('此操作不可撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          if (!context.mounted) return;
          final ok = await runDbAction(
            context,
            action: () => repo.delete(task.id),
          );
          if (ok) onChanged();
        }
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}

/// 重复任务折叠父卡片（FR-4 迭代：手风琴折叠）。
///
/// 将同一模板的多个实例合并为一张父卡片，默认折叠；点击整卡或右侧展开
/// 图标后向下展开，以子列表形式展示区间内每个日期的具体实例（子任务
/// 保持原有交互：复选框/日期/更多菜单，视觉内缩）。
///
/// 父卡片提供操作菜单（模板级）：编辑重复规则、停止重复、删除整个重复
/// （模板 + 全部实例）。实例数 < 2 的模板不进入本组件（见 [_groupTasks]）。
class RecurrenceGroupTile extends ConsumerStatefulWidget {
  const RecurrenceGroupTile({
    super.key,
    required this.goalId,
    required this.templateId,
    required this.instances,
    required this.subjects,
    required this.onChanged,
  });

  final int goalId;
  final int templateId;

  /// 该模板的全部实例（已按计划日期升序，见 [_groupTasks]）。
  final List<Task> instances;
  final List<Subject> subjects;
  final VoidCallback onChanged;

  @override
  ConsumerState<RecurrenceGroupTile> createState() => _RecurrenceGroupTileState();
}

class _RecurrenceGroupTileState extends ConsumerState<RecurrenceGroupTile> {
  /// 手风琴展开状态（默认折叠）。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final instances = widget.instances;
    // 模板信息（标题/是否停止）：加载中或读取失败时回退到实例首行标题。
    final template =
        ref.watch(recurrenceTemplateProvider(widget.templateId)).valueOrNull;
    final title = template?.title ?? instances.first.title;
    final stopped = template != null && !template.active;
    final scheme = Theme.of(context).colorScheme;
    final first = _parseDate(instances.first.plannedDate);
    final last = _parseDate(instances.last.plannedDate);

    return Column(
      children: [
        Card(
          margin: EdgeInsets.only(bottom: _expanded ? 0 : 8),
          child: ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            leading: const Tooltip(
              message: '重复任务',
              child: Icon(Icons.autorenew, size: 20),
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${DateFormat('yyyy-MM-dd').format(first)} ~ '
              '${DateFormat('yyyy-MM-dd').format(last)} · '
              '${instances.length} 个任务'
              '${stopped ? ' · 已停止' : ''}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  // NFR-4：展开/收起状态以图标旋转 + tooltip 双重表达。
                  tooltip: _expanded ? '收起重复任务' : '展开重复任务',
                  onPressed: () =>
                      setState(() => _expanded = !_expanded),
                  icon: AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(Icons.chevron_right, size: 20),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '任务操作',
                  onSelected: (action) => _handleAction(context, action),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'editRecurrence',
                      child: Text('编辑重复规则'),
                    ),
                    if (!stopped)
                      const PopupMenuItem(
                        value: 'stopRecurrence',
                        child: Text('停止重复'),
                      ),
                    const PopupMenuItem(
                      value: 'deleteAll',
                      child: Text('删除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // 展开的子任务列表：内缩 + 左缘竖引导线，表明隶属于父卡片。
        //
        // 性能说明：此处不使用 AnimatedSize 包裹。AnimatedSize 在动画期间
        // 对子节点逐帧重新测量/布局——含几十个实例的子列表会导致展开/收起
        // 明显卡顿（且外层页面 ListView 随高度变化每帧重算 extent）。
        // 改为条件渲染瞬时切换，只在展开/收起时布局一次；状态变化仍由
        // 图标旋转（AnimatedRotation）提供视觉反馈。
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(left: 24, bottom: 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: scheme.outlineVariant, width: 2),
              ),
            ),
            child: Column(
              children: [
                for (final task in instances)
                  _TaskTile(
                    goalId: widget.goalId,
                    task: task,
                    subjects: widget.subjects,
                    onChanged: widget.onChanged,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _handleAction(BuildContext context, String action) async {
    switch (action) {
      case 'editRecurrence':
        final template = await ref
            .read(recurrenceTemplateProvider(widget.templateId).future);
        if (template == null || !context.mounted) return;
        final saved = await RecurrenceTaskDialog.show(
          context,
          goalId: widget.goalId,
          subjects: widget.subjects,
          editTemplate: template,
        );
        if (saved) _refresh();
      case 'stopRecurrence':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('停止重复？'),
            content: const Text('停止后不再生成新的重复任务，已生成的任务保留。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('停止重复'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        if (!context.mounted) return;
        final ok = await runDbAction(
          context,
          action: () =>
              ref.read(recurrenceRepositoryProvider).stop(widget.templateId),
        );
        if (!ok) return;
        _refresh();
      case 'deleteAll':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除重复任务「${widget.instances.first.title}」？'),
            content: Text(
              '将同时删除 ${widget.instances.length} 个任务实例，此操作不可撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        if (!context.mounted) return;
        final ok = await runDbAction(
          context,
          action: () => ref
              .read(recurrenceRepositoryProvider)
              .deleteWithInstances(widget.templateId),
        );
        if (!ok) return;
        _refresh();
    }
  }

  /// 模板级操作成功后刷新：模板缓存族失效 + 通知父级刷新任务列表。
  void _refresh() {
    ref.invalidate(recurrenceTemplatesProvider(widget.goalId));
    widget.onChanged();
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
