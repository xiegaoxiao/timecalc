import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../data/subject_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';

/// 科目管理组件（FR-1.5）：目标下的科目列表。
///
/// 每个科目显示任务数概览，点击进入该科目的任务列表页；
/// 支持添加、重命名、删除。
class SubjectManager extends ConsumerWidget {
  const SubjectManager({super.key, required this.goalId});

  final int goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(subjectListProvider(goalId));
    final tasksAsync = ref.watch(taskListProvider(goalId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('科目', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _addSubject(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加科目'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        subjectsAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text('科目加载失败：$error'),
          data: (subjects) {
            final taskCounts = <int, List<Task>>{};
            final tasks = tasksAsync.valueOrNull ?? const <Task>[];
            for (final task in tasks) {
              final subjectId = task.subjectId;
              if (subjectId != null) {
                taskCounts.putIfAbsent(subjectId, () => []).add(task);
              }
            }
            if (subjects.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('还没有科目，点击「添加科目」按科目组织任务'),
              );
            }
            return Column(
              children: [
                for (final subject in subjects)
                  _SubjectCard(
                    goalId: goalId,
                    subject: subject,
                    taskCount: taskCounts[subject.id]?.length ?? 0,
                    doneCount: taskCounts[subject.id]
                            ?.where((t) => t.status == 'done')
                            .length ??
                        0,
                    onTap: () =>
                        context.push('/goals/$goalId/subjects/${subject.id}'),
                    onRename: () => _renameSubject(context, ref, subject),
                    onDelete: () => _deleteSubject(context, ref, subject),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _addSubject(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加科目'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '科目名称',
            hintText: '例如：政治',
          ),
          maxLength: 100,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final repo = ref.read(subjectRepositoryProvider);
    await repo.create(
      goalId: goalId,
      name: name,
      color: '#3F6C51', // M1 使用默认颜色，自定义颜色后续迭代提供。
    );
    ref.invalidate(subjectListProvider(goalId));
  }

  Future<void> _renameSubject(
      BuildContext context, WidgetRef ref, Subject subject) async {
    final controller = TextEditingController(text: subject.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('重命名科目「${subject.name}」'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '科目名称',
            hintText: '例如：高等数学',
          ),
          maxLength: 100,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == subject.name) return;

    final repo = ref.read(subjectRepositoryProvider);
    await repo.rename(id: subject.id, name: name);
    ref.invalidate(subjectListProvider(goalId));
  }

  Future<void> _deleteSubject(
      BuildContext context, WidgetRef ref, Subject subject) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除科目「${subject.name}」？'),
        content: const Text('该科目下的任务会保留，但不再归属此科目。'),
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

    final repo = ref.read(subjectRepositoryProvider);
    await repo.delete(subject.id);
    ref.invalidate(subjectListProvider(goalId));
    ref.invalidate(taskListProvider(goalId));
  }
}

class _SubjectCard extends StatelessWidget {
  const _SubjectCard({
    required this.goalId,
    required this.subject,
    required this.taskCount,
    required this.doneCount,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final int goalId;
  final Subject subject;
  final int taskCount;
  final int doneCount;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          child: Text(subject.name.characters.first),
        ),
        title: Text(subject.name),
        subtitle: Text(
          taskCount == 0
              ? '还没有任务，点击进入添加'
              : '$doneCount/$taskCount 个任务完成',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '重命名科目「${subject.name}」',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: onRename,
            ),
            PopupMenuButton<String>(
              tooltip: '科目操作',
              onSelected: (action) {
                if (action == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
