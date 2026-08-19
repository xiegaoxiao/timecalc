import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/theme/accent_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/widgets/app_form_field.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../../../shared/widgets/collapsible_section.dart';
import '../../../shared/widgets/progressive_rows.dart';
import '../data/subject_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';

/// 科目管理组件（FR-1.5）：目标下的科目列表。
///
/// 每个科目显示任务数概览，点击进入该科目的任务列表页；
/// 支持添加、重命名、删除。
///
/// 列表可折叠（2026-08-18）：区块头整行可点展开/收起，收起时仅保留头行
/// 与「N 个」摘要，科目多时无需整页长滚。折叠状态为本组件局部状态，
/// 只重建本区块。
class SubjectManager extends ConsumerStatefulWidget {
  const SubjectManager({super.key, required this.goalId});

  final int goalId;

  @override
  ConsumerState<SubjectManager> createState() => _SubjectManagerState();
}

class _SubjectManagerState extends ConsumerState<SubjectManager> {
  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(subjectListProvider(widget.goalId));
    final tasksAsync = ref.watch(taskListProvider(widget.goalId));

    return CollapsibleSection(
      icon: Icons.label_outline,
      title: '科目',
      summary: subjectsAsync.valueOrNull == null
          ? null
          : '${subjectsAsync.valueOrNull!.length} 个',
      trailing: TextButton.icon(
        onPressed: () => _addSubject(context, ref),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('添加科目'),
      ),
      body: subjectsAsync.when(
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
          return ProgressiveRows(
            // 懒加载（2026-08-17）：科目列表按视口驱动渐进构建（同上
            // 里程碑区），详情页中大科目数量不一次性全建。
            itemCount: subjects.length,
            itemBuilder: (context, i) {
              final subject = subjects[i];
              return _SubjectCard(
                goalId: widget.goalId,
                subject: subject,
                taskCount: taskCounts[subject.id]?.length ?? 0,
                doneCount:
                    taskCounts[subject.id]
                        ?.where((t) => t.status == 'done')
                        .length ??
                    0,
                onTap: () => context.push(
                  '/goals/${widget.goalId}/subjects/${subject.id}',
                ),
                onRename: () => _renameSubject(context, ref, subject),
                onDelete: () => _deleteSubject(context, ref, subject),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addSubject(BuildContext context, WidgetRef ref) async {
    final name = await AppDialog.show<String>(
      context,
      title: '添加科目',
      titleIcon: Icons.label_outline,
      maxWidth: 400,
      content: const _SubjectNameDialog(
        title: '添加科目',
        hintText: '例如：政治',
        confirmLabel: '添加',
      ),
      barrierDismissible: false,
    );
    if (name == null || name.isEmpty) return;
    if (!context.mounted) return;

    final repo = ref.read(subjectRepositoryProvider);
    // 默认色跟随当前主题色系（绿/蓝，2026-08-16 解耦）；库存色随主题
    // 不迁移，仅影响新建科目。M1 曾固定 #3F6C51。
    final accentHex = Theme.of(context)
        .extension<AccentPalette>()!
        .seed
        .toARGB32()
        .toRadixString(16)
        .substring(2);
    final ok = await runDbAction(
      context,
      action: () => repo.create(
        goalId: widget.goalId,
        name: name,
        color: '#$accentHex',
      ),
    );
    if (!ok) return;
    ref.invalidate(subjectListProvider(widget.goalId));
  }

  Future<void> _renameSubject(
    BuildContext context,
    WidgetRef ref,
    Subject subject,
  ) async {
    final name = await AppDialog.show<String>(
      context,
      title: '重命名科目',
      titleIcon: Icons.edit_outlined,
      maxWidth: 400,
      content: _SubjectNameDialog(
        title: '重命名科目「${subject.name}」',
        initialValue: subject.name,
        hintText: '例如：高等数学',
        confirmLabel: '保存',
      ),
      barrierDismissible: false,
    );
    if (name == null || name.isEmpty || name == subject.name) return;
    if (!context.mounted) return;

    final repo = ref.read(subjectRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.rename(id: subject.id, name: name),
    );
    if (!ok) return;
    ref.invalidate(subjectListProvider(widget.goalId));
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
    ref.invalidate(subjectListProvider(widget.goalId));
    ref.invalidate(taskListProvider(widget.goalId));
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
/// - 字数计数（N/100）由 AppFormField 内置计数器在输入框底部展示；
/// - 点遮罩不关闭（barrierDismissible: false，避免误触丢失输入）。
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
    return Form(
      key: _formKey,
      // 用户继续输入时即时重校验，错误提示随之清除（而非停留在已修正的
      // 错误上）。
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 科目名称输入
          AppFormField(
            controller: _controller,
            label: '科目名称',
            hint: widget.hintText,
            autofocus: true,
            maxLength: _maxLength,
            textInputAction: TextInputAction.done,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '科目名称不能为空';
              }
              return null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppTokens.spaceSm),

          // 底部按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              FilledButton(
                onPressed: _submit,
                child: Text(widget.confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
