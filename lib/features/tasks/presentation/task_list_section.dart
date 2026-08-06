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
/// 以 sliver 形态供页面 [CustomScrollView] 嵌入（[buildSlivers]），任务列表
/// 使用 [SliverList.builder] **懒加载**——只构建视口内的任务行，避免几十个
/// 重复实例行一次性全量实例化造成进入页面/展开收起卡顿。
///
/// 父级负责按上下文过滤 [tasks]（如科目任务页只传该科目任务，目标详情页
/// 只传未分类任务），并处理 [onChanged] 触发数据刷新。
/// 手风琴展开状态由宿主页面管理（[expandedTemplateIds]/[onToggleTemplate]）。
class TaskListSection extends StatelessWidget {
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

  /// 本组件为 sliver 形态，必须通过 [buildSlivers] 嵌入页面
  /// [CustomScrollView]；直接 [build] 渲染无意义，返回占位。
  @override
  Widget build(BuildContext context) {
    throw UnsupportedError(
      'TaskListSection 是 sliver 形态组件，请通过 buildSlivers() 嵌入 CustomScrollView。',
    );
  }

  /// 生成嵌入页面 [CustomScrollView] 的 slivers：区块头（标题/按钮/描述）
  /// + 懒加载任务列表。
  ///
  /// [expandedTemplateIds] 为已展开的重复模板 id 集合（折叠/展开的行结构
  /// 决定 SliverList 的 itemCount），[onToggleTemplate] 切换单个模板展开态。
  List<Widget> buildSlivers(
    BuildContext context, {
    required Set<int> expandedTemplateIds,
    required ValueChanged<int> onToggleTemplate,
  }) {
    final units = _groupTasks(tasks);
    return [
      if (title != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _header(context),
          ),
        ),
      if (description != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _description(context),
          ),
        ),
      if (tasks.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text(emptyText),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: _rowCount(units, expandedTemplateIds),
            itemBuilder: (context, index) => _buildRow(
              context,
              units,
              expandedTemplateIds,
              onToggleTemplate,
              index,
            ),
          ),
        ),
    ];
  }

  Widget _header(BuildContext context) {
    return Row(
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
    );
  }

  Widget _description(BuildContext context) {
    return Text(
      description!,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
    );
  }

  /// 当前行数：折叠组计 1 行（父卡片头），展开组计 1 + N 行（实例行）。
  static int _rowCount(List<_ListUnit> units, Set<int> expandedTemplateIds) {
    var count = 0;
    for (final unit in units) {
      if (!unit.isGroup) {
        count += 1;
        continue;
      }
      count += 1;
      if (expandedTemplateIds.contains(unit.templateId)) {
        count += unit.instances.length;
      }
    }
    return count;
  }

  /// 把扁平行 index 映射到具体行 widget（懒加载的 itemBuilder 每次只构建
  /// 可见的那几行，滚动时才按需实例化其余行）。
  Widget _buildRow(
    BuildContext context,
    List<_ListUnit> units,
    Set<int> expandedTemplateIds,
    ValueChanged<int> onToggleTemplate,
    int index,
  ) {
    for (final unit in units) {
      if (!unit.isGroup) {
        if (index == 0) {
          return _TaskTile(
            goalId: goalId,
            task: unit.task!,
            subjects: subjects,
            onChanged: onChanged,
          );
        }
        index -= 1;
        continue;
      }
      final templateId = unit.templateId!;
      final expanded = expandedTemplateIds.contains(templateId);
      // 父卡片头行。
      if (index == 0) {
        return RecurrenceGroupTile(
          goalId: goalId,
          templateId: templateId,
          instances: unit.instances,
          subjects: subjects,
          expanded: expanded,
          onToggle: () => onToggleTemplate(templateId),
          onChanged: onChanged,
        );
      }
      index -= 1;
      // 展开态：实例行。
      if (expanded) {
        if (index < unit.instances.length) {
          return _TaskTile(
            goalId: goalId,
            task: unit.instances[index],
            subjects: subjects,
            onChanged: onChanged,
          );
        }
        index -= unit.instances.length;
      }
    }
    throw StateError('row index out of range: $index');
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

/// 重复任务折叠父卡片头（FR-4 迭代：手风琴折叠）。
///
/// 仅渲染父卡片一行（标题 + 日期区间 + N 个任务 + 展开/收起图标 + 模板级
/// 操作菜单）。展开后的实例行由宿主 [SliverList] 懒加载渲染，本组件不做
/// 全量子列表，避免几十个实例行一次性实例化导致卡顿。
///
/// 模板级菜单：编辑重复规则、停止重复（已停止时隐藏）、删除整个重复
/// （模板 + 全部实例，二次确认）。
class RecurrenceGroupTile extends ConsumerWidget {
  const RecurrenceGroupTile({
    super.key,
    required this.goalId,
    required this.templateId,
    required this.instances,
    required this.subjects,
    required this.expanded,
    required this.onToggle,
    required this.onChanged,
  });

  final int goalId;
  final int templateId;

  /// 该模板的全部实例（已按计划日期升序，见 [TaskListSection._groupTasks]）。
  final List<Task> instances;
  final List<Subject> subjects;

  /// 当前是否展开（由宿主页面维护）。
  final bool expanded;

  /// 切换展开状态（宿主 setState 后 SliverList itemCount 随之变化）。
  final VoidCallback onToggle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 模板信息（标题/是否停止）：加载中或读取失败时回退到实例首行标题。
    final template =
        ref.watch(recurrenceTemplateProvider(templateId)).valueOrNull;
    final title = template?.title ?? instances.first.title;
    final stopped = template != null && !template.active;
    final first = _parseDate(instances.first.plannedDate);
    final last = _parseDate(instances.last.plannedDate);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onToggle,
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
              tooltip: expanded ? '收起重复任务' : '展开重复任务',
              onPressed: onToggle,
              icon: AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(Icons.chevron_right, size: 20),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '任务操作',
              onSelected: (action) => _handleAction(context, ref, action),
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
    );
  }

  Future<void> _handleAction(BuildContext context, WidgetRef ref, String action) async {
    switch (action) {
      case 'editRecurrence':
        final template = await ref
            .read(recurrenceTemplateProvider(templateId).future);
        if (template == null || !context.mounted) return;
        final saved = await RecurrenceTaskDialog.show(
          context,
          goalId: goalId,
          subjects: subjects,
          editTemplate: template,
        );
        if (saved) _refresh(ref);
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
              ref.read(recurrenceRepositoryProvider).stop(templateId),
        );
        if (!ok) return;
        _refresh(ref);
      case 'deleteAll':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除重复任务「${instances.first.title}」？'),
            content: Text(
              '将同时删除 ${instances.length} 个任务实例，此操作不可撤销。',
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
              .deleteWithInstances(templateId),
        );
        if (!ok) return;
        _refresh(ref);
    }
  }

  /// 模板级操作成功后刷新：模板缓存族失效 + 通知父级刷新任务列表。
  void _refresh(WidgetRef ref) {
    ref.invalidate(recurrenceTemplatesProvider(goalId));
    onChanged();
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}
