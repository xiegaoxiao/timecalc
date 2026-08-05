import 'package:flutter/material.dart';

/// 设置页：M3 起交付计划偏好、外观、备份等设置项。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: const Center(
        child: Text('设置页（M3 开发中）'),
      ),
    );
  }
}
