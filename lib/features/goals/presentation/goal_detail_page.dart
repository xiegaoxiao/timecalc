import 'package:flutter/material.dart';

/// 目标详情页：M1 骨架占位，PR 3/4 交付目标信息与任务 CRUD。
class GoalDetailPage extends StatelessWidget {
  const GoalDetailPage({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('目标详情')),
      body: Center(
        child: Text('目标详情（开发中）：$goalId'),
      ),
    );
  }
}
