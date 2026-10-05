import 'package:flutter/material.dart';

import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';

/// 快捷键页占位（P1 功能，后续迭代提供）。
///
/// 由设置页「快捷键」菜单项 push 进入；当前不提供可配置项，以撞色空态
/// （[ClashEmptyState]，点缀色）说明后续计划，避免纯空页给用户
/// 「功能异常/预期落空」的观感。
class ShortcutsPage extends StatelessWidget {
  const ShortcutsPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/shortcuts';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('快捷键')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClashEmptyState(
              icon: Icons.keyboard_outlined,
              title: '全局快捷键',
              message: '后续版本将支持全局呼出窗口、快捷标记完成等快捷键操作',
              tone: ClashTone.citrus,
              compact: true,
            ),
            const Chip(
              avatar: Icon(Icons.construction, size: 16),
              label: Text('即将上线'),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
