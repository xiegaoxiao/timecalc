import 'package:flutter/material.dart';

/// 统一区块头：主色图标（20px）+ 标题 + 可选副标题 + 可选右侧内容。
///
/// 进度页等统计区块共用（M13 从 progress_page 公有化）：
/// 图标点出区块语义、标题承载主信息、副标题承载白话说明，trailing
/// 放关键数字或操作。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }
}
