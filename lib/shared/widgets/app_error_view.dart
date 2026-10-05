import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'clash_tones.dart';
import 'clash_widgets.dart';

/// 读取失败统一错误视图（PRD §8：数据库异常提示，NFR-4）。
///
/// 替代各页裸 `Text('加载失败：$error')`：图标 + 错误消息 + **重试**按钮。
/// v2.0 撞色重构改用 [ClashEmptyState]（`ClashTone.danger`）承载，
/// 与全站空态同一套版式（撞色圆底图标 + 主文案 + 说明 + 动作）。
///
/// [onRetry] 由调用方注入（通常 invalidate 对应 Provider 重新加载）；
/// 为空时不展示重试按钮（如内嵌区块，重试语义由页面级兜底承担）。
class AppErrorView extends ConsumerWidget {
  const AppErrorView({
    super.key,
    required this.error,
    this.onRetry,
  });

  final Object error;

  /// 重试回调（为空则不展示重试按钮）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClashEmptyState(
      icon: Icons.error_outline,
      title: '加载失败',
      message: '$error',
      tone: ClashTone.danger,
      action: onRetry == null
          ? null
          : OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
    );
  }
}
