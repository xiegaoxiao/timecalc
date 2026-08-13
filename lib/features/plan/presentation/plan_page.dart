import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'calendar_view.dart';

/// 计划页（v1.12）：纯日历视图。
///
/// v1.11 及之前为「日历 / 目标」分段；v1.12 将目标拆分为独立一级导航
/// （底部导航「目标」进入目标页），计划页退化为专注月历负载与选日任务
/// 的纯日历页（FR-3.4 / FR-3.2 / FR-3.6）。「创建目标」与「导入完整计划」
/// 入口均迁至目标页。
class PlanPage extends ConsumerWidget {
  const PlanPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('计划')),
      body: const CalendarView(),
    );
  }
}
