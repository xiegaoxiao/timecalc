import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 渐进构建的行列表（2026-08-16 目标详情导航卡顿修复）。
///
/// 单卡列表行（TaskTile 自身无卡）装在 `SliverToBoxAdapter` 里时，会被
/// 视口 cacheExtent 触碰而**一次性构建全部行**——大任务量目标（批量/
/// JSON 导入 1000+）在进入页面的首帧全量 build + layout，实测单帧 4s+
/// （debug），表现为「点卡片进详情明显卡一下」。
///
/// 本组件把行构建切成每帧 [chunkSize] 条：首帧只建第一批，其余经
/// post-frame 回调逐帧补齐——单帧构建成本恒定，进入/展开不因超帧掉卡；
/// 行数 ≤ chunkSize 时行为与普通 children 列表完全一致（无额外帧）。
///
/// 数据刷新语义：行数不变（内容更新）时已构建的行立即呈现，不逐块
/// 闪现；行数增长（如展开重复任务组）时从当前已建数继续按块推进。
class ProgressiveRows extends StatefulWidget {
  const ProgressiveRows({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.chunkSize = 24,
  });

  final int itemCount;

  /// 构建第 [index] 行（分隔线等伴随元素由调用方在 builder 内一并返回）。
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// 每帧最多构建的行数。
  final int chunkSize;

  @override
  State<ProgressiveRows> createState() => _ProgressiveRowsState();
}

class _ProgressiveRowsState extends State<ProgressiveRows> {
  /// 已允许构建的行数（build 中再与 itemCount 取 min 兜底收缩）。
  int _built = 0;

  @override
  void initState() {
    super.initState();
    _built = math.min(widget.itemCount, widget.chunkSize);
    _scheduleNext();
  }

  @override
  void didUpdateWidget(ProgressiveRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行数变化才需要推进（内容同数刷新由行 element 自行更新，无需分块）。
    if (widget.itemCount != oldWidget.itemCount) {
      _scheduleNext();
    }
  }

  /// 当前帧结束后补下一块（有剩余且仍在树中才调度）。
  void _scheduleNext() {
    if (!mounted || _built >= widget.itemCount) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _built >= widget.itemCount) return;
      setState(() {
        _built = math.min(_built + widget.chunkSize, widget.itemCount);
      });
      _scheduleNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = math.min(_built, widget.itemCount);
    return Column(
      children: [
        for (var i = 0; i < count; i++) widget.itemBuilder(context, i),
      ],
    );
  }
}
