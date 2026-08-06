import 'package:flutter/material.dart';

/// 外观页占位（后续里程碑提供主题切换）。
///
/// 由设置页「外观」菜单项 push 进入；当前不提供可配置项，展示后续计划。
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/appearance';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.palette_outlined, size: 48, color: scheme.outline),
              const SizedBox(height: 12),
              const Text('主题切换将在后续里程碑提供'),
              const SizedBox(height: 4),
              Text(
                '当前跟随系统主题',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
