import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../tasks/data/task_repository_provider.dart';

/// 已归档任务页：替换导入时归档保留的已完成旧任务列表。
///
/// 由设置页「已归档任务」菜单项 push 进入。独立页空间充足，列表默认
/// 平铺展示（不再折叠），以 `ListView.builder` 懒加载（归档多时不卡）。
/// 每条提供「恢复」：恢复回其所属目标的当前计划（以完成态出现，可取消勾选）。
///
/// 批量删除：AppBar「选择」进入选择模式，支持 全选/反选 后一键删除所选
/// 归档任务（单事务批量删除 + 确认对话框，删除后不可恢复；长按某条也可
/// 直接进入选择模式并选中该条）。
class ArchivedTasksPage extends ConsumerStatefulWidget {
  const ArchivedTasksPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/archived';

  @override
  ConsumerState<ArchivedTasksPage> createState() => _ArchivedTasksPageState();
}

class _ArchivedTasksPageState extends ConsumerState<ArchivedTasksPage> {
  /// 选择模式开关；false 时列表仅展示与「恢复」。
  bool _selecting = false;

  /// 已选归档任务 id 集合（仅 _selecting 时生效）。
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    final archivedAsync = ref.watch(allArchivedTasksProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length} 项' : '已归档任务'),
        leading: _selecting
            ? IconButton(
                tooltip: '取消选择',
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        actions: _selecting
            ? [
                TextButton(
                  onPressed: () => _selectAll(archivedAsync),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => _invertSelection(archivedAsync),
                  child: const Text('反选'),
                ),
                IconButton(
                  tooltip: '删除所选',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _deleteSelected,
                ),
              ]
            : [
                IconButton(
                  tooltip: '批量删除',
                  icon: const Icon(Icons.checklist),
                  onPressed: () {
                    // 列表为空时不允许进入选择模式（无可选内容）。
                    final archived = archivedAsync.valueOrNull;
                    if (archived == null || archived.isEmpty) return;
                    setState(() => _selecting = true);
                  },
                ),
              ],
      ),
      body: archivedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(allArchivedTasksProvider),
        ),
        data: (archived) {
          if (archived.isEmpty) {
            return const _EmptyView();
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: archived.length,
            itemBuilder: (context, index) {
              final task = archived[index];
              return _ArchivedTaskRow(
                task: task,
                selecting: _selecting,
                selected: _selected.contains(task.id),
                onToggle: () => _toggle(task.id),
                onLongPress: _selecting
                    ? null
                    : () {
                        // 长按某条：进入选择模式并选中该条。
                        setState(() {
                          _selecting = true;
                          _selected.add(task.id);
                        });
                      },
              );
            },
          );
        },
      ),
    );
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  /// 全选：选中当前列表的全部归档任务。
  void _selectAll(AsyncValue<List<Task>> archivedAsync) {
    final archived = archivedAsync.valueOrNull;
    if (archived == null || archived.isEmpty) return;
    setState(() => _selected.addAll(archived.map((t) => t.id)));
  }

  /// 反选：在当前列表范围内反转选择（全选状态下点一下即全部取消）。
  void _invertSelection(AsyncValue<List<Task>> archivedAsync) {
    final archived = archivedAsync.valueOrNull;
    if (archived == null || archived.isEmpty) return;
    setState(() {
      final universe = archived.map((t) => t.id).toSet();
      final newlySelected = universe.difference(_selected);
      _selected
        ..removeAll(universe)
        ..addAll(newlySelected);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除所选 $count 项归档任务？'),
        content: const Text('删除后不可恢复。'),
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
    if (!mounted) return;

    final repo = ref.read(taskRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.deleteMany(_selected.toList()),
    );
    if (!ok) return;
    if (!mounted) return;

    _exitSelection();
    ref.invalidate(archivedCountProvider);
    ref.invalidate(allArchivedTasksProvider);
    ref.invalidate(archivedTaskListProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $count 项归档任务')),
    );
  }
}

/// 空态：无归档任务时提示。
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            const Text('还没有归档任务'),
            const SizedBox(height: 4),
            Text(
              '替换导入时归档保留的已完成旧任务会出现在这里',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条归档任务行（ListView.builder 的 item）。
class _ArchivedTaskRow extends ConsumerWidget {
  const _ArchivedTaskRow({
    required this.task,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onLongPress,
  });

  final Task task;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completedAt = task.completedAt?.toLocal();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
        // 选择模式下点击行切换勾选；普通模式点击无操作（恢复走按钮）。
        onTap: selecting ? onToggle : null,
        onLongPress: onLongPress,
        leading: selecting
            ? Checkbox(
                value: selected,
                onChanged: (_) => onToggle(),
              )
            : null,
        title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (completedAt != null)
              '完成 ${DateFormat('yyyy-MM-dd').format(completedAt)}',
            task.plannedDate,
            if (task.estimatedMinutes != null)
              DurationFormat.minutes(task.estimatedMinutes!),
          ].join(' · '),
        ),
        trailing: selecting
            ? null
            : TextButton.icon(
                onPressed: () async {
                  final repo = ref.read(taskRepositoryProvider);
                  final ok = await runDbAction(
                    context,
                    action: () => repo.restoreArchived(task.id),
                  );
                  if (!ok) return;
                  ref.invalidate(archivedCountProvider);
                  ref.invalidate(allArchivedTasksProvider);
                  ref.invalidate(archivedTaskListProvider(task.goalId));
                  ref.invalidate(taskListProvider(task.goalId));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('「${task.title}」已恢复回当前计划')),
                    );
                  }
                },
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('恢复'),
              ),
      ),
    );
  }
}
