import 'package:drift/drift.dart';

import '../../../../core/database/database.dart';

/// 备份数据编解码：drift 行 ↔ 平铺 JSON map。
///
/// 备份文件内的业务数据以 JSON 数组存储（`data/goals.json` 等），
/// 字段名与 drift 数据类一致（camelCase）。日期遵循 PRD §9：
/// 时间戳（createdAt/updatedAt/completedAt/archivedAt）以 UTC ISO 8601
/// 存储，计划日期（plannedDate/deadlineDate/startDate/endDate 等）以
/// `yyyy-MM-dd` 文本原样保存。
///
/// [BackupCodec] 不关心 ID 是否复用：合并模式插入前清空 id 字段让数据库
/// 分配新 ID；覆盖模式保留原 ID 以还原完全一致的数据。
class BackupCodec {
  const BackupCodec();

  /// 目标行 → JSON。
  Map<String, Object?> goalToJson(Goal row) => {
        'id': row.id,
        'title': row.title,
        'description': row.description,
        'deadlineDate': row.deadlineDate,
        'status': row.status,
        'completedAt': row.completedAt?.toUtc().toIso8601String(),
        'createdAt': row.createdAt.toUtc().toIso8601String(),
        'updatedAt': row.updatedAt.toUtc().toIso8601String(),
      };

  /// 科目行 → JSON。
  Map<String, Object?> subjectToJson(Subject row) => {
        'id': row.id,
        'goalId': row.goalId,
        'name': row.name,
        'color': row.color,
        'sortOrder': row.sortOrder,
        'createdAt': row.createdAt.toUtc().toIso8601String(),
        'updatedAt': row.updatedAt.toUtc().toIso8601String(),
      };

  /// 任务行 → JSON（含归档任务：备份包含全部业务数据，FR-9.1）。
  Map<String, Object?> taskToJson(Task row) => {
        'id': row.id,
        'goalId': row.goalId,
        'subjectId': row.subjectId,
        'title': row.title,
        'note': row.note,
        'plannedDate': row.plannedDate,
        'estimatedMinutes': row.estimatedMinutes,
        'status': row.status,
        'completedAt': row.completedAt?.toUtc().toIso8601String(),
        'sortOrder': row.sortOrder,
        'createdAt': row.createdAt.toUtc().toIso8601String(),
        'updatedAt': row.updatedAt.toUtc().toIso8601String(),
        'originalPlannedDate': row.originalPlannedDate,
        'archivedAt': row.archivedAt?.toUtc().toIso8601String(),
        'recurrenceTemplateId': row.recurrenceTemplateId,
      };

  /// 重复模板行 → JSON。
  Map<String, Object?> templateToJson(RecurrenceTemplate row) => {
        'id': row.id,
        'goalId': row.goalId,
        'subjectId': row.subjectId,
        'title': row.title,
        'estimatedMinutes': row.estimatedMinutes,
        'ruleType': row.ruleType,
        'ruleJson': row.ruleJson,
        'startDate': row.startDate,
        'endDate': row.endDate,
        'active': row.active,
        'generatedThroughDate': row.generatedThroughDate,
        'createdAt': row.createdAt.toUtc().toIso8601String(),
        'updatedAt': row.updatedAt.toUtc().toIso8601String(),
        'deletedInstanceDates': row.deletedInstanceDates,
      };

  /// 计划偏好行 → JSON。
  ///
  /// 只包含计划偏好（FR-9.5：窗口状态/关闭行为等桌面层状态不进入业务
  /// 备份；API Key 与日志本就不存于本表）。
  Map<String, Object?> settingsToJson(Setting row) => {
        'dailyAvailableMinutes': row.dailyAvailableMinutes,
        'availableWeekdays': row.availableWeekdays,
      };

  /// 里程碑行 → JSON（FR-2，schema v7）。
  Map<String, Object?> milestoneToJson(Milestone row) => {
        'id': row.id,
        'goalId': row.goalId,
        'title': row.title,
        'date': row.date,
        'status': row.status,
        'sortOrder': row.sortOrder,
        'createdAt': row.createdAt.toUtc().toIso8601String(),
        'updatedAt': row.updatedAt.toUtc().toIso8601String(),
      };

  /// 检查项行 → JSON（FR-4.1，schema v8）。
  Map<String, Object?> checklistItemToJson(ChecklistItem row) => {
        'id': row.id,
        'taskId': row.taskId,
        'title': row.title,
        'done': row.done,
        'sortOrder': row.sortOrder,
        'createdAt': row.createdAt.toUtc().toIso8601String(),
        'updatedAt': row.updatedAt.toUtc().toIso8601String(),
      };

  /// JSON → GoalsCompanion（[keepId] 为 true 时保留原 id 供覆盖恢复）。
  GoalsCompanion goalFromJson(Map<String, Object?> json, {bool keepId = false}) {
    final now = DateTime.now().toUtc();
    return GoalsCompanion.insert(
      id: keepId ? Value(json['id'] as int) : const Value.absent(),
      title: json['title'] as String,
      description: Value(json['description'] as String?),
      deadlineDate: json['deadlineDate'] as String,
      status: Value(json['status'] as String? ?? 'active'),
      completedAt: Value(
        json['completedAt'] == null
            ? null
            : DateTime.parse(json['completedAt'] as String).toUtc(),
      ),
      createdAt: _parseUtc(json['createdAt']) ?? now,
      updatedAt: _parseUtc(json['updatedAt']) ?? now,
    );
  }

  /// JSON → SubjectsCompanion。
  SubjectsCompanion subjectFromJson(
    Map<String, Object?> json, {
    required int goalId,
    bool keepId = false,
  }) {
    final now = DateTime.now().toUtc();
    return SubjectsCompanion.insert(
      id: keepId ? Value(json['id'] as int) : const Value.absent(),
      goalId: goalId,
      name: json['name'] as String,
      color: json['color'] as String? ?? '#3F6C51',
      sortOrder: Value(json['sortOrder'] as int? ?? 0),
      createdAt: _parseUtc(json['createdAt']) ?? now,
      updatedAt: _parseUtc(json['updatedAt']) ?? now,
    );
  }

  /// JSON → TasksCompanion。
  TasksCompanion taskFromJson(
    Map<String, Object?> json, {
    required int goalId,
    int? subjectId,
    int? recurrenceTemplateId,
    bool keepId = false,
  }) {
    final now = DateTime.now().toUtc();
    return TasksCompanion.insert(
      id: keepId ? Value(json['id'] as int) : const Value.absent(),
      goalId: goalId,
      subjectId: Value(subjectId),
      title: json['title'] as String,
      note: Value(json['note'] as String?),
      plannedDate: json['plannedDate'] as String,
      estimatedMinutes: Value(json['estimatedMinutes'] as int?),
      status: Value(json['status'] as String? ?? 'todo'),
      completedAt: Value(
        json['completedAt'] == null
            ? null
            : DateTime.parse(json['completedAt'] as String).toUtc(),
      ),
      sortOrder: Value(json['sortOrder'] as int? ?? 0),
      createdAt: _parseUtc(json['createdAt']) ?? now,
      updatedAt: _parseUtc(json['updatedAt']) ?? now,
      originalPlannedDate: Value(json['originalPlannedDate'] as String?),
      archivedAt: Value(
        json['archivedAt'] == null
            ? null
            : DateTime.parse(json['archivedAt'] as String).toUtc(),
      ),
      recurrenceTemplateId: Value(recurrenceTemplateId),
    );
  }

  /// JSON → RecurrenceTemplatesCompanion。
  RecurrenceTemplatesCompanion templateFromJson(
    Map<String, Object?> json, {
    required int goalId,
    int? subjectId,
    bool keepId = false,
  }) {
    final now = DateTime.now().toUtc();
    return RecurrenceTemplatesCompanion.insert(
      id: keepId ? Value(json['id'] as int) : const Value.absent(),
      goalId: goalId,
      subjectId: Value(subjectId),
      title: json['title'] as String,
      estimatedMinutes: Value(json['estimatedMinutes'] as int?),
      ruleType: json['ruleType'] as String? ?? 'daily',
      ruleJson: json['ruleJson'] as String? ?? '{}',
      startDate: json['startDate'] as String,
      endDate: Value(json['endDate'] as String?),
      active: Value(json['active'] as bool? ?? true),
      generatedThroughDate: json['generatedThroughDate'] as String? ?? '',
      createdAt: _parseUtc(json['createdAt']) ?? now,
      updatedAt: _parseUtc(json['updatedAt']) ?? now,
      deletedInstanceDates: Value(json['deletedInstanceDates'] as String?),
    );
  }

  /// JSON → SettingsCompanion（仅计划偏好；运行时配置默认 null）。
  ///
  /// 备份文件按 FR-9.5 不包含运行时配置（close_behavior、自动备份配置），
  /// 因此恢复时这些字段由调用方决定：null 表示「覆盖恢复保留当前值」
  /// （见 BackupService._overwriteRestore）。
  SettingsCompanion settingsFromJson(
    Map<String, Object?> json, {
    String? closeBehavior,
    bool? autoBackupEnabled,
    String? localBackupFolder,
    String? webdavUrl,
    String? webdavUsername,
    bool? webdavPasswordSaved,
    DateTime? lastAutoBackupAt,
  }) {
    final now = DateTime.now().toUtc();
    return SettingsCompanion.insert(
      id: const Value(1),
      dailyAvailableMinutes:
          Value(json['dailyAvailableMinutes'] as int? ?? 120),
      availableWeekdays: Value(
        json['availableWeekdays'] as String? ?? '1,2,3,4,5,6,7',
      ),
      closeBehavior: closeBehavior == null
          ? const Value.absent()
          : Value(closeBehavior),
      autoBackupEnabled: autoBackupEnabled == null
          ? const Value.absent()
          : Value(autoBackupEnabled),
      localBackupFolder: localBackupFolder == null
          ? const Value.absent()
          : Value(localBackupFolder),
      webdavUrl: webdavUrl == null
          ? const Value.absent()
          : Value(webdavUrl),
      webdavUsername: webdavUsername == null
          ? const Value.absent()
          : Value(webdavUsername),
      webdavPasswordSaved: webdavPasswordSaved == null
          ? const Value.absent()
          : Value(webdavPasswordSaved),
      lastAutoBackupAt: lastAutoBackupAt == null
          ? const Value.absent()
          : Value(lastAutoBackupAt),
      createdAt: now,
      updatedAt: now,
    );
  }

  /// JSON → MilestonesCompanion（FR-2，schema v7）。
  MilestonesCompanion milestoneFromJson(
    Map<String, Object?> json, {
    required int goalId,
    bool keepId = false,
  }) {
    final now = DateTime.now().toUtc();
    return MilestonesCompanion.insert(
      id: keepId ? Value(json['id'] as int) : const Value.absent(),
      goalId: goalId,
      title: json['title'] as String,
      date: json['date'] as String,
      status: Value(json['status'] as String? ?? 'todo'),
      sortOrder: Value(json['sortOrder'] as int? ?? 0),
      createdAt: _parseUtc(json['createdAt']) ?? now,
      updatedAt: _parseUtc(json['updatedAt']) ?? now,
    );
  }

  /// JSON → ChecklistItemsCompanion（FR-4.1，schema v8）。
  ///
  /// [taskId] 为恢复时经外键映射转换后的新任务 id（备份 JSON 存旧 id）。
  ChecklistItemsCompanion checklistItemFromJson(
    Map<String, Object?> json, {
    required int taskId,
    bool keepId = false,
  }) {
    final now = DateTime.now().toUtc();
    return ChecklistItemsCompanion.insert(
      id: keepId ? Value(json['id'] as int) : const Value.absent(),
      taskId: taskId,
      title: json['title'] as String,
      done: Value(json['done'] as bool? ?? false),
      sortOrder: Value(json['sortOrder'] as int? ?? 0),
      createdAt: _parseUtc(json['createdAt']) ?? now,
      updatedAt: _parseUtc(json['updatedAt']) ?? now,
    );
  }

  static DateTime? _parseUtc(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value as String);
    return parsed?.toUtc();
  }
}
