import 'package:flutter/material.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/utils/date_text.dart';

/// 里程碑卡片（2026-08-18 从 MilestoneSection 提取复用）：纯展示，
/// 操作（编辑/勾选完成/删除）由回调注入，供详情页与全部里程碑页共用。
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
    final scheme = Theme.of(context).colorScheme;
    final date = parseLocalDate(milestone.date);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Checkbox(
          value: done,
          // NFR-4：完成状态不只依赖颜色（划线 + Checkbox）。
          semanticLabel: '标记里程碑「${milestone.title}」为${done ? '未完成' : '已完成'}',
          onChanged: (_) => onToggleDone(),
        ),
        title: Text(
          milestone.title,
          style: done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: scheme.outline,
                )
              : null,
        ),
        subtitle: Text(
          '${formatLocalDate(date)}'
          '${done ? ' · 已完成' : ''}',
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
    );
  }
}
