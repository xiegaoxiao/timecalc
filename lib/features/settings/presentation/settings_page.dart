import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../backup/presentation/archived_tasks_page.dart';
import '../../backup/presentation/auto_backup_page.dart';
import '../../backup/presentation/backup_page.dart';
import '../data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import 'appearance_page.dart';
import 'close_behavior_page.dart';
import 'shortcuts_page.dart';

/// 设置页：整宽长条形菜单，每个菜单项点击进入独立子页。
///
/// 统一信息架构：关闭行为 / 自动备份 / 备份与恢复 / 已归档任务 / 外观 /
/// 快捷键一律为整宽 ListTile（图标 + 标题 + 摘要 + chevron），不再混用
/// 胶囊按钮、独立按钮或纯文字占位。摘要数据（关闭行为当前值、归档数量、
/// 自动备份状态）用 valueOrNull 展示，加载中/失败时回退默认文案，菜单
/// 本身不被阻塞。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final archivedCount = ref.watch(archivedCountProvider).valueOrNull ?? 0;
    final closeLabel = settings?.closeBehavior == CloseBehavior.minimizeToTray
        ? '最小化到托盘'
        : '直接退出';
    final autoBackupLabel = settings?.autoBackupEnabled ?? false
        ? '每日自动备份 · ${_autoBackupTargetsLabel(settings)}'
        : '每日自动备份（未开启）';

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _MenuTile(
                  icon: Icons.close_fullscreen_outlined,
                  title: '关闭行为',
                  subtitle: closeLabel,
                  onTap: () => context.push(CloseBehaviorPage.route),
                ),
                const Divider(height: 1),
                _MenuTile(
                  icon: Icons.backup_outlined,
                  title: '自动备份',
                  subtitle: autoBackupLabel,
                  onTap: () => context.push(AutoBackupPage.route),
                ),
                const Divider(height: 1),
                _MenuTile(
                  icon: Icons.file_download_outlined,
                  title: '备份与恢复',
                  subtitle: '导出备份、从备份恢复数据',
                  onTap: () => context.push(BackupPage.route),
                ),
                const Divider(height: 1),
                _MenuTile(
                  icon: Icons.history,
                  title: '已归档任务',
                  subtitle: '$archivedCount 个已完成旧任务，可恢复回当前计划',
                  onTap: () => context.push(ArchivedTasksPage.route),
                ),
                const Divider(height: 1),
                _MenuTile(
                  icon: Icons.palette_outlined,
                  title: '外观',
                  subtitle: '主题切换（后续里程碑提供）',
                  onTap: () => context.push(AppearancePage.route),
                ),
                const Divider(height: 1),
                _MenuTile(
                  icon: Icons.keyboard_outlined,
                  title: '快捷键',
                  subtitle: '全局快捷键（P1 功能，后续迭代提供）',
                  onTap: () => context.push(ShortcutsPage.route),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 自动备份目的地摘要（本地目录 / WebDAV / 未配置）。
String _autoBackupTargetsLabel(Setting? settings) {
  if (settings == null) return '本地/WebDAV';
  final parts = <String>[];
  final local = settings.localBackupFolder;
  if (local != null && local.trim().isNotEmpty) parts.add('本地');
  final url = settings.webdavUrl;
  if (url != null && url.trim().isNotEmpty) parts.add('WebDAV');
  if (parts.isEmpty) return '未配置目的地';
  return parts.join(' + ');
}

/// 整宽菜单项：图标 + 标题 + 摘要 + chevron。
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
