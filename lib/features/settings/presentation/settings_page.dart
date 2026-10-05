import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/theme/accent_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../backup/presentation/archived_tasks_page.dart';
import '../../backup/presentation/backup_page.dart';
import '../data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import 'appearance_page.dart';
import 'close_behavior_page.dart';
import 'reset_data_page.dart';
import 'shortcuts_page.dart';

/// 设置页（**v2.0 撞色语言**）：卡片化菜单，每项左侧为撞色图标底，
/// 点击进入独立子页。
///
/// 统一信息架构：关闭行为 / 自动备份 / 备份与恢复 / 已归档任务 / 外观 /
/// 快捷键一律为同一套「撞色菜单卡」（图标底 + 标题 + 摘要 + chevron），
/// 不再混用胶囊按钮、独立按钮或纯文字占位。摘要数据（关闭行为当前值、
/// 归档数量、自动备份状态）用 valueOrNull 展示，加载中/失败时回退默认
/// 文案，菜单本身不被阻塞。
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
    final appearanceLabel =
        '${_appearanceLabel(settings?.themeMode)} · ${accentLabel(settings?.accentColor)}';

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        children: [
          // 分组标题：层级更清晰（个性化 / 数据）。
          const _GroupHeader(title: '个性化', tone: ClashTone.warm),
          _MenuTile(
            icon: Icons.close_fullscreen_outlined,
            title: '关闭行为',
            subtitle: closeLabel,
            tone: ClashTone.warm,
            onTap: () => context.push(CloseBehaviorPage.route),
          ),
          _MenuTile(
            icon: Icons.palette_outlined,
            title: '外观',
            subtitle: appearanceLabel,
            tone: ClashTone.cool,
            onTap: () => context.push(AppearancePage.route),
          ),
          _MenuTile(
            icon: Icons.keyboard_outlined,
            title: '快捷键',
            subtitle: '全局快捷键 · 即将上线',
            tone: ClashTone.citrus,
            onTap: () => context.push(ShortcutsPage.route),
          ),
          const SizedBox(height: AppTokens.spaceLg),
          const _GroupHeader(title: '数据', tone: ClashTone.cool),
          _MenuTile(
            icon: Icons.backup_outlined,
            title: '备份与恢复',
            subtitle: autoBackupLabel,
            tone: ClashTone.cool,
            onTap: () => context.push(BackupPage.route),
          ),
          _MenuTile(
            icon: Icons.history,
            title: '已归档任务',
            subtitle: '$archivedCount 个已完成旧任务，可恢复回当前计划',
            tone: ClashTone.citrus,
            onTap: () => context.push(ArchivedTasksPage.route),
          ),
          _MenuTile(
            icon: Icons.delete_outline,
            title: '重置数据',
            subtitle: '清空全部数据（可选同时恢复默认设置），执行前自动备份',
            tone: ClashTone.danger,
            onTap: () => context.push(ResetDataPage.route),
          ),
        ],
      ),
    );
  }
}

/// 设置页分组标题：撞色色标 + 小号标题，分割菜单层级。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, this.tone = ClashTone.warm});

  final String title;
  final ClashTone tone;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceXs,
        0,
        AppTokens.spaceXs,
        AppTokens.spaceSm,
      ),
      child: Row(
        children: [
          Container(
            width: 3.5,
            height: 14,
            margin: const EdgeInsets.only(right: AppTokens.spaceSm),
            decoration: BoxDecoration(
              color: t.ink,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 自动备份目的地摘要（本地目录；2026-08 移除 WebDAV 后仅本地目录）。
String _autoBackupTargetsLabel(Setting? settings) {
  final local = settings?.localBackupFolder;
  if (local == null || local.trim().isEmpty) return '未配置目录';
  return '本地目录';
}

/// 主题模式摘要（M10，schema v12 `theme_mode`）。
String _appearanceLabel(String? mode) {
  return switch (mode) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };
}

/// 色系摘要（2026-08-16 色系解耦，schema v14 `accent_color`）。
String accentLabel(String? accentColor) {
  return accentPaletteById(accentColor).label;
}

/// 撞色菜单卡：撞色图标底 + 标题 + 摘要 + chevron。
///
/// 卡片走 [AppTokens.radiusLg] + 暖调细边框 + [AppTokens.shadowCard]，
/// 与全站卡片语言一致；左侧图标底按 [tone] 表达该项语义
/// （暖＝主动作、冷＝数据、点缀＝成就、危险＝重置）。
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone = ClashTone.warm,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final ClashTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = ClashTones.of(context, tone);
    // 外层只承担暖调投影（无底色），卡片底色/描边交给 Material 绘制——
    // ListTile 的水波纹必须落在最近的 Material 上，中间夹一层带底色的
    // DecoratedBox 会被 Flutter 判定为「背景/水波纹不可见」并报错。
    return Container(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        boxShadow: AppTokens.shadowCard(theme.brightness == Brightness.dark),
      ),
      child: Material(
        color:
            theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLowest,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(color: ClashTones.tint(t.ink, alpha: 0.28)),
        ),
        child: ListTile(
          onTap: onTap,
          leading: Container(
            padding: const EdgeInsets.all(AppTokens.spaceSm),
            decoration: BoxDecoration(
              color: t.soft,
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            child: Icon(icon, size: 20, color: t.onSoft),
          ),
          title: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Icon(Icons.chevron_right, color: t.ink),
        ),
      ),
    );
  }
}
