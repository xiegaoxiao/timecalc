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
}
