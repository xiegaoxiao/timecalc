import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';

/// 里程碑数据访问层（FR-2：目标下的阶段性节点）。
///
/// 里程碑可添加/编辑/完成/删除（FR-2.1）；日期原则上不得晚于目标截止日
/// （FR-2.2，UI 层校验）；首页仅展示距离最近的一个未完成里程碑
/// （FR-2.3，[nextUpcoming]）。
class MilestoneRepository {
  MilestoneRepository(this._db);

  final AppDatabase _db;

  /// 返回目标下的全部里程碑，按 sortOrder 升序。
  Future<List<Milestone>> byGoal(int goalId) {
    final query = _db.select(_db.milestones)
      ..where((m) => m.goalId.equals(goalId))
      ..orderBy([(m) => OrderingTerm.asc(m.sortOrder)]);
    return query.get();
  }

  Future<Milestone?> byId(int id) {
    return (_db.select(_db.milestones)..where((m) => m.id.equals(id)))
        .getSingleOrNull();
  }

  Future<Milestone> create({
    required int goalId,
    required String title,
    required String date,
    int sortOrder = 0,
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final id = await _db.into(_db.milestones).insert(MilestonesCompanion.insert(
            goalId: goalId,
            title: title,
            date: date,
            sortOrder: Value(sortOrder),
            createdAt: now,
            updatedAt: now,
          ));
      return (await byId(id))!;
    });
  }

  /// 编辑标题/日期；[done] 非 null 时同步标记完成状态（FR-2.1 完成里程碑）。
  Future<void> update({
    required int id,
    String? title,
    String? date,
    bool? done,
  }) {
    return _db.transaction(() async {
      await (_db.update(_db.milestones)..where((m) => m.id.equals(id))).write(
        MilestonesCompanion(
          title: title == null ? const Value.absent() : Value(title),
          date: date == null ? const Value.absent() : Value(date),
          status: done == null
              ? const Value.absent()
              : Value(done ? MilestoneStatus.done : MilestoneStatus.todo),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  Future<void> delete(int id) {
    return _db.transaction(() async {
      await (_db.delete(_db.milestones)..where((m) => m.id.equals(id))).go();
    });
  }

  /// 返回目标下日期最近的一个未完成里程碑（FR-2.3 首页展示）。
  ///
  /// 未完成里程碑中取 date 最小（最近）的那个；没有未完成里程碑时返回 null。
  /// 日期为 `yyyy-MM-dd` 文本，同格式下字典序即日期序。
  Future<Milestone?> nextUpcoming(int goalId, {required DateTime today}) {
    final todayText = _dateText(today);
    final query = _db.select(_db.milestones)
      ..where((m) =>
          m.goalId.equals(goalId) &
          m.status.equals(MilestoneStatus.todo) &
          m.date.isBiggerOrEqualValue(todayText))
      ..orderBy([(m) => OrderingTerm.asc(m.date)])
      ..limit(1);
    return query.getSingleOrNull();
  }

  static String _dateText(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}
