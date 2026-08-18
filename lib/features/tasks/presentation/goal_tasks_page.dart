import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../../../shared/widgets/collapsible_section.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'task_list_section.dart';

/// 目标全部任务页（2026-08-18）：目标详情页任务区预览截断后的全量入口。
///
/// 展示目标下全部任务，按科目分组（未分类任务组在最前，其后每个科目
/// 一组），每组为 [CollapsibleSection] 折叠区块 + [TaskListSection] 全量
/// 列表，组头可折叠收起——几百个任务时也能快速定位到想看的科目，不必
/// 整页长滚。任务操作（完成/编辑/删除/检查项）与详情页一致（TaskTile
/// 行内提供）；新建任务入口保留在目标详情页。
class GoalTasksPage extends ConsumerStatefulWidget {
  const GoalTasksPage({super.key, required this.goalId});

  final int goalId;

  @override
  ConsumerState<GoalTasksPage> createState() => _GoalTasksPageState();
}

class _GoalTasksPageState extends ConsumerState<GoalTasksPage> {
  /// 未分类任务组的折叠标记（科目 id 均为正 int，用 -1 区分）。
  static const _unassignedKey = -1;

  /// 已折叠的组 key 集合（默认全部展开，只记录折叠的）。
  final Set<int> _collapsedGroups = {};

  bool _isCollapsed(int key) => _collapsedGroups.contains(key);

  void _toggle(int key) {
    setState(() {
      if (!_collapsedGroups.remove(key)) _collapsedGroups.add(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final goalAsync = ref.watch(goalDetailProvider(widget.goalId));
    final subjectsAsync = ref.watch(subjectListProvider(widget.goalId));
    final tasksAsync = ref.watch(taskListProvider(widget.goalId));

    return Scaffold(
      appBar: AppBar(title: const Text('全部任务')),
      body: goalAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(error: error),
        data: (goal) {
          if (goal == null) {
            return const Center(child: Text('目标不存在'));
          }
          return subjectsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppErrorView(error: error),
            data: (subjects) => tasksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => AppErrorView(error: error),
              data: (tasks) => _buildBody(goal, subjects, tasks),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(Goal goal, List<Subject> subjects, List<Task> tasks) {
    final doneCount = tasks.where((t) => t.status == 'done').length;
    if (tasks.isEmpty) {
      return const Center(
        child: ChartEmptyState(
          icon: Icons.checklist,
          title: '这个目标还没有任务，去目标详情页添加',
        ),
      );
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: _Summary(goal: goal, tasks: tasks, doneCount: doneCount),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 24)),
        ..._buildGroupSlivers(subjects, tasks),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// 按「未分类组在前、科目组随科目表顺序」生成各组 slivers；
  /// 无任务的科目不占行（这是任务全览页，空科目没有可看的内容）。
  List<Widget> _buildGroupSlivers(List<Subject> subjects, List<Task> tasks) {
    final slivers = <Widget>[];
    final unassigned = tasks.where((t) => t.subjectId == null).toList();
    if (unassigned.isNotEmpty) {
      slivers.addAll(
        _groupSlivers(
          allSubjects: subjects,
          key: _unassignedKey,
          title: '未分类任务',
          groupTasks: unassigned,
        ),
      );
    }
    for (final subject in subjects) {
      final groupTasks = tasks
          .where((t) => t.subjectId == subject.id)
          .toList();
      if (groupTasks.isEmpty) continue;
      slivers.addAll(
        _groupSlivers(
          allSubjects: subjects,
          key: subject.id,
          title: subject.name,
          groupTasks: groupTasks,
        ),
      );
    }
    return slivers;
  }

  /// 单组：折叠头（CollapsibleSection，受控） + 全量任务列表（sliver）。
  List<Widget> _groupSlivers({
    required List<Subject> allSubjects,
    required int key,
    required String title,
    required List<Task> groupTasks,
  }) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverToBoxAdapter(
          child: CollapsibleSection(
            icon: Icons.checklist,
            title: title,
            summary: '${groupTasks.length} 个',
            expanded: !_isCollapsed(key),
            onChanged: (_) => _toggle(key),
            // 无 body：列表本身是 sliver，由外部按状态渲染。
          ),
        ),
      ),
      if (!_isCollapsed(key))
        TaskListSection(
          goalId: widget.goalId,
          subjects: allSubjects,
          tasks: groupTasks,
          // 新建任务入口保留在目标详情页，本页只负责浏览/操作已有任务。
          showAddButton: false,
          // 全量跨页刷新（FR-3 验收）：完成/编辑/删除任务影响今日页、
          // 日历与进度页（completedTasksProvider/allTodoTasksProvider
          // 若不失效，进度页热力图与剩余工作量停留陈旧，回归教训）。
          onChanged: () => invalidateAppData(ref),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
  }
}

/// 页面顶部概况：目标名 + 任务总数/完成数。
class _Summary extends StatelessWidget {
  const _Summary({
    required this.goal,
    required this.tasks,
    required this.doneCount,
  });

  final Goal goal;
  final List<Task> tasks;
  final int doneCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          goal.title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '共 ${tasks.length} 个任务 · $doneCount 个已完成',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
