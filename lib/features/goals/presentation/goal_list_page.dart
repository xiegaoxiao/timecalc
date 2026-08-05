import 'package:flutter/material.dart';

/// 计划页：M1 骨架占位，PR 3 交付目标 CRUD 后展示目标列表。
class GoalListPage extends StatelessWidget {
  const GoalListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('计划')),
      body: const Center(
        child: Text('计划页（开发中）'),
      ),
    );
  }
}
