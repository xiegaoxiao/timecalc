import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';

/// 达成庆祝彩带（v1.11 动效升级）：今日任务全部完成时在 Overlay 层
/// 播一次爆炸式彩带（低频、克制，不重复触发骚扰）。
///
/// 用法：[showCelebration] 插入 OverlayEntry，约 4 秒后自动移除；
/// 彩带本身 IgnorePointer，不拦截任何交互。
void showCelebration(BuildContext context) {
  final overlay = Overlay.of(context);
  final entry = OverlayEntry(
    builder: (_) => const _CelebrationOverlay(),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(seconds: 4), () {
    if (entry.mounted) entry.remove();
  });
}

class _CelebrationOverlay extends StatefulWidget {
  const _CelebrationOverlay();

  @override
  State<_CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends State<_CelebrationOverlay>
    with SingleTickerProviderStateMixin {
  late final ConfettiController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConfettiController(duration: const Duration(seconds: 3))
      ..play();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ConfettiWidget(
          confettiController: _controller,
          blastDirectionality: BlastDirectionality.explosive,
          numberOfParticles: 60,
          gravity: 0.3,
          shouldLoop: false,
        ),
      ),
    );
  }
}
