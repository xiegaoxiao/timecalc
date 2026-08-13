import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
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
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppErrorView(error: error),
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
              // 空态内容横向居中：本列 start 对齐，需给全宽内部才能居中。
              return const SizedBox(
                width: double.infinity,
                child: ChartEmptyState(
                  icon: Icons.label_outline,
                  title: '还没有科目，点击「添加科目」按科目组织任务',
                ),
              );
            }
            return Column(
              children: [
                for (final subject in subjects)
                  _SubjectCard(
                    goalId: goalId,
                    subject: subject,
                    taskCount: taskCounts[subject.id]?.length ?? 0,
                    doneCount:
                        taskCounts[subject.id]
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
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _SubjectNameDialog(
        title: '添加科目',
        hintText: '例如：政治',
        confirmLabel: '添加',
      ),
    );
    if (name == null || name.isEmpty) return;
    if (!context.mounted) return;

    final repo = ref.read(subjectRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.create(
        goalId: goalId,
        name: name,
        color: '#3F6C51', // M1 使用默认颜色，自定义颜色后续迭代提供。
      ),
    );
    if (!ok) return;
    ref.invalidate(subjectListProvider(goalId));
  }

  Future<void> _renameSubject(
    BuildContext context,
    WidgetRef ref,
    Subject subject,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _SubjectNameDialog(
        title: '重命名科目「${subject.name}」',
        initialValue: subject.name,
        hintText: '例如：高等数学',
        confirmLabel: '保存',
      ),
    );
    if (name == null || name.isEmpty || name == subject.name) return;
    if (!context.mounted) return;

    final repo = ref.read(subjectRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.rename(id: subject.id, name: name),
    );
    if (!ok) return;
    ref.invalidate(subjectListProvider(goalId));
  }

  Future<void> _deleteSubject(
    BuildContext context,
    WidgetRef ref,
    Subject subject,
  ) async {
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
    if (!context.mounted) return;

    final repo = ref.read(subjectRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.delete(subject.id),
    );
    if (!ok) return;
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
          child: Text(
            // L11：空科目名（计划导入/备份恢复可引入）会令 characters.first
            // 抛 StateError，兜底显示占位符。
            subject.name.isEmpty ? '?' : subject.name.characters.first,
          ),
        ),
        title: Text(subject.name),
        subtitle: Text(
          taskCount == 0 ? '还没有任务，点击进入添加' : '$doneCount/$taskCount 个任务完成',
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

/// 科目名称输入对话框（添加/重命名共用，桌面端交互标准）。
///
/// - 回车提交：`onFieldSubmitted` + `TextInputAction.done`，无需鼠标点按钮；
/// - 空内容防呆：validator 校验失败显示「科目名称不能为空」红字 + 红边框，
///   用户继续输入后自动清除（AutovalidateMode.onUserInteraction）；
/// - 字数计数（N/100）移到输入框外部下方右对齐，不再挤在边框内右下角
///   与输入文字/光标重叠；
/// - 点遮罩关闭由 AlertDialog 默认提供（barrierDismissible: true）。
class _SubjectNameDialog extends StatefulWidget {
  const _SubjectNameDialog({
    required this.title,
    required this.hintText,
    required this.confirmLabel,
    this.initialValue,
  });

  final String title;
  final String hintText;
  final String confirmLabel;
  final String? initialValue;

  @override
  State<_SubjectNameDialog> createState() => _SubjectNameDialogState();
}

class _SubjectNameDialogState extends State<_SubjectNameDialog> {
  static const _maxLength = 100;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 校验通过后提交（确认按钮与回车共用同一入口）。
  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        // 用户继续输入时即时重校验，错误提示随之清除（而非停留在已修正的
        // 错误上）。
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _controller,
              autofocus: true,
              maxLength: _maxLength,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '科目名称',
                hintText: widget.hintText,
                // 关闭内置右下角计数器（会与输入文字/光标拥挤），
                // 计数改在输入框外部下方单独右对齐展示。
                counterText: '',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '科目名称不能为空';
                }
                return null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
            // 字数计数：输入框外部下方右对齐，不与输入内容重叠。
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) => Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${value.text.length}/$_maxLength',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
