/// 备份文件类型（FR-9 数据管理）。
enum BackupType {
  /// 全量业务数据备份（当前唯一类型，FR-9.1）。
  full('full');

  const BackupType(this.value);

  final String value;

  static BackupType? fromValue(String? value) {
    for (final type in BackupType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// 恢复模式（FR-9.2：要求用户确认「合并」或「覆盖」）。
enum RestoreMode {
  /// 合并：备份数据以新 ID 追加，与当前数据共存，不触碰当前设置。
  merge,

  /// 覆盖：先自动创建当前数据安全副本（FR-9.3），再以备份数据整体替换
  /// 业务数据（settings 一并恢复）；失败回滚，原库保持可用。
  overwrite,
}

/// 备份格式标识与版本（写入 manifest.json）。
///
/// 版本用于恢复前校验：格式、版本、类型与计数全部匹配才允许恢复，
/// 不匹配时拒绝并保持原数据库不变（NFR-2）。
class BackupFormat {
  static const String format = 'timecalc-backup';
  static const int version = 1;
}

/// 备份文件清单（manifest.json 内容）。
///
/// 恢复前展示「备份时间、目标数、任务数」（FR-9.2）的数据来源。
class BackupManifest {
  const BackupManifest({
    required this.format,
    required this.version,
    required this.type,
    required this.exportedAtUtc,
    required this.appSchemaVersion,
    required this.appVersion,
    required this.goalCount,
    required this.subjectCount,
    required this.taskCount,
    required this.recurrenceTemplateCount,
    required this.milestoneCount,
    required this.checklistItemCount,
  });

  final String format;
  final int version;

  /// 备份类型；未知/非法值（未来版本或手工构造）为 null，恢复前拒绝。
  final BackupType? type;
  final DateTime? exportedAtUtc;
  final int appSchemaVersion;
  final String appVersion;
  final int goalCount;
  final int subjectCount;
  final int taskCount;
  final int recurrenceTemplateCount;
  final int milestoneCount;
  final int checklistItemCount;

  /// 校验备份文件的格式、版本与类型（恢复前第一步，NFR-2）。
  ///
  /// 不抛异常：返回失败原因文本；通过返回 null。
  String? validate() {
    if (format != BackupFormat.format) return '不是 TimeCalc 备份文件';
    if (version != BackupFormat.version) return '备份版本不受支持（$version）';
    // type 为 null（未知类型，从 JSON 解析未识别）时同样拒绝。
    if (type != BackupType.full) return '不支持的备份类型';
    // exportedAtUtc 为 null（损坏时间戳解析失败）时拒绝，而非在预览中
    // 显示误导性的「1970-01-01」。
    if (exportedAtUtc == null) return '备份时间缺失';
    if (goalCount < 0 || subjectCount < 0 || taskCount < 0 ||
        recurrenceTemplateCount < 0 || milestoneCount < 0 ||
        checklistItemCount < 0) {
      return '备份计数非法';
    }
    return null;
  }

  Map<String, Object> toJson() {
    return {
      'format': format,
      'version': version,
      // 类型未知时（仅理论上，导出端恒为 full）按 'unknown' 落盘。
      'type': type?.value ?? 'unknown',
      'exportedAtUtc': exportedAtUtc?.toUtc().toIso8601String() ?? '',
      'appSchemaVersion': appSchemaVersion,
      'appVersion': appVersion,
      'counts': {
        'goals': goalCount,
        'subjects': subjectCount,
        'tasks': taskCount,
        'recurrenceTemplates': recurrenceTemplateCount,
        'milestones': milestoneCount,
        'checklistItems': checklistItemCount,
      },
    };
  }

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    // 类型判定替代 `as` 强转：备份是外部输入，字段类型损坏（如 counts 为
    // 数组、exportedAtUtc/type 为数字）时 `as Map?/as String?` 会抛 TypeError
    // （Error 而非 Exception），逃出 UI 的 `on Exception` 兜底 → 恢复预览静默失败。
    final rawCounts = json['counts'];
    final counts = rawCounts is Map<String, Object?>
        ? rawCounts
        : const <String, Object?>{};
    final rawExportedAtUtc = json['exportedAtUtc'];
    final exported = DateTime.tryParse(
      rawExportedAtUtc is String ? rawExportedAtUtc : '',
    );
    final rawFormat = json['format'];
    final rawType = json['type'];
    final rawAppVersion = json['appVersion'];
    return BackupManifest(
      format: rawFormat is String ? rawFormat : '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      type: BackupType.fromValue(rawType is String ? rawType : null),
      exportedAtUtc: exported,
      appSchemaVersion: (json['appSchemaVersion'] as num?)?.toInt() ?? 0,
      appVersion: rawAppVersion is String ? rawAppVersion : '',
      goalCount: (counts['goals'] as num?)?.toInt() ?? 0,
      subjectCount: (counts['subjects'] as num?)?.toInt() ?? 0,
      taskCount: (counts['tasks'] as num?)?.toInt() ?? 0,
      recurrenceTemplateCount:
          (counts['recurrenceTemplates'] as num?)?.toInt() ?? 0,
      milestoneCount: (counts['milestones'] as num?)?.toInt() ?? 0,
      checklistItemCount: (counts['checklistItems'] as num?)?.toInt() ?? 0,
    );
  }
}
