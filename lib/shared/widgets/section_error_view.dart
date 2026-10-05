import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'clash_tones.dart';

/// 区块级读取失败提示条（局部错误，替代整页 [AppErrorView]）。
///
/// 「页面内某一块加载失败」不打断整页可用内容：错误文案 + 重试按钮，
/// 走危险撞色（PRD §8 异常状态；NFR-4 不只依赖颜色——图标 + 文案 +
/// 动作三者齐备）。
///
/// 今日页与日历原先各有一份近似实现（圆角/间距/描边已分叉），此处收敛为
/// 单一来源，避免两处版式继续漂移。
class SectionErrorView extends StatelessWidget {
  const SectionErrorView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final Object error;

  /// 重试回调（通常 invalidate 对应 Provider 重新加载）。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final danger = ClashTones.of(context, ClashTone.danger);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceMd,
        vertical: AppTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: danger.soft,
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        border: Border.all(color: ClashTones.tint(danger.ink, alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: danger.ink),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Text(
              '$error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: danger.onSoft, fontSize: 12),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
