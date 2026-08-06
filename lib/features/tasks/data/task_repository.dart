import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/utils/date_text.dart';
import '../domain/task_import_parser.dart';
import 'recurrence_repository.dart';

/// 任务数据访问层（FR-3）。
class TaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;

  /// 返回目标下的全部未归档任务，按计划日期、创建时间排序。
  Future<List<Task>> byGoal(int goalId) {
    final query = _db.select(_db.tasks)
      ..where((t) => t.goalId.equals(goalId) & t.archivedAt.isNull())
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

  /// 返回计划日期为 [date]（yyyy-MM-dd）的全部未归档任务（跨目标，供今日页使用）。
  Future<List<Task>> byDate(String date) {
    final query = _db.select(_db.tasks)
      ..where((t) => t.plannedDate.equals(date) & t.archivedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.goalId),
        (t) => OrderingTerm.asc(t.sortOrder),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  /// 返回计划日期在 [start]～[end]（含，yyyy-MM-dd，字典序比较）的全部未归档任务，
  /// 供日历月视图聚合使用。
  Future<List<Task>> byDateRange(String start, String end) {
    final query = _db.select(_db.tasks)
      ..where((t) => t.plannedDate.isBetweenValues(start, end) &
          t.archivedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.plannedDate),
        (t) => OrderingTerm.asc(t.goalId),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  /// 返回计划日期早于 [date]（yyyy-MM-dd）且未完成、未归档的任务（FR-3.7）。
  ///
  /// 用于次日首次打开时集中提示昨日及以前未完成任务的延期/保留选择。
  Future<List<Task>> unfinishedBefore(String date) {
    final query = _db.select(_db.tasks)
      ..where((t) => t.plannedDate.isSmallerThanValue(date) &
          t.status.equals(TaskStatus.todo) &
          t.archivedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.plannedDate),
        (t) => OrderingTerm.asc(t.goalId),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  /// 返回目标下的全部归档任务（历史记录，按归档时间倒序）。
  Future<List<Task>> archivedByGoal(int goalId) {
    final query = _db.select(_db.tasks)
      ..where((t) => t.goalId.equals(goalId) & t.archivedAt.isNotNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.archivedAt),
        (t) => OrderingTerm.asc(t.plannedDate),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  /// 返回全部归档任务（跨目标，设置页数据管理区用，按归档时间倒序）。
  Future<List<Task>> allArchived() {
    final query = _db.select(_db.tasks)
      ..where((t) => t.archivedAt.isNotNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.archivedAt),
        (t) => OrderingTerm.asc(t.plannedDate),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  /// 归档任务总数（COUNT 查询）。
  ///
  /// 设置页数据管理区折叠态只展示计数，不加载全量列表（懒加载回看：
  /// 归档多时避免打开设置页即全量查询造成卡顿）。
  Future<int> countArchived() {
    final query = _db.selectOnly(_db.tasks)
      ..addColumns([_db.tasks.id.count()])
      ..where(_db.tasks.archivedAt.isNotNull());
    return query.map((row) => row.read(_db.tasks.id.count()) ?? 0).getSingle();
  }

  /// 返回在 [fromUtc]（含）～[toUtc]（含）之间完成、未归档的任务（FR-7.2）。
  ///
  /// 供热力图按「完成日期」统计：completedAt 为 UTC 时间戳，调用方换算为
  /// 本地日历日期后归入对应日期。
  Future<List<Task>> completedBetween(DateTime fromUtc, DateTime toUtc) {
    final query = _db.select(_db.tasks)
      ..where((t) =>
          t.status.equals(TaskStatus.done) &
          t.completedAt.isNotNull() &
          t.completedAt.isBetweenValues(fromUtc, toUtc) &
          t.archivedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.completedAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
  }

  /// 返回全部未完成、未归档任务（跨目标，FR-7.1 目标剩余工作量汇总）。
  Future<List<Task>> allTodoTasks() {
    final query = _db.select(_db.tasks)
      ..where((t) => t.status.equals(TaskStatus.todo) & t.archivedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.plannedDate),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return query.get();
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
        // 纯日历加法（date_text）：避免 Duration(days:) 在夏令时切换日
        // 偏移一小时导致日期文本错位。
        final date = addLocalDays(start, dateIntervalDays * i);
        await _db.into(_db.tasks).insert(TasksCompanion.insert(
              goalId: goalId,
              subjectId: Value(subjectId),
              title: cleanTitles[i],
              plannedDate: formatLocalDate(date),
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

  /// 批量导入（JSON 导入升级版）。
  ///
  /// 科目与未分类任务在单个事务内写入（NFR-2）：目标下不存在的科目自动创建
  /// （沿用默认颜色与排序），任务按计划日期与归属写入；任一条失败整体回滚，
  /// 无半写入。日期与时长已在解析层校验，本方法不重复业务校验。
  ///
  /// [replaceExisting] 为 true 时执行「替换」语义（JSON 导入默认行为）：
  /// 未完成旧任务直接删除，已完成旧任务归档保留（历史语义重构：归档区
  /// 只保留已完成任务，未完成的旧计划不保留），再写入 JSON 任务。
  /// 删除/归档与写入在同一事务内完成。
  Future<ImportStats> importPlan({
    required int goalId,
    required List<ImportedTaskItem> items,
    bool replaceExisting = false,
  }) {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      var deletedTasks = 0;
      var archivedTasks = 0;
      if (replaceExisting) {
        final current = await (_db.select(_db.tasks)
              ..where((t) => t.goalId.equals(goalId) & t.archivedAt.isNull()))
            .get();
        final todoIds = current
            .where((t) => t.status == TaskStatus.todo)
            .map((t) => t.id)
            .toList();
        final doneIds = current
            .where((t) => t.status == TaskStatus.done)
            .map((t) => t.id)
            .toList();
        if (todoIds.isNotEmpty) {
          // 未完成的旧任务不保留：替换即弃旧，直接物理删除。
          // 先删这些任务的检查项，防止孤儿检查项（FR-4.1，NFR-2）。
          await (_db.delete(_db.checklistItems)
                ..where((c) => c.taskId.isIn(todoIds)))
              .go();
          deletedTasks = await (_db.delete(_db.tasks)
                ..where((t) => t.id.isIn(todoIds)))
              .go();
        }
        if (doneIds.isNotEmpty) {
          // 已完成的旧任务归档保留，供设置页数据管理区回看/恢复。
          archivedTasks = await (_db.update(_db.tasks)
                ..where((t) => t.id.isIn(doneIds)))
              .write(
                TasksCompanion(
                  archivedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
        }
        // 替换语义下停用该目标的重复模板，避免替换后模板继续生成实例。
        await (_db.update(_db.recurrenceTemplates)
              ..where((t) => t.goalId.equals(goalId) & t.active.equals(true)))
            .write(
              RecurrenceTemplatesCompanion(
                active: const Value(false),
                updatedAt: Value(now),
              ),
            );
      }

      final existing = await (_db.select(_db.subjects)
            ..where((s) => s.goalId.equals(goalId)))
          .get();
      final nameToId = {for (final s in existing) s.name: s.id};
      var maxSort = existing.isEmpty
          ? -1
          : existing.map((s) => s.sortOrder).reduce((a, b) => a > b ? a : b);

      var createdSubjects = 0;
      for (final item in items) {
        final name = item.subjectName;
        int? subjectId;
        if (name != null) {
          subjectId = nameToId[name];
          if (subjectId == null) {
            maxSort++;
            subjectId = await _db.into(_db.subjects).insert(
                  SubjectsCompanion.insert(
                    goalId: goalId,
                    name: name,
                    color: '#3F6C51',
                    sortOrder: Value(maxSort),
                    createdAt: now,
                    updatedAt: now,
                  ),
                );
            nameToId[name] = subjectId;
            createdSubjects++;
          }
        }
        await _db.into(_db.tasks).insert(TasksCompanion.insert(
              goalId: goalId,
              subjectId: Value(subjectId),
              title: item.title,
              plannedDate: item.date,
              estimatedMinutes: Value(item.minutes),
              createdAt: now,
              updatedAt: now,
            ));
      }
      return ImportStats(
        createdSubjects: createdSubjects,
        createdTasks: items.length,
        replacedTasks: deletedTasks + archivedTasks,
        deletedTasks: deletedTasks,
        archivedTasks: archivedTasks,
      );
    });
  }

  /// 归档目标下全部未归档任务（历史语义重构后仅用于测试/兼容；替换导入
  /// 已在 importPlan 内按完成状态分流处理）。
  Future<int> archiveAllActive(int goalId) {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      return (_db.update(_db.tasks)
            ..where((t) => t.goalId.equals(goalId) & t.archivedAt.isNull()))
          .write(
            TasksCompanion(
              archivedAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    });
  }

  /// 恢复归档任务：重新进入未归档状态（回到其计划日期参与负载与列表）。
  Future<void> restoreArchived(int id) {
    return _db.transaction(() async {
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          archivedAt: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
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
  /// 可置空字段（[note]、[estimatedMinutes]、[subjectId]）用 `Value` 包装，
  /// 传 `Value(null)` 表示显式置空，不传（null）表示不修改。
  ///
  /// 当计划日期变化且任务尚未记录原计划日期时，自动记录原日期
  /// （FR-3.3 验收：延期/改期保留原计划日期；仅记录首次，不随后续调整刷新）。
  Future<void> update({
    required int id,
    String? title,
    Value<String?>? note,
    String? plannedDate,
    Value<int?>? estimatedMinutes,
    Value<int?>? subjectId,
  }) {
    return _db.transaction(() async {
      final current = await byId(id);
      if (current == null) return;
      final original =
          _originalDateOnReschedule(current: current, newPlannedDate: plannedDate);
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          title: title == null ? const Value.absent() : Value(title),
          note: note ?? const Value.absent(),
          plannedDate:
              plannedDate == null ? const Value.absent() : Value(plannedDate),
          estimatedMinutes: estimatedMinutes ?? const Value.absent(),
          subjectId: subjectId ?? const Value.absent(),
          originalPlannedDate: original,
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  /// 延期单个任务到 [newPlannedDate]（yyyy-MM-dd）。
  ///
  /// 事务内读取当前行：日期未变则不写入（no-op）；仅当原计划日期为空时
  /// 记录当前日期（FR-3.3 验收）。任务内容、归属与预估时长保持不变。
  Future<void> defer(int id, String newPlannedDate) {
    return _db.transaction(() async {
      final current = await byId(id);
      if (current == null) return;
      // 计划日期未变视为无效操作（不写库）；改期后仅记录首次原日期。
      if (current.plannedDate == newPlannedDate) return;
      final original =
          _originalDateOnReschedule(current: current, newPlannedDate: newPlannedDate);
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          plannedDate: Value(newPlannedDate),
          originalPlannedDate: original,
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  /// 批量延期到同一日期（FR-3.7 次日未完成任务集中处理）。
  ///
  /// 全部延期在单个事务内完成（NFR-2）：任一条失败整体回滚，无半写入。
  /// 返回实际发生延期（计划日期被改变）的任务数。
  Future<int> deferMany(List<int> ids, String newPlannedDate) {
    return _db.transaction(() async {
      var changed = 0;
      for (final id in ids) {
        final current = await byId(id);
        if (current == null) continue;
        if (current.plannedDate == newPlannedDate) continue;
        await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
          TasksCompanion(
            plannedDate: Value(newPlannedDate),
            originalPlannedDate:
                current.originalPlannedDate == null
                    ? Value(current.plannedDate)
                    : const Value.absent(),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
        changed++;
      }
      return changed;
    });
  }

  /// 改期时计算应写入的 originalPlannedDate 字段。
  ///
  /// 仅当计划日期确实变化且原计划日期尚未记录时，记录当前计划日期；
  /// 否则不修改（Value.absent）。
  Value<String?> _originalDateOnReschedule({
    required Task current,
    required String? newPlannedDate,
  }) {
    if (newPlannedDate == null ||
        newPlannedDate == current.plannedDate ||
        current.originalPlannedDate != null) {
      return const Value.absent();
    }
    return Value(current.plannedDate);
  }

  /// 删除任务。
  ///
  /// 删除重复任务的实例时，将该实例的日期记入模板墓碑
  /// （deletedInstanceDates，schema v5），后续滚动生成跳过这些日期，
  /// 保证用户删除的实例不会随窗口前移「复活」。
  /// 任务的检查项随任务级联删除，防止孤儿检查项（FR-4.1，NFR-2）。
  Future<void> delete(int id) {
    return _db.transaction(() async {
      final task = await byId(id);
      if (task == null) return;
      await (_db.delete(_db.checklistItems)..where((c) => c.taskId.equals(id)))
          .go();
      await (_db.delete(_db.tasks)..where((t) => t.id.equals(id))).go();
      final templateId = task.recurrenceTemplateId;
      if (templateId != null) {
        await _recordDeletedInstance(templateId, task.plannedDate);
      }
    });
  }

  /// 把 [date] 记入模板墓碑（同一事务内调用，删除实例后写入）。
  Future<void> _recordDeletedInstance(int templateId, String date) async {
    final template = await (_db.select(_db.recurrenceTemplates)
          ..where((t) => t.id.equals(templateId)))
        .getSingleOrNull();
    if (template == null) return;
    final tombstones =
        RecurrenceRepository.decodeTombstones(template.deletedInstanceDates)
          ..add(date);
    await (_db.update(_db.recurrenceTemplates)
          ..where((t) => t.id.equals(templateId)))
        .write(
          RecurrenceTemplatesCompanion(
            deletedInstanceDates:
                Value(RecurrenceRepository.encodeTombstones(tombstones)),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }
}
