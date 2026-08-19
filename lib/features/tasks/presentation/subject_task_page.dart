import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/collapsible_section.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'task_list_section.dart';
import 'task_section_actions.dart';

/// 科目任务页：展示某一科目下的全部任务（点击科目进入）。
///
/// 任务创建默认归属当前科目；也可改为其他科目或无科目（移动任务）。
///
/// 任务区可折叠（2026-08-18）：区块头整行可点展开/收起，科目下任务多时
/// 收起即可避免整页长滚；折叠状态为本页局部状态。
class SubjectTaskPage extends ConsumerStatefulWidget {
  const SubjectTaskPage({
    super.key,
    required this.goalId,
    required this.subjectId,
  });

  final int goalId;
  final int subjectId;

  @override
  ConsumerState<SubjectTaskPage> createState() => _SubjectTaskPageState();
}

class _SubjectTaskPageState extends ConsumerState<SubjectTaskPage> {
  /// 任务区折叠状态（默认展开，保持既有默认可见行为）。
  bool _tasksExpanded = true;

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(subjectListProvider(widget.goalId));
    final tasksAsync = ref.watch(taskListProvider(widget.goalId));
    final subject = subjectsAsync.valueOrNull
        ?.where((s) => s.id == widget.subjectId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(subject?.name ?? '科目任务')),
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(subjectListProvider(widget.goalId)),
        ),
        data: (_) {
          if (subject == null) {
            return const Center(child: Text('科目不存在'));
          }
          return tasksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppErrorView(
              error: error,
              onRetry: () => ref.invalidate(taskListProvider(widget.goalId)),
            ),
            data: (tasks) {
              final subjectTasks = tasks
                  .where((t) => t.subjectId == widget.subjectId)
                  .toList();
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    sliver: SliverToBoxAdapter(
                      // 科目概览：任务数/完成数（不只依赖颜色，NFR-4）。
                      child: _SubjectSummary(
                        subject: subject,
                        tasks: subjectTasks,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: Divider(height: 32)),
                  // 任务区可折叠（2026-08-18）：头部为独立 sliver，列表
                  // 展开与否由本页状态控制；添加/导入等操作组常驻头部行，
                  // 折叠时入口不消失。TaskListSection 自身是
                  // SliverMainAxisGroup（含懒加载 SliverList，重复任务组
                  // 展开状态内部维护），直接作为一条 sliver 嵌入。
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: CollapsibleSection(
                        icon: Icons.checklist,
                        title: '任务',
                        summary: '${subjectTasks.length} 个',
                        expanded: _tasksExpanded,
                        onChanged: (v) => setState(() => _tasksExpanded = v),
                        // 无 body：列表本身是 sliver，由外部按状态渲染。
                        trailing: TaskSectionActions(
                          goalId: widget.goalId,
                          subjects: _allSubjects(ref),
                          defaultSubjectId: widget.subjectId,
                        ),
                      ),
                    ),
                  ),
                  if (_tasksExpanded)
                    TaskListSection(
                      goalId: widget.goalId,
                      subjects: _allSubjects(ref),
                      tasks: subjectTasks,
                      // 全量跨页刷新（FR-3 验收）：完成/编辑/删除任务影响
                      // 今日页、日历与进度页（completedTasksProvider/
                      // allTodoTasksProvider 若不失效，进度页热力图与剩余
                      // 工作量停留陈旧，回归教训）。
                      onChanged: () => invalidateAppData(ref.invalidate),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 表单科目下拉需要目标下全部科目（允许把任务移到其他科目）。
  List<Subject> _allSubjects(WidgetRef ref) {
    final subjects = ref.read(subjectListProvider(widget.goalId));
    return subjects.valueOrNull ?? const [];
  }
}

class _SubjectSummary extends StatelessWidget {
  const _SubjectSummary({required this.subject, required this.tasks});

  final Subject subject;
  final List<Task> tasks;

  @override
  Widget build(BuildContext context) {
    final doneCount = tasks.where((t) => t.status == 'done').length;
    final doneMinutes = tasks
        .where((t) => t.status == 'done' && t.estimatedMinutes != null)
        .fold<int>(0, (sum, t) => sum + t.estimatedMinutes!);
    final totalMinutes = tasks
        .where((t) => t.estimatedMinutes != null)
        .fold<int>(0, (sum, t) => sum + t.estimatedMinutes!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${subject.name} · $doneCount/${tasks.length} 个任务完成',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (tasks.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '已完成 ${DurationFormat.minutes(doneMinutes)} / 共 ${DurationFormat.minutes(totalMinutes)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ],
    );
  }
}
