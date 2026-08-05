import 'package:flutter/material.dart';

/// 今天页：M1 骨架占位，M2 交付「查看今日任务 → 完成/延期」闭环。
class TodayPage extends StatelessWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('今天')),
      body: const Center(
        child: Text('今天页（M2 开发中）'),
      ),
    );
  }
}
