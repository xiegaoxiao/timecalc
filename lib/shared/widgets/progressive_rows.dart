import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 滚动感知的懒加载行列表（2026-08-16 目标详情卡顿修复 v2：真懒加载）。
///
/// 单卡列表行（TaskTile 自身无卡）装在 `SliverToBoxAdapter`/Column 里时，
/// Flutter 无法按视口裁剪构建——大任务量目标（批量/JSON 导入 1000+）若
/// 一次性全量 build，进入页面的首帧会卡死（实测单帧 4s+）。
///
/// 本组件在单卡视觉内实现**视口驱动的懒构建**：
/// - 初始只构建第一批（[chunkSize] 条）；
/// - 仅当「已构建的最后一行」进入其**实际所在视口** + [preloadMargin]
///   范围内（用户快滚到底了）才构建下一批——视口外的行永不构建，滚动
///   到哪建到哪；
/// - 行数 ≤ chunkSize 时行为与普通 children 列表完全一致。
///
/// 视口与滚动偏移直接取自「渲染最后一行的 RenderAbstractViewport」
/// （地面真值），而非 `Scrollable.maybeOf` 的祖先链——嵌套路由/IndexedStack
/// 场景下祖先链可能解析到别的滚动位置（pixels 恒 0、viewportDimension
/// 与实际不符，导致误判全量可见）。
///
/// 数据刷新语义：行数不变（内容更新）时已构建行立即呈现；行数增长
/// （如展开重复任务组）从当前已建数继续按需推进。
class ProgressiveRows extends StatefulWidget {
  const ProgressiveRows({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.chunkSize = 24,
    this.preloadMargin = 400,
  });

  final int itemCount;

  /// 构建第 [index] 行（分隔线等伴随元素由调用方在 builder 内一并返回）。
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// 每批最多构建的行数。
  final int chunkSize;

  /// 预构建边距（逻辑像素）：最后一行距视口底部不足该值时提前建下一批。
  /// 400 ≈ 桌面端 5-8 行前瞻，快滚顺滑且不把视口外长列表整段吃进。
  final double preloadMargin;

  @override
  State<ProgressiveRows> createState() => _ProgressiveRowsState();
}

class _ProgressiveRowsState extends State<ProgressiveRows> {
  /// 已允许构建的行数（build 中再与 itemCount 取 min 兜底收缩）。
  int _built = 0;

  /// 标记当前已构建的最后一行（测量其与视口的距离，决定是否扩展）。
  final GlobalKey _lastRowKey = GlobalKey();

  /// 监听中的滚动位置（真实渲染本列表的视口，随测量同步）。
  ScrollPosition? _offset;

  @override
  void initState() {
    super.initState();
    _built = math.min(widget.itemCount, widget.chunkSize);
    // 首帧布局后复查：高视口/矮行场景下初始一批可能填不满视口+边距。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeExtend());
  }

  @override
  void didUpdateWidget(ProgressiveRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行数变化才需要复查（内容同数刷新由行 element 自行更新）。
    if (widget.itemCount != oldWidget.itemCount) {
      _maybeExtend();
    }
  }

  @override
  void dispose() {
    _offset?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() => _maybeExtend();

  /// 最后一行是否已进入「实际视口 + 边距」范围（用户即将看到列表底部）。
  bool _shouldExtend() {
    if (_built >= widget.itemCount) return false;
    final ctx = _lastRowKey.currentContext;
    if (ctx == null) return true; // 尚未布局（首帧）：先建一批兜底。
    final lastBox = ctx.findRenderObject();
    if (lastBox is! RenderBox || !lastBox.attached) return true;
    final viewport = RenderAbstractViewport.of(lastBox);
    // 从渲染该行的视口取真实偏移（同步滚动监听到同一 offset）。
    final ViewportOffset? offset = switch (viewport) {
      final RenderViewport v => v.offset,
      final RenderShrinkWrappingViewport v => v.offset,
      _ => null,
    };
    // 视口偏移运行时为 ScrollPosition（含 pixels/viewportDimension）；
    // 未就绪（无内容维度）时不扩展，等下一帧/滚动事件再查。
    if (offset is! ScrollPosition || !offset.hasContentDimensions) {
      return false;
    }
    _syncListener(offset);
    // 让最后一行底部贴到视口底部所需的滚动偏移 ≤ 当前偏移 + 视口高 +
    // 边距 → 该行已在（或即将进入）可见范围。
    final reveal = viewport.getOffsetToReveal(lastBox, 1.0);
    return reveal.offset <=
        offset.pixels + offset.viewportDimension + widget.preloadMargin;
  }

  /// 把滚动监听挂到真实渲染本列表的视口偏移上（替换旧监听）。
  void _syncListener(ScrollPosition offset) {
    if (identical(offset, _offset)) return;
    _offset?.removeListener(_onScroll);
    _offset = offset;
    offset.addListener(_onScroll);
  }

  /// 视口需要则构建下一批；一批每帧（post-frame 复查直至填满视口+边距）。
  void _maybeExtend() {
    if (!mounted || !_shouldExtend()) return;
    setState(() {
      _built = math.min(_built + widget.chunkSize, widget.itemCount);
    });
    // 本批构建布局完成后复查（视口比一批更大时继续填充）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeExtend());
  }

  @override
  Widget build(BuildContext context) {
    final count = math.min(_built, widget.itemCount);
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          KeyedSubtree(
            key: i == count - 1 ? _lastRowKey : null,
            child: widget.itemBuilder(context, i),
          ),
      ],
    );
  }
}
