import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../data/subject_repository_provider.dart';

/// 科目管理组件（FR-1.5：任务可选属于一个科目/分组）。
///
/// 以输入框 + 删除按钮管理目标下的科目列表；M1 仅支持增删，
/// 重命名与排序（sortOrder）在后续迭代补充。
class SubjectManager extends ConsumerWidget {
  const SubjectManager({super.key, required this.goalId});

  final int goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(subjectListProvider(goalId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('科目', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        subjectsAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text('科目加载失败：$error'),
          data: (subjects) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final subject in subjects)
                _SubjectChip(
                  subject: subject,
                  onDelete: () => _deleteSubject(context, ref, subject),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('添加科目'),
                onPressed: () => _addSubject(context, ref),
              ),
            ],
          ),
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
            hintText: '例如：数学',
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
  }
}

class _SubjectChip extends StatelessWidget {
  const _SubjectChip({required this.subject, required this.onDelete});

  final Subject subject;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(subject.name),
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: onDelete,
      deleteButtonTooltipMessage: '删除科目「${subject.name}」',
    );
  }
}
