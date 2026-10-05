import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/auto_backup_service_provider.dart';
import '../data/backup_file_picker.dart';
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
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        children: [
          Text(
            '导出/恢复全部业务数据。覆盖恢复前会自动创建当前数据的安全副本（FR-9.3）。'
            '替换导入时归档保留的已完成旧任务请在「已归档任务」页查看。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppTokens.spaceLg),
          _buildAutoBackupSection(),
          const SizedBox(height: AppTokens.spaceXl),
          const ClashSectionHeader(
            icon: Icons.file_download_outlined,
            title: '手动备份 / 恢复',
            tone: ClashTone.warm,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: Wrap(
                spacing: AppTokens.spaceMd,
                runSpacing: AppTokens.spaceSm,
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
            ),
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
          padding: EdgeInsets.all(AppTokens.spaceLg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
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
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 区块头走撞色冷色（数据/自动化的归属）。
                const ClashSectionHeader(
                  icon: Icons.backup_outlined,
                  title: '自动备份',
                  tone: ClashTone.cool,
                  dense: true,
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '每日自动备份全部业务数据到本地目录（保留最近 7 份）。'
                  '应用运行期间生效：启动时检查一次、之后每小时复查。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppTokens.spaceSm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用每日自动备份'),
                  value: _enabled,
                  // 点击即写库并立即触发一次检查（review 修复）。
                  onChanged: toggleEnabled,
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Row(
                  children: [
                    Expanded(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.folder_outlined,
                          color: ClashTones.of(context, ClashTone.cool).ink,
                        ),
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
                const SizedBox(height: AppTokens.spaceSm),
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
    final picked = await ref.read(backupFilePickerProvider).pickFolder();
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
        _feedbackSnackBar(
          context,
          '已关闭每日自动备份',
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      _feedbackSnackBar(
        context,
        '已启用每日自动备份，正在检查…',
        duration: const Duration(seconds: 2),
      ),
    );
    final result = await ref.read(autoBackupServiceProvider).run();
    if (!mounted) return;
    if (result.skipped) {
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '已启用；${result.skipReason}',
          duration: const Duration(seconds: 4),
        ),
      );
    } else if (result.succeeded) {
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '已启用，自动备份完成',
          kind: _FeedbackKind.success,
        ),
      );
    } else {
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '已启用；自动备份失败：${result.errors.join('；')}',
          kind: _FeedbackKind.error,
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
        messenger.showSnackBar(
          _feedbackSnackBar(context, '未执行：${result.skipReason}'),
        );
      } else if (result.succeeded) {
        messenger.showSnackBar(
          _feedbackSnackBar(
            context,
            '自动备份完成',
            kind: _FeedbackKind.success,
          ),
        );
      } else {
        messenger.showSnackBar(
          _feedbackSnackBar(
            context,
            '自动备份失败：${result.errors.join('；')}',
            kind: _FeedbackKind.error,
          ),
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
      if (!context.mounted) return;
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '备份已导出：${target.path}',
          kind: _FeedbackKind.success,
        ),
      );
    } on Exception catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '导出失败：$e',
          kind: _FeedbackKind.error,
        ),
      );
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
      if (!context.mounted) return;
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '无法读取备份：$e',
          kind: _FeedbackKind.error,
        ),
      );
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
      if (!context.mounted) return;
      messenger.showSnackBar(
        _feedbackSnackBar(context, message, kind: _FeedbackKind.success),
      );
    } on Exception catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        _feedbackSnackBar(
          context,
          '恢复失败：$e',
          kind: _FeedbackKind.error,
        ),
      );
    }
  }

  String _lastBackupText(Setting settings) {
    final last = settings.lastAutoBackupAt;
    if (last == null) return '尚未执行过自动备份';
    return '上次成功：${DateFormat('yyyy-MM-dd HH:mm').format(last.toLocal())}';
  }
}

/// 反馈语义：正向（成功）/ 负向（失败）/ 中性提示。
enum _FeedbackKind { success, error, neutral }

/// 语义化反馈条：正向走 [AppSemanticColors.success] 容器色，失败走
/// `scheme.error` 容器色，中性提示保持主题默认（SnackBar 不再只有一种灰）。
///
/// 语义色扩展缺失时（如测试里手工构造的无扩展 ThemeData）自动退化为
/// 中性样式，绝不因为取色失败而让反馈消失。
SnackBar _feedbackSnackBar(
  BuildContext context,
  String message, {
  _FeedbackKind kind = _FeedbackKind.neutral,
  Duration? duration,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final semantic = theme.extension<AppSemanticColors>();
  Color? background;
  TextStyle? textStyle;
  switch (kind) {
    case _FeedbackKind.success:
      if (semantic != null) {
        background = semantic.successContainer;
        textStyle = TextStyle(color: semantic.onSuccessContainer);
      }
    case _FeedbackKind.error:
      background = scheme.errorContainer;
      textStyle = TextStyle(color: scheme.onErrorContainer);
    case _FeedbackKind.neutral:
      break;
  }
  return SnackBar(
    content: Text(message, style: textStyle),
    duration: duration ?? const Duration(seconds: 4),
    backgroundColor: background,
  );
}
