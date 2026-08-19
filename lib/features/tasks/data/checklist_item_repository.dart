import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// 任务检查项数据访问层（FR-4.1）。
///
/// 检查项归属任务（taskId 外键），按 sortOrder 排序；上移/下移在同任务
/// 内交换 sortOrder 实现「可排序」。任务/目标删除时检查项由级联删除
/// 清理（见 TaskRepository.delete / importPlan / GoalRepository.deleteWithCascade），
/// 本类不负责跨实体删除。
class ChecklistItemRepository {
  ChecklistItemRepository(this._db, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() clock;

  /// 返回任务下的全部检查项，按 sortOrder、id 升序。
  Future<List<ChecklistItem>> byTask(int taskId) {
    final query = _db.select(_db.checklistItems)
      ..where((c) => c.taskId.equals(taskId))
      ..orderBy([
        (c) => OrderingTerm.asc(c.sortOrder),
        (c) => OrderingTerm.asc(c.id),
      ]);
    return query.get();
  }

  /// 任务下未完成检查项数量（完成二次确认的判定依据，FR-4.1）。
  Future<int> unfinishedCount(int taskId) {
    final query = _db.selectOnly(_db.checklistItems)
      ..addColumns([_db.checklistItems.id.count()])
      ..where(_db.checklistItems.taskId.equals(taskId) &
          _db.checklistItems.done.equals(false));
    return query.map((row) => row.read(_db.checklistItems.id.count()) ?? 0)
        .getSingle();
  }

  /// 创建检查项（追加到任务末尾，sortOrder = 当前最大 + 1）。
  Future<ChecklistItem> create({
    required int taskId,
    required String title,
  }) {
    final now = clock().toUtc();
    return _db.transaction(() async {
      // 单条 MAX 聚合查询代替「加载任务下全部检查项再求最大」——
      // 检查项多时避免整表行拉进内存只为求一个计数。
      final maxQuery = _db.selectOnly(_db.checklistItems)
        ..addColumns([_db.checklistItems.sortOrder.max()])
        ..where(_db.checklistItems.taskId.equals(taskId));
      final maxOrder =
          await maxQuery.map((row) => row.read(_db.checklistItems.sortOrder.max())).getSingle();
      final id = await _db.into(_db.checklistItems).insert(
            ChecklistItemsCompanion.insert(
              taskId: taskId,
              title: title,
              sortOrder: Value((maxOrder ?? -1) + 1),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return (await byId(id))!;
    });
  }

  Future<ChecklistItem?> byId(int id) {
    return (_db.select(_db.checklistItems)..where((c) => c.id.equals(id)))
        .getSingleOrNull();
  }

  /// 重命名检查项标题。
  Future<void> rename(int id, String title) {
    return _db.transaction(() async {
      await (_db.update(_db.checklistItems)..where((c) => c.id.equals(id)))
          .write(
            ChecklistItemsCompanion(
              title: Value(title),
              updatedAt: Value(clock().toUtc()),
            ),
          );
    });
  }

  /// 完成状态切换（勾选/取消勾选）。
  Future<void> setDone(int id, bool done) {
    return _db.transaction(() async {
      await (_db.update(_db.checklistItems)..where((c) => c.id.equals(id)))
          .write(
            ChecklistItemsCompanion(
              done: Value(done),
              updatedAt: Value(clock().toUtc()),
            ),
          );
    });
  }

  Future<void> delete(int id) {
    return _db.transaction(() async {
      await (_db.delete(_db.checklistItems)..where((c) => c.id.equals(id)))
          .go();
    });
  }

  /// 上移/下移检查项（delta = -1 上移，+1 下移）：在同任务内与相邻项
  /// 交换 sortOrder，单事务保证排序一致（NFR-2）。
  Future<void> move(int taskId, int itemId, int delta) {
    return _db.transaction(() async {
      final items = await byTask(taskId);
      final index = items.indexWhere((c) => c.id == itemId);
      if (index < 0) return;
      final target = index + delta;
      if (target < 0 || target >= items.length) return;
      final current = items[index];
      final neighbor = items[target];
      // 直接交换两者的 sortOrder（L42：注释曾误写「写中间值再交换」；
      // sortOrder 无唯一约束，直接交换即可，两次 UPDATE 在单事务内保证
      // 排序一致）。
      await (_db.update(_db.checklistItems)
            ..where((c) => c.id.equals(current.id)))
          .write(
            ChecklistItemsCompanion(
              sortOrder: Value(neighbor.sortOrder),
              updatedAt: Value(clock().toUtc()),
            ),
          );
      await (_db.update(_db.checklistItems)
            ..where((c) => c.id.equals(neighbor.id)))
          .write(
            ChecklistItemsCompanion(
              sortOrder: Value(current.sortOrder),
              updatedAt: Value(clock().toUtc()),
            ),
          );
    });
  }
}
