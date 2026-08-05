import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// 目标数据访问层。
///
/// 数据事实保存在 Drift；规则校验（如倒计时）位于 service，
/// 本类只负责读写与事务边界。
class GoalRepository {
  GoalRepository(this._db);

  final AppDatabase _db;

  /// 返回全部目标，按创建时间倒序（新目标在前）；时间相同时按 id 倒序保证稳定。
  Future<List<Goal>> watchAll() {
    final query = _db.select(_db.goals)
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ]);
    return query.get();
  }

  /// 按 id 查询单个目标。
  Future<Goal?> byId(int id) {
    return (_db.select(_db.goals)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 创建目标。deadlineDate 由调用方以本地日历日期文本（yyyy-MM-dd）传入。
  Future<Goal> create({
    required String title,
    required String deadlineDate,
    String? description,
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final id = await _db.into(_db.goals).insert(GoalsCompanion.insert(
            title: title,
            deadlineDate: deadlineDate,
            description: Value(description),
            createdAt: now,
            updatedAt: now,
          ));
      return (await byId(id))!;
    });
  }

  /// 创建目标并一次性创建其科目（如「考研」+ 政治/英语/数学/408）。
  ///
  /// 目标与科目在同一事务内完成（NFR-2）：任一步失败整体回滚，
  /// 不会留下"无科目的目标"或"无目标的科目"半成品。
  Future<Goal> createWithSubjects({
    required String title,
    required String deadlineDate,
    String? description,
    List<String> subjectNames = const [],
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final goalId = await _db.into(_db.goals).insert(GoalsCompanion.insert(
            title: title,
            deadlineDate: deadlineDate,
            description: Value(description),
            createdAt: now,
            updatedAt: now,
          ));
      final uniqueNames = subjectNames
          .map((n) => n.trim())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList();
      for (var i = 0; i < uniqueNames.length; i++) {
        await _db.into(_db.subjects).insert(SubjectsCompanion.insert(
              goalId: goalId,
              name: uniqueNames[i],
              color: '#3F6C51',
              sortOrder: Value(i),
              createdAt: now,
              updatedAt: now,
            ));
      }
      return (await byId(goalId))!;
    });
  }

  /// 更新目标的基础字段。字符串字段为 null 表示不修改；
  /// [description] 传 `Value(null)` 表示显式清空描述。
  Future<void> update({
    required int id,
    String? title,
    String? deadlineDate,
    Value<String?>? description,
    String? status,
    DateTime? completedAt,
  }) {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
        GoalsCompanion(
          title: title == null ? const Value.absent() : Value(title),
          deadlineDate:
              deadlineDate == null ? const Value.absent() : Value(deadlineDate),
          description: description ?? const Value.absent(),
          status: status == null ? const Value.absent() : Value(status),
          completedAt:
              completedAt == null ? const Value.absent() : Value(completedAt),
          updatedAt: Value(now),
        ),
      );
    });
  }

  /// 删除目标及其全部科目、任务与重复模板（FR-1 验收：删除目标前明确提示将同时删除其任务）。
  ///
  /// 跨多表删除在单个事务内完成（NFR-2）：中途失败时回滚，不留下半删除数据。
  Future<void> deleteWithCascade(int goalId) {
    return _db.transaction(() async {
      final subjects = await (_db.select(_db.subjects)
            ..where((s) => s.goalId.equals(goalId)))
          .get();
      final subjectIds = subjects.map((s) => s.id).toList();

      if (subjectIds.isNotEmpty) {
        await (_db.delete(_db.tasks)
              ..where((t) => t.subjectId.isIn(subjectIds)))
            .go();
      }
      await (_db.delete(_db.tasks)..where((t) => t.goalId.equals(goalId))).go();
      await (_db.delete(_db.subjects)
            ..where((s) => s.goalId.equals(goalId)))
          .go();
      // 重复任务模板随目标级联删除，防止孤儿模板（FR-4）。
      await (_db.delete(_db.recurrenceTemplates)
            ..where((t) => t.goalId.equals(goalId)))
          .go();
      await (_db.delete(_db.goals)..where((g) => g.id.equals(goalId))).go();
    });
  }
}
