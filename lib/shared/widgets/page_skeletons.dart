import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// 加载骨架屏（v1.11 动效升级，v2.0 统一静态灰块）：首载/换参期间用骨架
/// 占位替代纯转圈，消除 spinner 闪烁、观感更专业。
///
/// 骨架一律为**静态灰块**（同文件 [_SkeletonBlock]），不再用 shimmer 流动
/// 动画：shimmer 与页面过渡动画叠加是 Windows 桌面进入卡顿的实测元凶
/// （详见 [PageSkeletons.goalDetailPage] 的注释）。
///
/// 使用方在对应页面的首载分支（原 `CircularProgressIndicator`）替换为
/// 具体骨架组件即可；骨架仅存续于数据未就绪的极短窗口，卸载即停。
abstract final class PageSkeletons {
  /// 通用卡片列骨架（**非滚动**，Column）：n 张灰块（高度可配）。
  /// 用于嵌在页面滚动容器内的区块首载（如日历页的月历/选日面板）。
  static Widget cardColumn({int count = 4, double height = 120}) {
    return Column(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _SkeletonBlock(height: height),
        ],
      ],
    );
  }

  /// 通用卡片列表骨架：n 张灰块（高度可配），用于今天/计划/设置等
  /// 以卡片列表为主体的页面首载。
  static Widget cardList({int count = 4, double height = 120}) {
    return ListView.separated(
      padding: const EdgeInsets.all(AppTokens.pagePadding),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, _) => _SkeletonBlock(height: height),
    );
  }

  /// 进度页骨架：概览卡 + 三个图表区块卡（高卡），匹配进度页纵向结构。
  static Widget progressPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        const _SkeletonBlock(height: 56),
        const SizedBox(height: 8),
        const _SkeletonBlock(height: 200),
        const SizedBox(height: 8),
        const _SkeletonBlock(height: 160),
        const SizedBox(height: 8),
        const _SkeletonBlock(height: 200),
        const SizedBox(height: 8),
        const _SkeletonBlock(height: 40),
      ],
    );
  }

  /// 今天页骨架：倒计时 hero 卡 + 概览卡 + 任务行，匹配今天页纵向结构。
  static Widget todayPage() {
    return ListView(
      padding: const EdgeInsets.all(AppTokens.pagePadding),
      children: const [
        _SkeletonBlock(height: 180, radius: AppTokens.radiusXl),
        SizedBox(height: 8),
        _SkeletonBlock(height: 96),
        SizedBox(height: 8),
        _SkeletonBlock(height: 56),
        SizedBox(height: 8),
        _SkeletonBlock(height: 56),
        SizedBox(height: 8),
        _SkeletonBlock(height: 56),
      ],
    );
  }

  /// 目标详情页骨架：渐变 hero 头卡 + 负载卡 + 里程碑/科目/任务行。
  ///
  /// 匹配详情页纵向结构（头部 hero → 负载 → 里程碑 → 科目 → 任务区），
  /// 点击卡片进入详情页的首载窗口用骨架占位替代纯转圈，数据到达后自然
  /// 过渡。
  ///
  /// 注意：**不用 shimmer 流动动画**——shimmer 动画与页面过渡动画
  /// 叠加是 Windows 桌面进入卡顿的实测元凶（详情页已改为「数据先到再
  /// 导航」+ 150ms 轻过渡，骨架仅作超慢库的兜底，静态灰块足够）。
  /// 2026-10 起其余四个骨架也统一为此做法。
  static Widget goalDetailPage() {
    return ListView(
      padding: const EdgeInsets.all(AppTokens.pagePadding),
      children: const [
        _SkeletonBlock(height: 140, radius: AppTokens.radiusXl),
        SizedBox(height: 16),
        _SkeletonBlock(height: 96),
        SizedBox(height: 8),
        _SkeletonBlock(height: 56),
        SizedBox(height: 8),
        _SkeletonBlock(height: 56),
        SizedBox(height: 8),
        _SkeletonBlock(height: 56),
      ],
    );
  }
}

/// 静态骨架块：固定高度圆角灰块，**无动画**（区别于 shimmer 骨架）。
///
/// 用于「过渡动画进行中」的首载兜底：动画叠加是桌面端掉帧/卡顿的元凶，
/// 静态灰块让 UI 线程专注过渡本身。
class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({required this.height, this.radius});

  final double height;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      decoration: BoxDecoration(
        // 骨架底色统一走 scheme.surfaceContainer（暖调次级底），
        // 与卡片底色形成「白卡浮于暖底」的同一层次，不再是冷灰块。
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(radius ?? AppTokens.radiusXl),
      ),
    );
  }
}
