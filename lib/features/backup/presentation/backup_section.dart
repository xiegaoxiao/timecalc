import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../services/duration_format.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/recurrence_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../data/backup_file_picker.dart';
import '../data/backup_manifest.dart';
import '../data/backup_service.dart';
import '../data/backup_service_provider.dart';
import 'restore_confirm_dialog.dart';

/// 设置页「备份与恢复」卡片（FR-9.1 / FR-9.2 / FR-9.3 + 数据管理）。
///
/// 统一管理数据相关操作：
/// - 导出备份：原生「另存为」对话框 → 单事务读取业务数据 → zip 打包；
/// - 从备份恢复：原生「打开」对话框 → 读取清单展示摘要 → 确认合并/覆盖
///   → 执行；覆盖前自动创建安全副本并展示其路径；
/// - 已归档任务：替换导入时归档保留的已完成旧任务，可回看或恢复回当前
///   计划（默认折叠，展开后懒加载列表，避免归档多时卡顿）。
class BackupSection extends ConsumerWidget {
  const BackupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picker = ref.watch(backupFilePickerProvider);
    final backup = ref.watch(backupServiceProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('备份与恢复', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '导出/恢复全部业务数据，并管理替换导入时归档保留的已完成旧任务。'
              '覆盖恢复前会自动创建当前数据的安全副本（FR-9.3）。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _exportBackup(context, ref, picker, backup),
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('导出备份'),
                ),
                FilledButton.icon(
                  onPressed: () => _restoreBackup(context, ref, picker, backup),
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: const Text('从备份恢复'),
                ),
              ],
            ),
            const Divider(height: 32),
            const _ArchivedSection(),
          ],
        ),
      ),
    );
  }

  Future<void> _exportBackup(
    BuildContext context,
    WidgetRef ref,
    BackupFilePicker picker,
    BackupService backup,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final target = await picker.saveBackupFile();
    if (target == null) return; // 用户取消
    try {
      await backup.exportBackup(target);
      messenger.showSnackBar(
        SnackBar(content: Text('备份已导出：${target.path}')),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<void> _restoreBackup(
    BuildContext context,
    WidgetRef ref,
    BackupFilePicker picker,
    BackupService backup,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await picker.openBackupFile();
    if (file == null) return; // 用户取消

    final BackupManifest manifest;
    try {
      manifest = await backup.readBackupManifest(file);
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('无法读取备份：$e')));
      return;
    }

    if (!context.mounted) return;
    final choice = await RestoreConfirmDialog.show(context, manifest);
    if (choice == null || !context.mounted) return;

    try {
      final safety = await backup.restoreBackup(
        file,
        mode: choice.mode,
      );
      // 恢复生效后刷新各页缓存（跨页统一刷新）。
      _invalidateAll(ref);
      final message = switch (choice.mode) {
        RestoreMode.merge => '已合并备份数据',
        RestoreMode.overwrite =>
          '已恢复备份；当前数据安全副本保存在：\n${safety?.path ?? ''}',
      };
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }

  void _invalidateAll(WidgetRef ref) {
    ref.invalidate(goalListProvider);
    ref.invalidate(goalDetailProvider); // family 无参失效整族（详情页缓存）
    ref.invalidate(subjectListProvider); // family 整族（科目页/表单缓存）
    ref.invalidate(taskListProvider);
    ref.invalidate(tasksByDateProvider);
    ref.invalidate(tasksByMonthProvider);
    ref.invalidate(unfinishedBeforeProvider);
    ref.invalidate(archivedTaskListProvider);
    ref.invalidate(allArchivedTasksProvider);
    ref.invalidate(completedTasksProvider);
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(recurrenceTemplatesProvider); // family 整族（重复任务入口）
    ref.invalidate(recurrenceTemplateProvider); // family 整族（任务条目标注）
    ref.invalidate(settingsProvider);
  }
}

/// 已归档任务区（替换导入时归档保留的已完成旧任务）。
///
/// 默认折叠展示计数；展开后固定高度内以 [ListView.builder] 懒加载展示
/// （避免设置页外层 ListView 嵌套滚动冲突 + 归档多时不卡）。每条提供
/// 「恢复」：恢复回其所属目标的当前计划（以完成态出现，可取消勾选）。
class _ArchivedSection extends ConsumerStatefulWidget {
  const _ArchivedSection();

  @override
  ConsumerState<_ArchivedSection> createState() => _ArchivedSectionState();
}

class _ArchivedSectionState extends ConsumerState<_ArchivedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final archivedAsync = ref.watch(allArchivedTasksProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        archivedAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text('已归档任务加载失败：$error'),
          data: (archived) {
            final count = archived.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text('已归档任务（$count）'),
                  subtitle: Text(
                    count == 0
                        ? '替换导入时归档保留的已完成旧任务会出现在这里'
                        : '替换导入时归档保留的已完成旧任务，可回看或恢复回当前计划',
                  ),
                  trailing: count == 0
                      ? null
                      : IconButton(
                          tooltip: _expanded ? '收起已归档任务' : '展开已归档任务',
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          icon: AnimatedRotation(
                            turns: _expanded ? 0.25 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: const Icon(Icons.chevron_right),
                          ),
                        ),
                  onTap: count == 0
                      ? null
                      : () => setState(() => _expanded = !_expanded),
                ),
                if (_expanded)
                  SizedBox(
                    height: 320,
                    child: ListView.builder(
                      itemCount: archived.length,
                      itemBuilder: (context, index) => _ArchivedTaskRow(
                        task: archived[index],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 单条归档任务行（懒加载 ListView 的 item）。
class _ArchivedTaskRow extends ConsumerWidget {
  const _ArchivedTaskRow({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completedAt = task.completedAt?.toLocal();
    return ListTile(
      dense: true,
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
    );
  }
}
