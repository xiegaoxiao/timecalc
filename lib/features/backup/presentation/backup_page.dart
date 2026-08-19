import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/app_refresh.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/auto_backup_service_provider.dart';
import '../data/backup_file_picker.dart';
import '../data/backup_folder_picker.dart';
import '../data/backup_manifest.dart';
import '../data/backup_service.dart';
import '../data/backup_service_provider.dart';
import 'restore_confirm_dialog.dart';

/// 备份与恢复页（FR-9.1 / FR-9.2 / FR-9.3 / FR-9.4，M8 扩展，M11 合并自动备份）。
///
/// 由设置页「备份与恢复」菜单项 push 进入。统一管理数据相关操作：
/// - 自动备份区（M11 并入）：总开关（点击即写库 + 立即触发一次检查反馈）、
///   本地目录（唯一目的地）、立即备份、最近备份时间；
/// - 手动备份/恢复区：导出备份、从备份恢复（直接选 .timecalc 文件，本地
///   自动备份生成的文件同样可用文件选择器选中恢复）。
///
/// 已归档任务在独立「已归档任务」页管理（见 archived_tasks_page.dart）。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/backup';

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  late bool _enabled;
  String? _localFolder;
  bool _initialized = false;
  bool _runningBackup = false;

  @override
  Widget build(BuildContext context) {
    final picker = ref.watch(backupFilePickerProvider);
    final backup = ref.watch(backupServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 16),
          Text(
            '导出/恢复全部业务数据。覆盖恢复前会自动创建当前数据的安全副本（FR-9.3）。'
            '替换导入时归档保留的已完成旧任务请在「已归档任务」页查看。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _buildAutoBackupSection(),
          const SizedBox(height: 24),
          Text('手动备份 / 恢复',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _exportBackup(context, picker, backup),
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('导出备份'),
              ),
              FilledButton.icon(
                onPressed: () => _restoreBackup(context, picker, backup),
                icon: const Icon(Icons.file_upload_outlined, size: 18),
                label: const Text('从备份恢复'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 自动备份区（M11 并入）：开关（点击即写库 + 立即检查反馈）+ 本地目录
  /// + 立即备份 + 最近备份时间。
  Widget _buildAutoBackupSection() {
    final settingsAsync = ref.watch(settingsProvider);
    return settingsAsync.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('自动备份配置加载失败：$error'),
        ),
      ),
      data: (settings) {
        // 首次加载到数据时初始化本地选择；provider 后续刷新不重置。
        if (!_initialized) {
          _enabled = settings.autoBackupEnabled;
          _localFolder = settings.localBackupFolder;
          _initialized = true;
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.backup_outlined,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('自动备份',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '每日自动备份全部业务数据到本地目录（保留最近 7 份）。'
                  '应用运行期间生效：启动时检查一次、之后每小时复查。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用每日自动备份'),
                  value: _enabled,
                  // 点击即写库并立即触发一次检查（review 修复）。
                  onChanged: toggleEnabled,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          _localFolder == null ||
                                  _localFolder!.trim().isEmpty
                              ? '未选择（本地目的地不启用）'
                              : _localFolder!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _pickFolder,
                      child: const Text('选择目录…'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _lastBackupText(settings),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    _runningBackup
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton(
                            onPressed: _backupNow,
                            child: const Text('立即备份'),
                          ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickFolder() async {
    final picked = await ref.read(backupFolderPickerProvider).pickFolder();
    if (picked == null || picked.trim().isEmpty) return;
    if (!mounted) return;
    final folder = picked.trim();
    setState(() => _localFolder = folder); // 即时反馈
    // 点击即写库（与其他交互一致，无独立保存按钮）。
    final ok = await runDbAction(
      context,
      action: () async {
        await ref
            .read(settingsRepositoryProvider)
            .updateLocalBackupFolder(folder);
      },
    );
    if (!ok) {
      // 写库失败：还原显示（runDbAction 已弹「数据保存失败」）。
      if (mounted) {
        final saved =
            ref.read(settingsProvider).valueOrNull?.localBackupFolder;
        setState(() => _localFolder = saved);
      }
      return;
    }
    ref.invalidate(settingsProvider);
  }

  /// 总开关：点击即写库（review 修复：此前只改内存，必须另点保存才落库，
  /// 用户以为开关无效）。
  ///
  /// 开启后立即触发一次自动检查并把结果/跳过原因直接反馈（尊重 FR-9.4
  /// 「距上次不足 24 小时跳过」语义，非 force），避免干等最长 1 小时。
  Future<void> toggleEnabled(bool value) async {
    if (value == _enabled) return;
    setState(() => _enabled = value); // 即时反馈
    final repo = ref.read(settingsRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.updateAutoBackupEnabled(value),
    );
    if (!ok) {
      // 写库失败：还原开关（runDbAction 已弹「数据保存失败」）。
      if (mounted) {
        final saved =
            ref.read(settingsProvider).valueOrNull?.autoBackupEnabled ?? false;
        setState(() => _enabled = saved);
      }
      return;
    }
    ref.invalidate(settingsProvider);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (!value) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已关闭每日自动备份'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已启用每日自动备份，正在检查…'),
        duration: Duration(seconds: 2),
      ),
    );
    final result = await ref.read(autoBackupServiceProvider).run();
    if (!mounted) return;
    if (result.skipped) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('已启用；${result.skipReason}'),
          duration: const Duration(seconds: 4),
        ),
      );
    } else if (result.succeeded) {
      messenger.showSnackBar(
        SnackBar(
          content:
              Text('已启用，自动备份完成：${result.uploadedTargets} 个目的地'),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('已启用；自动备份失败：${result.errors.join('；')}'),
        ),
      );
    }
  }

  /// 立即备份（force）：无论距上次多久都执行一次。
  Future<void> _backupNow() async {
    setState(() => _runningBackup = true);
    try {
      final result = await ref.read(autoBackupServiceProvider).run(force: true);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      ref.invalidate(settingsProvider);
      if (result.skipped) {
        messenger.showSnackBar(SnackBar(content: Text('未执行：${result.skipReason}')));
      } else if (result.succeeded) {
        messenger.showSnackBar(
          SnackBar(content: Text('自动备份完成：${result.uploadedTargets} 个目的地')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text('自动备份失败：${result.errors.join('；')}')),
        );
      }
    } finally {
      if (mounted) setState(() => _runningBackup = false);
    }
  }

  Future<void> _exportBackup(
    BuildContext context,
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
    BackupFilePicker picker,
    BackupService backup,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await picker.openBackupFile();
    if (file == null || !context.mounted) return; // 用户取消
    await _confirmAndRestore(context, backup, messenger, file);
  }

  /// 统一恢复确认流程：读清单 → 确认合并/覆盖 → 执行 → 全量刷新缓存。
  Future<void> _confirmAndRestore(
    BuildContext context,
    BackupService backup,
    ScaffoldMessengerState messenger,
    File file,
  ) async {
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
      invalidateAllAppData(ref.invalidate);
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

  String _lastBackupText(Setting settings) {
    final last = settings.lastAutoBackupAt;
    if (last == null) return '尚未执行过自动备份';
    return '上次成功：${DateFormat('yyyy-MM-dd HH:mm').format(last.toLocal())}';
  }
}
