import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// 设置页「备份与恢复」区（FR-9.1 / FR-9.2 / FR-9.3）。
///
/// - 导出备份：原生「另存为」对话框 → 单事务读取业务数据 → zip 打包；
/// - 从备份恢复：原生「打开」对话框 → 读取清单展示摘要 → 确认合并/覆盖
///   → 执行；覆盖前自动创建安全副本并展示其路径。
class BackupSection extends ConsumerWidget {
  const BackupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picker = ref.watch(backupFilePickerProvider);
    final backup = ref.watch(backupServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('备份与恢复', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '将全部业务数据导出为带版本号的备份文件；恢复前可预览摘要并选择合并或覆盖。'
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
      ],
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
    ref.invalidate(completedTasksProvider);
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(recurrenceTemplatesProvider); // family 整族（重复任务入口）
    ref.invalidate(recurrenceTemplateProvider); // family 整族（任务条目标注）
    ref.invalidate(settingsProvider);
  }
}
