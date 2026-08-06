import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../services/duration_format.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'task_list_section.dart';

/// 科目任务页：展示某一科目下的全部任务（点击科目进入）。
///
/// 任务创建默认归属当前科目；也可改为其他科目或无科目（移动任务）。
class SubjectTaskPage extends ConsumerStatefulWidget {
  const SubjectTaskPage({super.key, required this.goalId, required this.subjectId});

  final int goalId;
  final int subjectId;

  @override
  ConsumerState<SubjectTaskPage> createState() => _SubjectTaskPageState();
}

class _SubjectTaskPageState extends ConsumerState<SubjectTaskPage> {
  /// 已展开的重复模板 id 集合（手风琴局部状态）。
  final Set<int> _expandedTemplates = {};

  int get goalId => widget.goalId;
  int get subjectId => widget.subjectId;

  void _toggleTemplate(int templateId) {
    setState(() {
      if (!_expandedTemplates.remove(templateId)) {
        _expandedTemplates.add(templateId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(subjectListProvider(goalId));
    final tasksAsync = ref.watch(taskListProvider(goalId));
    final subject = subjectsAsync.valueOrNull
        ?.where((s) => s.id == subjectId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(subject?.name ?? '科目任务'),
      ),
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (_) {
          if (subject == null) {
            return const Center(child: Text('科目不存在'));
          }
          return tasksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('加载失败：$error')),
            data: (tasks) {
              final subjectTasks =
                  tasks.where((t) => t.subjectId == subjectId).toList();
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
                  // 任务区（sliver 形态懒加载，含重复实例折叠）。
                  ...TaskListSection(
                    goalId: goalId,
                    subjects: _allSubjects(ref),
                    tasks: subjectTasks,
                    title: '任务',
                    defaultSubjectId: subjectId,
                    onChanged: () => ref.invalidate(taskListProvider(goalId)),
                  ).buildSlivers(
                    context,
                    expandedTemplateIds: _expandedTemplates,
                    onToggleTemplate: _toggleTemplate,
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
    final subjects = ref.read(subjectListProvider(goalId));
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
