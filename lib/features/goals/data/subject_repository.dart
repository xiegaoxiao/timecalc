import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// 科目数据访问层（FR-1.5：任务可选属于一个科目/分组）。
class SubjectRepository {
  SubjectRepository(this._db);

  final AppDatabase _db;

  /// 返回目标下的全部科目，按 sortOrder 升序。
  Future<List<Subject>> byGoal(int goalId) {
    final query = _db.select(_db.subjects)
      ..where((s) => s.goalId.equals(goalId))
      ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]);
    return query.get();
  }

  Future<Subject?> byId(int id) {
    return (_db.select(_db.subjects)..where((s) => s.id.equals(id)))
        .getSingleOrNull();
  }

  Future<Subject> create({
    required int goalId,
    required String name,
    required String color,
    int sortOrder = 0,
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final id = await _db.into(_db.subjects).insert(SubjectsCompanion.insert(
            goalId: goalId,
            name: name,
            color: color,
            sortOrder: Value(sortOrder),
            createdAt: now,
            updatedAt: now,
          ));
      return (await byId(id))!;
    });
  }

  Future<void> rename({required int id, required String name}) {
    return _db.transaction(() async {
      await (_db.update(_db.subjects)..where((s) => s.id.equals(id))).write(
        SubjectsCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  Future<void> delete(int id) {
    return _db.transaction(() async {
      // 科目删除时，其任务保留但解除科目归属（subjectId 置空），不误删任务。
      await (_db.update(_db.tasks)..where((t) => t.subjectId.equals(id))).write(
        TasksCompanion(
          subjectId: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      // 重复任务模板同样解除科目归属：模板的 subject_id 为外键，
      // 不置空会在删除科目时触发约束异常（修复：删除科目崩溃）。
      await (_db.update(_db.recurrenceTemplates)
            ..where((t) => t.subjectId.equals(id)))
          .write(
            RecurrenceTemplatesCompanion(
              subjectId: const Value(null),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );
      await (_db.delete(_db.subjects)..where((s) => s.id.equals(id))).go();
    });
  }
}
