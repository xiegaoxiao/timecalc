import 'package:drift/drift.dart';

/// TimeCalc 数据模型（schema v1）。
///
/// 遵循 PRD §9：
/// - 业务实体包含 id、createdAt、updatedAt；
/// - 时间戳（createdAt/updatedAt/completedAt）使用 UTC 存储；
/// - 计划日期（deadlineDate/plannedDate）按本地日历日期以 `yyyy-MM-dd`
///   文本单独存储，避免跨时区导致日期漂移。

/// 目标状态（FR-1.3 / FR-1.4）。
class GoalStatus {
  static const String active = 'active';
  static const String completed = 'completed';
  static const String abandoned = 'abandoned';
  static const String archived = 'archived';
}

/// 任务状态。
class TaskStatus {
  static const String todo = 'todo';
  static const String done = 'done';
}

/// 计划偏好默认值（PRD §5.1：默认每天 2 小时、每周 7 天）。
class SettingsDefaults {
  static const int dailyAvailableMinutes = 120;

  /// 每周可用日（ISO 星期 1=周一 … 7=周日），默认全部可用。
  static const Set<int> availableWeekdays = {1, 2, 3, 4, 5, 6, 7};
}

class Goals extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();
  TextColumn get deadlineDate => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

class Subjects extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get color => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

class Tasks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  IntColumn get subjectId => integer().references(Subjects, #id).nullable()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get note => text().nullable()();
  TextColumn get plannedDate => text()();
  IntColumn get estimatedMinutes => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('todo'))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 原计划日期（FR-3.3 验收：延期保留原计划日期）。
  ///
  /// schema v2 引入，仅记录首次延期/改期前的日期，不随后续延期刷新，
  /// 用于审计与后续恢复/统计。未延期过的任务为 null。
  TextColumn get originalPlannedDate => text().nullable()();

  /// 归档时间（JSON 导入替换时保留的历史记录，schema v3 引入）。
  ///
  /// 非 null 表示该任务已被归档：不参与负载/日历统计与常规列表，仅出现在
  /// 目标详情的「历史任务」区，可手动恢复。未归档任务为 null。
  DateTimeColumn get archivedAt => dateTime().nullable()();

  /// 所属重复模板（FR-4，schema v4 引入）。
  ///
  /// 非 null 表示该任务是重复任务的实例：随模板规则由 generateDue 滚动生成；
  /// 模板停止后仍保留为普通任务。普通任务为 null。
  IntColumn get recurrenceTemplateId =>
      integer().references(RecurrenceTemplates, #id).nullable()();
}

/// 重复任务模板（FR-4，schema v4 引入）。
///
/// 「模板 + 实例」模型：模板保存重复规则，实例为具体日期上的任务
/// （Tasks.recurrenceTemplateId 指向本表）。规则以 ruleType(文本) +
/// ruleJson(文本) 存储，由 RecurrenceRuleRegistry 中的 handler 解释，
/// 新增规则类型无需 schema 变更。
class RecurrenceTemplates extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  IntColumn get subjectId => integer().references(Subjects, #id).nullable()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  IntColumn get estimatedMinutes => integer().nullable()();
  TextColumn get ruleType => text()();
  TextColumn get ruleJson => text()();
  TextColumn get startDate => text()();
  TextColumn get endDate => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  TextColumn get generatedThroughDate => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 计划偏好（单行表，PRD §9 Settings 的 M2 子集）。
///
/// schema v2 引入。默认行不写死在迁移里，由 SettingsRepository.get()
/// 惰性 seed（insertOrIgnore），保证迁移库与全新安装行为一致。
class Settings extends Table {
  /// 单行表固定主键 1。
  IntColumn get id => integer()();

  /// 每日可用时长（分钟），PRD §5.1 默认 120。
  IntColumn get dailyAvailableMinutes =>
      integer().withDefault(const Constant(120))();

  /// 每周可用日，逗号分隔的 ISO 星期（1=周一…7=周日），如 `1,2,3,4,5,6,7`。
  TextColumn get availableWeekdays =>
      text().withDefault(const Constant('1,2,3,4,5,6,7'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
