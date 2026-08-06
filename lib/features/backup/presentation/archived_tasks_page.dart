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
class ArchivedTasksPage extends ConsumerWidget {
  const ArchivedTasksPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/archived';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archivedAsync = ref.watch(allArchivedTasksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('已归档任务')),
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
            itemBuilder: (context, index) =>
                _ArchivedTaskRow(task: archived[index]),
          );
        },
      ),
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
  const _ArchivedTaskRow({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completedAt = task.completedAt?.toLocal();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
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
        trailing: TextButton.icon(
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
