import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_refresh.dart';
import '../../backup/data/backup_service_provider.dart';

/// 重置数据页（设置页「重置数据」菜单项 push 进入）。
///
/// 提供两个互斥选项，均在执行前自动创建当前数据的安全副本（FR-9.3 语义，
/// 与覆盖恢复一致），副本保存到系统临时目录：
/// - 「重置数据」：仅清空全部业务数据（目标/科目/里程碑/任务/重复模板/
///   检查项，含已归档任务），设置与运行时配置保持不变；
/// - 「重置数据 + 设置」：业务数据与设置全部恢复默认（等同全新安装）。
///
/// 每个选项都要经二次确认对话框后才执行，执行后全量刷新各页缓存。
class ResetDataPage extends ConsumerStatefulWidget {
  const ResetDataPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/reset-data';

  @override
  ConsumerState<ResetDataPage> createState() => _ResetDataPageState();
}

class _ResetDataPageState extends ConsumerState<ResetDataPage> {
  /// 是否正在执行重置（防连点，按钮转菊花）。
  bool _resetting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('重置数据')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '以下操作不可撤销，执行前会自动创建当前数据的安全副本。'
            '副本保存在系统临时目录，如需找回被清空的数据，可从「备份与恢复」'
            '导入副本文件。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _buildOption(
            title: '重置数据',
            icon: Icons.delete_outline,
            description: '清空全部目标、科目、里程碑、任务、重复模板与检查项'
                '（含已归档任务）。设置与运行时配置（主题、自动备份、'
                '关闭行为、计划偏好）保持不变。',
            buttonLabel: '重置数据',
            dialogTitle: '重置全部数据？',
            dialogContent: '将清空全部目标、任务、里程碑等业务数据，设置保持不变。'
                '执行前会自动创建安全副本。此操作不可撤销。',
            onConfirm: () => _reset(includeSettings: false),
          ),
          const SizedBox(height: 16),
          _buildOption(
            title: '重置数据 + 设置',
            icon: Icons.restart_alt,
            description: '清空全部业务数据，同时把设置恢复默认（等同全新安装）：'
                '主题跟随系统、计划偏好 120 分钟/周 7 天、自动备份关闭。',
            buttonLabel: '重置数据 + 设置',
            dialogTitle: '重置全部数据与设置？',
            dialogContent: '将清空全部业务数据，并把主题、自动备份、'
                '关闭行为、计划偏好等设置恢复默认。执行前会自动创建安全副本。'
                '此操作不可撤销。',
            onConfirm: () => _reset(includeSettings: true),
          ),
        ],
      ),
    );
  }

  Widget _buildOption({
    required String title,
    required IconData icon,
    required String description,
    required String buttonLabel,
    required String dialogTitle,
    required String dialogContent,
    required Future<void> Function() onConfirm,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.error),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(description, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: _resetting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      ),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(dialogTitle),
                            content: Text(dialogContent),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: scheme.error,
                                  foregroundColor: scheme.onError,
                                ),
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('确认重置'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && mounted) {
                          await onConfirm();
                        }
                      },
                      child: Text(buttonLabel),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 执行重置：安全副本 → 清空（按选项是否含设置）→ 全量刷新缓存 → 提示。
  Future<void> _reset({required bool includeSettings}) async {
    setState(() => _resetting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final backup = ref.read(backupServiceProvider);
      final safety = await backup.resetData(includeSettings: includeSettings);
      if (!mounted) return;
      // 重置生效后刷新各页缓存（覆盖恢复同款全量刷新，跨页统一）。
      invalidateAllAppData(ref.invalidate);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '已重置${includeSettings ? '数据与设置' : '数据'}；'
            '安全副本保存在：\n${safety.path}',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e) {
      // 兜底捕获 Exception 与 Error（L36：与 restoreBackup 同款，
      // 避免 TypeError 等 Error 无提示静默失败）。
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('重置失败：$e')));
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }
}
