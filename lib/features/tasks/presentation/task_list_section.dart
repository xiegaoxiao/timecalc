import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/utils/date_text.dart';
import '../data/recurrence_repository_provider.dart';
import 'batch_task_form_dialog.dart';
import 'recurrence_task_dialog.dart';
import 'task_form_dialog.dart';
import 'task_import_dialog.dart';
import 'task_tile.dart';

/// 任务列表区域（FR-3.1/FR-3.2）：创建、编辑、删除、完成任务。
///
/// 以单个 [SliverMainAxisGroup] 的形式嵌入页面 [CustomScrollView]（任务区
/// 作为一条 sliver），任务列表使用 [SliverList.builder] **懒加载**——只构建
/// 视口内的任务行，避免几十个重复实例行一次性全量实例化。
///
/// 手风琴展开状态在本组件内部维护（[State]），点展开/收起只重建任务区
/// slivers，不重建页面其他区块（里程碑/负载/科目），避免卡顿。
/// 模板信息一次批量查询（[recurrenceTemplatesProvider]），父卡片直接取
/// map，避免每张父卡片独立查询数据库（N+1）。
///
/// 父级负责按上下文过滤 [tasks]（如科目任务页只传该科目任务，目标详情页
/// 只传未分类任务），并处理 [onChanged] 触发数据刷新。
class TaskListSection extends ConsumerStatefulWidget {
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
  ConsumerState<TaskListSection> createState() => _TaskListSectionState();
}

class _TaskListSectionState extends ConsumerState<TaskListSection> {
  /// 已展开的重复模板 id 集合（手风琴局部状态）。本组件内部维护，
  /// 展开/收起只触发任务区重建，不波及页面其他区块。
  final Set<int> _expandedTemplates = {};

  void _toggleTemplate(int templateId) {
    setState(() {
      if (!_expandedTemplates.remove(templateId)) {
        _expandedTemplates.add(templateId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final units = _groupTasks(widget.tasks);
    // 一次批量查询目标下全部模板，父卡片按 id 取（避免每张父卡片各自
    // watch 单个模板 provider 造成 N+1 数据库查询）。
    final templates = ref
            .watch(recurrenceTemplatesProvider(widget.goalId))
            .valueOrNull ??
        const <RecurrenceTemplate>[];
    final templatesById = {for (final t in templates) t.id: t};

    return SliverMainAxisGroup(
      slivers: [
        if (widget.title != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _header(context),
            ),
          ),
        if (widget.description != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _description(context),
            ),
          ),
        if (widget.tasks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Text(widget.emptyText),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: _rowCount(units),
              itemBuilder: (context, index) => _buildRow(
                context,
                units,
                templatesById,
                index,
              ),
            ),
          ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        Text(widget.title!, style: Theme.of(context).textTheme.titleMedium),
        if (widget.showAddButton) ...[
          const Spacer(),
          TextButton.icon(
            onPressed: () => TaskFormDialog.show(
              context,
              goalId: widget.goalId,
              subjects: widget.subjects,
              defaultSubjectId: widget.defaultSubjectId,
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加任务'),
          ),
          TextButton.icon(
            onPressed: () => BatchTaskFormDialog.show(
              context,
              goalId: widget.goalId,
              subjects: widget.subjects,
              defaultSubjectId: widget.defaultSubjectId,
            ),
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('批量添加'),
          ),
          // 高级操作（JSON 导入/重复任务）折叠进「更多操作」：空态下主操作
          // 已覆盖绝大多数场景，避免一行四个按钮的视觉噪音与小屏溢出。
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (action) {
              switch (action) {
                case 'import':
                  TaskImportDialog.show(
                    context,
                    goalId: widget.goalId,
                    subjects: widget.subjects,
                    // JSON 导入为「替换」语义：传入将被替换并保留为历史的
                    // 目标当前任务清单。
                    currentTasks: widget.currentTasks ?? widget.tasks,
                  );
                  break;
                case 'recurrence':
                  RecurrenceTaskDialog.show(
                    context,
                    goalId: widget.goalId,
                    subjects: widget.subjects,
                  );
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'import',
                child: Text('JSON 导入'),
              ),
              PopupMenuItem(
                value: 'recurrence',
                child: Text('重复任务'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _description(BuildContext context) {
    return Text(
      widget.description!,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
    );
  }

  /// 当前行数：折叠组计 1 行（父卡片头），展开组计 1 + N 行（实例行）。
  int _rowCount(List<_ListUnit> units) {
    var count = 0;
    for (final unit in units) {
      if (!unit.isGroup) {
        count += 1;
        continue;
      }
      count += 1;
      if (_expandedTemplates.contains(unit.templateId)) {
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
    Map<int, RecurrenceTemplate> templatesById,
    int index,
  ) {
    for (final unit in units) {
      if (!unit.isGroup) {
        if (index == 0) {
          return TaskTile(
            task: unit.task!,
            subjects: widget.subjects,
            showPlannedDate: true,
            onChanged: widget.onChanged,
          );
        }
        index -= 1;
        continue;
      }
      final templateId = unit.templateId!;
      final expanded = _expandedTemplates.contains(templateId);
      // 父卡片头行。
      if (index == 0) {
        return RecurrenceGroupTile(
          goalId: widget.goalId,
          templateId: templateId,
          template: templatesById[templateId],
          instances: unit.instances,
          subjects: widget.subjects,
          expanded: expanded,
          onToggle: () => _toggleTemplate(templateId),
          onChanged: widget.onChanged,
        );
      }
      index -= 1;
      // 展开态：实例行。
      if (expanded) {
        if (index < unit.instances.length) {
          return TaskTile(
            task: unit.instances[index],
            subjects: widget.subjects,
            showPlannedDate: true,
            onChanged: widget.onChanged,
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

/// 重复任务折叠父卡片头（FR-4 迭代：手风琴折叠）。
///
/// 仅渲染父卡片一行（标题 + 日期区间 + N 个任务 + 展开/收起图标 + 模板级
/// 操作菜单）。展开后的实例行由宿主 [SliverList] 懒加载渲染，本组件不做
/// 全量子列表，避免几十个实例行一次性实例化导致卡顿。
///
/// 模板级菜单：编辑重复规则、停止重复（已停止时隐藏）、删除整个重复
/// （模板 + 全部实例，二次确认）。
///
/// 模板信息由宿主一次批量查询后传入（[template]），本组件不 watch 单个
/// 模板 provider，避免每张父卡片触发一次数据库查询（N+1）。
class RecurrenceGroupTile extends ConsumerWidget {
  const RecurrenceGroupTile({
    super.key,
    required this.goalId,
    required this.templateId,
    required this.template,
    required this.instances,
    required this.subjects,
    required this.expanded,
    required this.onToggle,
    required this.onChanged,
  });

  final int goalId;
  final int templateId;

  /// 宿主批量查询到的模板（可能为 null：模板加载中或已被删除），
  /// 为 null 时回退到实例首行标题。
  final RecurrenceTemplate? template;

  /// 该模板的全部实例（已按计划日期升序，见 [TaskListSection._groupTasks]）。
  final List<Task> instances;
  final List<Subject> subjects;

  /// 当前是否展开（由宿主维护）。
  final bool expanded;

  /// 切换展开状态（宿主 setState 后 SliverList itemCount 随之变化）。
  final VoidCallback onToggle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final template = this.template;
    final title = template?.title ?? instances.first.title;
    final stopped = template != null && !template.active;
    final first = parseLocalDate(instances.first.plannedDate);
    final last = parseLocalDate(instances.last.plannedDate);

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
        // 用户点击编辑时按需读一次最新模板（非 watch，无 N+1）。
        final latest = await ref
            .read(recurrenceTemplateProvider(templateId).future);
        if (latest == null || !context.mounted) return;
        final saved = await RecurrenceTaskDialog.show(
          context,
          goalId: goalId,
          subjects: subjects,
          editTemplate: latest,
        );
        if (saved) _refresh(ref);
        break;
      case 'stopRecurrence':
        final confirmed = await confirmStopRecurrence(context);
        if (confirmed != true) return;
        if (!context.mounted) return;
        final ok = await runDbAction(
          context,
          action: () =>
              ref.read(recurrenceRepositoryProvider).stop(templateId),
        );
        if (!ok) return;
        _refresh(ref);
        break;
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
        break;
    }
  }

  /// 模板级操作成功后刷新：模板缓存族失效 + 通知父级刷新任务列表。
  void _refresh(WidgetRef ref) {
    ref.invalidate(recurrenceTemplatesProvider(goalId));
    onChanged();
  }
}
