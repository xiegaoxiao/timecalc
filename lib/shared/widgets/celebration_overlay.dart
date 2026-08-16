import 'dart:async';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';

/// 达成庆祝彩带（v1.11 动效升级）：今日任务全部完成时在 Overlay 层
/// 播一次爆炸式彩带（低频、克制，不重复触发骚扰）。
///
/// 用法：[showCelebration] 插入 OverlayEntry，约 4 秒后自动移除；
/// 彩带本身 IgnorePointer，不拦截任何交互。移除定时器由 overlay 自身
/// 持有并在 dispose 时取消——避免页面销毁后遗留 pending Timer
/// （widget 测试会因 pending timer 失败）。
void showCelebration(BuildContext context) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _CelebrationOverlay(onFinished: () {
      if (entry.mounted) entry.remove();
    }),
  );
  overlay.insert(entry);
}

class _CelebrationOverlay extends StatefulWidget {
  const _CelebrationOverlay({required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<_CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends State<_CelebrationOverlay>
    with SingleTickerProviderStateMixin {
  late final ConfettiController _controller;
  Timer? _autoRemove;

  @override
  void initState() {
    super.initState();
    _controller = ConfettiController(duration: const Duration(seconds: 3))
      ..play();
    _autoRemove = Timer(const Duration(seconds: 4), widget.onFinished);
  }

  @override
  void dispose() {
    _autoRemove?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        // RepaintBoundary（2026-08-16 动画流畅度优化）：彩带逐帧重绘被
        // 限制在独立图层，不再把整个窗口的内容拖进同一帧光栅化——
        // 全部完成庆祝恰好与定稿刷新同帧叠加，是此前最明显的掉帧场景。
        child: RepaintBoundary(
          child: ConfettiWidget(
            confettiController: _controller,
            blastDirectionality: BlastDirectionality.explosive,
            // 40 粒在视觉上依然饱满，Windows 光栅化成本约降三分之一。
            numberOfParticles: 40,
            gravity: 0.3,
            shouldLoop: false,
          ),
        ),
      ),
    );
  }
}
