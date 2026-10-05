import 'package:flutter/material.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/theme/app_semantic_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/completion_checkbox.dart';

/// 里程碑卡片（2026-08-18 从 MilestoneSection 提取复用）：纯展示，
/// 操作（编辑/勾选完成/删除）由回调注入，供详情页与全部里程碑页共用。
///
/// v2.0 撞色：里程碑 = **点缀撞色（citrus）**——图标底/徽标取暖色系的
/// 青柠强调；**完成态**改用语义 `success` 系列（绿），与「成就达成」的
/// 通用约定一致。左侧淡色竖条是里程碑序列的**时间线轴**（点缀色淡色）。
class MilestoneCard extends StatelessWidget {
  const MilestoneCard({
    super.key,
    required this.milestone,
    required this.onEdit,
    required this.onToggleDone,
    required this.onDelete,
  });

  final Milestone milestone;
  final VoidCallback onEdit;
  final VoidCallback onToggleDone;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final done = milestone.status == MilestoneStatus.done;
    final date = parseLocalDate(milestone.date);
    // 点缀撞色（未完成）↔ 语义成功色（已完成）。
    final citrus = ClashTones.of(context, ClashTone.citrus);
    final semantic = AppSemanticColors.of(context);
    final accent = done ? semantic.success : citrus.ink;
    final accentSoft = done ? semantic.successContainer : citrus.soft;
    final onAccentSoft = done ? semantic.onSuccessContainer : citrus.onSoft;

    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      child: Stack(
        children: [
          // 时间线连接线：点缀色淡色（完成态跟随 success 淡色）。
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(
              color: ClashTones.tint(accent, alpha: 0.35),
            ),
          ),
          ListTile(
            leading: CompletionCheckbox(
              value: done,
              // NFR-4：完成状态不只依赖颜色（划线 + Checkbox）。
              semanticLabel:
                  '标记里程碑「${milestone.title}」为${done ? '未完成' : '已完成'}',
              onChanged: (_) => onToggleDone(),
            ),
            title: Row(
              children: [
                // 点缀撞色图标底（完成态切 success 容器）。
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: accentSoft,
                    borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  ),
                  child: Icon(
                    done ? Icons.emoji_events : Icons.flag_outlined,
                    size: 14,
                    color: onAccentSoft,
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Flexible(
                  child: Text(
                    milestone.title,
                    style: done
                        ? TextStyle(
                            decoration: TextDecoration.lineThrough,
                            color: accent,
                          )
                        : null,
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${formatLocalDate(date)}'
              '${done ? ' · 已完成' : ''}',
              style: done ? TextStyle(color: accent) : null,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '编辑里程碑「${milestone.title}」',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEdit,
                ),
                PopupMenuButton<String>(
                  tooltip: '里程碑操作',
                  onSelected: (action) {
                    if (action == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
