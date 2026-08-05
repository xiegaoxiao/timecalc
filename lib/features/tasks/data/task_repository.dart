import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';

/// 任务数据访问层（FR-3）。
class TaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;

  /// 返回目标下的全部任务，按计划日期、创建时间排序。
  Future<List<Task>> byGoal(int goalId) {
    final query = _db.select(_db.tasks)
      ..where((t) => t.goalId.equals(goalId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.plannedDate),
        (t) => OrderingTerm.asc(t.sortOrder),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  Future<Task?> byId(int id) {
    return (_db.select(_db.tasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 创建任务。plannedDate 为本地日历日期文本（yyyy-MM-dd）。
  ///
  /// [estimatedMinutes] 仅接受 1～1440 分钟整数（FR-3 验收），
  /// 非法值由调用方/校验层阻止，本方法不进行业务校验。
  Future<Task> create({
    required int goalId,
    int? subjectId,
    required String title,
    String? note,
    required String plannedDate,
    int? estimatedMinutes,
    int sortOrder = 0,
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final id = await _db.into(_db.tasks).insert(TasksCompanion.insert(
            goalId: goalId,
            subjectId: Value(subjectId),
            title: title,
            note: Value(note),
            plannedDate: plannedDate,
            estimatedMinutes: Value(estimatedMinutes),
            createdAt: now,
            updatedAt: now,
          ));
      return (await byId(id))!;
    });
  }

  /// 批量创建任务（NFR-2：单事务，任一条失败整体回滚，无半写入）。
  ///
  /// 每条 [titles] 生成一个任务；计划日期从 [startDate]（yyyy-MM-dd）起，
  /// 按 [dateIntervalDays] 递增：0 表示全部同一天，1 表示每天一个（如
  /// 真题套卷），7 表示每周一个。[estimatedMinutes] 为统一预估时长。
  /// 空标题条自动跳过。
  Future<int> batchCreate({
    required int goalId,
    int? subjectId,
    required List<String> titles,
    required String startDate,
    int dateIntervalDays = 0,
    int? estimatedMinutes,
  }) {
    if (dateIntervalDays < 0) {
      throw ArgumentError.value(dateIntervalDays, 'dateIntervalDays', '不能为负数');
    }
    final now = DateTime.now().toUtc();
    final start = _parseLocalDate(startDate);
    final cleanTitles = titles.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    if (cleanTitles.isEmpty) return Future.value(0);

    return _db.transaction(() async {
      var count = 0;
      for (var i = 0; i < cleanTitles.length; i++) {
        final date = start.add(Duration(days: dateIntervalDays * i));
        await _db.into(_db.tasks).insert(TasksCompanion.insert(
              goalId: goalId,
              subjectId: Value(subjectId),
              title: cleanTitles[i],
              plannedDate: _formatLocalDate(date),
              estimatedMinutes: Value(estimatedMinutes),
              createdAt: now,
              updatedAt: now,
            ));
        count++;
      }
      return count;
    });
  }

  static DateTime _parseLocalDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  static String _formatLocalDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// 完成任务状态切换（todo <-> done）。事务封装（NFR-2）。
  Future<void> setDone(int id, bool done) {
    return _db.transaction(() async {
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          status: Value(done ? TaskStatus.done : TaskStatus.todo),
          completedAt: Value(done ? DateTime.now().toUtc() : null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  /// 更新任务字段。字符串字段为 null 表示不修改；
  /// 可置空字段（[estimatedMinutes]、[subjectId]）用 `Value` 包装，
  /// 传 `Value(null)` 表示显式置空，不传（null）表示不修改。
  Future<void> update({
    required int id,
    String? title,
    String? note,
    String? plannedDate,
    Value<int?>? estimatedMinutes,
    Value<int?>? subjectId,
  }) {
    return _db.transaction(() async {
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          title: title == null ? const Value.absent() : Value(title),
          note: note == null ? const Value.absent() : Value(note),
          plannedDate:
              plannedDate == null ? const Value.absent() : Value(plannedDate),
          estimatedMinutes: estimatedMinutes ?? const Value.absent(),
          subjectId: subjectId ?? const Value.absent(),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  Future<void> delete(int id) {
    return _db.transaction(() async {
      await (_db.delete(_db.tasks)..where((t) => t.id.equals(id))).go();
    });
  }
}
