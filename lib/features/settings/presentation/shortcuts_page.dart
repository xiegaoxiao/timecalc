import 'package:flutter/material.dart';

/// 快捷键页占位（P1 功能，后续迭代提供）。
///
/// 由设置页「快捷键」菜单项 push 进入；当前不提供可配置项，以预告卡说明
/// 后续计划，避免纯空页给用户「功能异常/预期落空」的观感。
class ShortcutsPage extends StatelessWidget {
  const ShortcutsPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/shortcuts';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('快捷键')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.keyboard_outlined, size: 48, color: scheme.outline),
              const SizedBox(height: 12),
              Text('全局快捷键', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Chip(
                avatar: const Icon(Icons.construction, size: 16),
                label: const Text('即将上线'),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(height: 8),
              Text(
                '后续版本将支持全局呼出窗口、快捷标记完成等快捷键操作',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
