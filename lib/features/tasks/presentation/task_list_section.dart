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
/// 作为一条 sliver）。任务列表为**单卡分组行**（2026-08-16 视觉升级）：
/// 一张卡片承载全部行（单任务/组头/组实例），行间细分隔线，行内容由
/// TaskTile / RecurrenceGroupTile（自身无卡）提供。取舍：放弃此前
/// SliverList.builder 的懒加载——行构建成本低、桌面端一次性构建可接受，
/// 换取与今天页/计划页一致的整卡视觉形态。
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

  /// _groupTasks 缓存：任务列表实例未变（如仅手风琴展开/收起）时直接复用，
  /// 避免每次重建都对全量任务重新分组+排序。
  List<Task>? _groupedTasksSource;
  List<_ListUnit>? _groupedUnits;

  void _toggleTemplate(int templateId) {
    setState(() {
      if (!_expandedTemplates.remove(templateId)) {
        _expandedTemplates.add(templateId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final units = _groupTasksCached(widget.tasks);
    // 扁平行计划：单任务 / 组头 / 组实例，一次构建、index 直接定位——
    // 替代旧版 _buildRow 对每个可见行线性扫描全部 units（O(可见行×分组数)）。
    final rows = _flattenRows(units);
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
            sliver: SliverToBoxAdapter(
              // 单卡分组行（2026-08-16 视觉升级）：单任务/组头/组实例
              // 全部行共用一张卡片，行间细分隔线。
              child: Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 12, endIndent: 12),
                      _buildRow(context, rows, templatesById, i),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 任务列表实例未变时复用上次分组结果（手风琴展开/收起不再重排任务）。
  List<_ListUnit> _groupTasksCached(List<Task> tasks) {
    if (!identical(_groupedTasksSource, tasks)) {
      _groupedTasksSource = tasks;
      _groupedUnits = _groupTasks(tasks);
    }
    return _groupedUnits!;
  }

  /// 把分组展开为扁平行计划列表（组头 1 行；展开组追加实例行）。
  List<_RowPlan> _flattenRows(List<_ListUnit> units) {
    final rows = <_RowPlan>[];
    for (final unit in units) {
      if (!unit.isGroup) {
        rows.add(_RowPlan.single(unit));
        continue;
      }
      rows.add(_RowPlan.header(unit));
      if (_expandedTemplates.contains(unit.templateId)) {
        for (final task in unit.instances) {
          rows.add(_RowPlan.instance(unit, task));
        }
      }
    }
    return rows;
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

  /// 把扁平行 index 映射到具体行 widget（宿主单卡 Column 逐行构建）。
  ///
  /// [rows] 是 [build] 里一次性展开的行计划（见 [_flattenRows]），此处按
  /// index 直接定位，O(1)——旧版对每个可见行从头线性扫描全部 units。
  Widget _buildRow(
    BuildContext context,
    List<_RowPlan> rows,
    Map<int, RecurrenceTemplate> templatesById,
    int index,
  ) {
    final plan = rows[index];
    if (plan.isHeader) {
      final unit = plan.unit;
      final templateId = unit.templateId!;
      return RecurrenceGroupTile(
        goalId: widget.goalId,
        templateId: templateId,
        template: templatesById[templateId],
        instances: unit.instances,
        subjects: widget.subjects,
        expanded: _expandedTemplates.contains(templateId),
        onToggle: () => _toggleTemplate(templateId),
        onChanged: widget.onChanged,
      );
    }
    return TaskTile(
      task: plan.task ?? plan.unit.task!,
      subjects: widget.subjects,
      showPlannedDate: true,
      onChanged: widget.onChanged,
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

/// 扁平行构建计划（[_flattenRows] 一次性生成，行 index 直接定位）。
class _RowPlan {
  const _RowPlan.single(this.unit) : task = null;
  const _RowPlan.header(this.unit) : task = null;
  const _RowPlan.instance(this.unit, Task this.task);

  final _ListUnit unit;
  final Task? task;

  /// 重复模板折叠组的父卡片头行。
  bool get isHeader => unit.isGroup && task == null;

  /// 展开组的实例行（[task] 非空）。
  bool get isInstance => unit.isGroup && task != null;
}

/// 重复任务折叠组头行（FR-4 迭代：手风琴折叠）。
///
/// 仅渲染组头一行（标题 + 日期区间 + N 个任务 + 展开/收起图标 + 模板级
/// 操作菜单）。展开后的实例行由宿主列表渲染为同卡内的后续行。
/// 单卡分组行（2026-08-16 视觉升级）：本组件不再自包 Card。
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

    // 单卡分组行（2026-08-16 视觉升级）：组头不再自包 Card，作为宿主
    // 单张任务卡内的一行（与单任务行同形态，行间分隔线由宿主提供）。
    return ListTile(
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
