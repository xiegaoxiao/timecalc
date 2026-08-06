import 'package:flutter/material.dart';

/// 快捷键页占位（P1 功能，后续迭代提供）。
///
/// 由设置页「快捷键」菜单项 push 进入；当前不提供可配置项，展示后续计划。
class ShortcutsPage extends StatelessWidget {
  const ShortcutsPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/shortcuts';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              const Text('全局快捷键为 P1 功能，将在后续迭代提供'),
            ],
          ),
        ),
      ),
    );
  }
}
