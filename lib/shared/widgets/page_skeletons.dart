import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/theme/app_tokens.dart';

/// 加载骨架屏（v1.11 动效升级）：首载/换参期间用骨架占位替代纯转圈，
/// 消除 spinner 闪烁、观感更专业。基于 skeletonizer 包：把真实卡片结构
/// 的文字/图标渲染为流动灰块，加载完成后自然过渡到真实内容。
///
/// 使用方在对应页面的首载分支（原 `CircularProgressIndicator`）替换为
/// 具体骨架组件即可；骨架仅存续于数据未就绪的极短窗口，卸载即停。
abstract final class PageSkeletons {
  /// 通用卡片列骨架（**非滚动**，Column）：n 张卡片（高度可配）。
  /// 用于嵌在页面滚动容器内的区块首载（如日历页的月历/选日面板）。
  static Widget cardColumn({int count = 4, double height = 120}) {
    return Skeletonizer(
      child: Column(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Container(
                height: height,
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                child: const Text('骨架卡片占位'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 通用卡片列表骨架：n 张卡片（高度可配），用于今天/计划/设置等
  /// 以卡片列表为主体的页面首载。
  static Widget cardList({int count = 4, double height = 120}) {
    return Skeletonizer(
      child: ListView.separated(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, _) => Card(
          margin: EdgeInsets.zero,
          child: Container(
            height: height,
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: const Text('骨架卡片占位'),
          ),
        ),
      ),
    );
  }

  /// 进度页骨架：概览卡 + 三个图表区块卡（高卡），匹配进度页纵向结构。
  static Widget progressPage() {
    return Skeletonizer(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          const _SkeletonCard(height: 56),
          const SizedBox(height: 8),
          const _SkeletonCard(height: 200),
          const SizedBox(height: 8),
          const _SkeletonCard(height: 160),
          const SizedBox(height: 8),
          const _SkeletonCard(height: 200),
          const SizedBox(height: 8),
          const _SkeletonCard(height: 40),
        ],
      ),
    );
  }

  /// 今天页骨架：倒计时 hero 卡 + 概览卡 + 任务行，匹配今天页纵向结构。
  static Widget todayPage() {
    return Skeletonizer(
      child: ListView(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        children: const [
          _SkeletonCard(height: 180, radius: 16),
          SizedBox(height: 8),
          _SkeletonCard(height: 96),
          SizedBox(height: 8),
          _SkeletonCard(height: 56),
          SizedBox(height: 8),
          _SkeletonCard(height: 56),
          SizedBox(height: 8),
          _SkeletonCard(height: 56),
        ],
      ),
    );
  }
}

/// 骨架卡片：固定高度 + 内嵌占位文字（skeletonizer 渲染为灰块）。
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.height, this.radius});

  final double height;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.titleMedium ?? const TextStyle();
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius ?? AppTokens.radiusXl),
      ),
      child: Container(
        height: height,
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Text('加载中', style: text),
      ),
    );
  }
}
