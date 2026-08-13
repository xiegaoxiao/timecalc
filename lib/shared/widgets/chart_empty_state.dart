import 'package:flutter/material.dart';

/// 统一空态：主色容器圆底图标 + 主文案 + bodySmall 副文案 + 可选 CTA。
///
/// 进度页图表空态（M13 从 progress_page 公有化；v1.11 视觉升级为
/// shadcn 风格「主色通明圆底图标」）。副文案承载引导，CTA 提供 PRD §8
/// 要求的「首个操作」；无 CTA 时纯展示。
class ChartEmptyState extends StatelessWidget {
  const ChartEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.caption,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;

  /// 可选副文案（引导说明）。
  final String? caption;

  /// 可选的「首个操作」按钮文案（空态应提供与页面相关的操作，PRD §8）。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          // 主色通明圆底图标：克制点缀，替代裸 outline 图标。
          // 高度与原版（40px 图标 + 8px 间距）完全一致，避免长页面
          // 中被推离 CustomScrollView 懒构建窗口。
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: scheme.primary),
          ),
          const SizedBox(height: 8),
          Text(title),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(caption!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            // 低关注度引导按钮（主色通明描边），引导用户去有数据而不是干等。
            OutlinedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
