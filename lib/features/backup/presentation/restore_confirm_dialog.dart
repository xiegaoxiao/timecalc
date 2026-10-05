import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/widgets/clash_tones.dart';
import '../data/backup_manifest.dart';

/// 恢复确认对话框结果：用户选择的恢复模式，或 null（取消）。
class RestoreChoice {
  const RestoreChoice(this.mode);

  final RestoreMode mode;
}

/// 恢复确认对话框（FR-9.2）。
///
/// 展示备份时间、目标数与任务数，并要求确认「合并」或「覆盖」。
/// 覆盖模式额外说明将自动创建当前数据的安全副本（FR-9.3）。
class RestoreConfirmDialog extends StatelessWidget {
  const RestoreConfirmDialog({super.key, required this.manifest});

  final BackupManifest manifest;

  /// 弹出恢复确认对话框；用户选择模式或取消。
  static Future<RestoreChoice?> show(
    BuildContext context,
    BackupManifest manifest,
  ) {
    return showDialog<RestoreChoice>(
      context: context,
      builder: (_) => RestoreConfirmDialog(manifest: manifest),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 覆盖恢复是危险动作（替换全部业务数据）：统一走 ClashTone.danger；
    // 合并恢复是相对安全的冷色动作。
    final danger = ClashTones.of(context, ClashTone.danger);
    final cool = ClashTones.of(context, ClashTone.cool);
    final backupTime = manifest.exportedAtUtc?.toLocal();
    return AlertDialog(
      icon: Icon(Icons.settings_backup_restore, color: cool.ink),
      title: const Text('从备份恢复'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('恢复前请确认备份信息：'),
          const SizedBox(height: 12),
          _InfoRow(
            label: '备份时间',
            value: backupTime == null
                ? '未知'
                : DateFormat('yyyy-MM-dd HH:mm').format(backupTime),
          ),
          _InfoRow(label: '目标数', value: '${manifest.goalCount}'),
          _InfoRow(label: '任务数', value: '${manifest.taskCount}'),
          _InfoRow(label: '里程碑', value: '${manifest.milestoneCount}'),
          // 课程数（FR-10，v17 起）：旧版本备份没有该字段，恒为 0，
          // 此时不显示以免误导（「0 门课程」会让人以为备份里的课表丢了）。
          if (manifest.courseCount > 0 || manifest.appSchemaVersion >= 17)
            _InfoRow(label: '课程数', value: '${manifest.courseCount}'),
          Divider(height: 24, color: scheme.outlineVariant),
          const Text('请选择恢复方式：'),
          const SizedBox(height: 8),
          _ModeTile(
            title: '合并',
            description: '备份数据追加到当前计划，不覆盖现有数据',
            icon: Icons.merge_type,
            iconColor: cool.ink,
          ),
          const SizedBox(height: 4),
          _ModeTile(
            title: '覆盖',
            description: '用备份数据替换全部业务数据；覆盖前自动创建当前数据的安全副本',
            icon: Icons.file_download_done_outlined,
            iconColor: danger.ink,
            descriptionColor: danger.ink,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: () =>
              Navigator.of(context).pop(const RestoreChoice(RestoreMode.merge)),
          child: const Text('合并恢复'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: danger.fill,
            foregroundColor: danger.onFill,
          ),
          onPressed: () => Navigator.of(context)
              .pop(const RestoreChoice(RestoreMode.overwrite)),
          child: const Text('覆盖恢复'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.title,
    required this.description,
    required this.icon,
    this.iconColor,
    this.descriptionColor,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color? iconColor;
  final Color? descriptionColor;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      subtitle: Text(
        description,
        style: descriptionColor == null
            ? null
            : TextStyle(color: descriptionColor),
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
