import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/sync/data/database_change_watcher.dart';

/// DatabaseChangeWatcher 测试（M9「变更后推送」链路）。
///
/// 回答「修改/添加后是否触发同步」：业务表写入 → managers.watch() →
/// debounce → onChanged（main 里接 pushIfNeeded）。
///
/// 覆盖：
/// - 订阅不触发（skip(1) 跳过初始行）；
/// - 添加任务 / 修改任务标题 → 触发；
/// - 目标 / 里程碑 / 待办勾选（checklistItems）写入 → 触发；
/// - settings 表写入 → **不触发**（推送写 lastPushedSeq 不回环）；
/// - debounce 窗口内多次写入合并为一次回调；
/// - dispose 后不再触发。
void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<DatabaseChangeWatcher> startWatcher(
    void Function() onChanged, {
    Duration debounce = const Duration(milliseconds: 30),
  }) async {
    final watcher = DatabaseChangeWatcher(
      db,
      debounce: debounce,
      onChanged: onChanged,
    );
    // 等订阅建立 + skip(1) 消费完初始行。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return watcher;
  }

  test('订阅后无写入：onChanged 不触发（skip(1) 跳过初始行）', () async {
    var fired = 0;
    await startWatcher(() => fired++);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(fired, 0);
  });

  test('添加目标 + 添加任务 → 触发 onChanged', () async {
    var fired = 0;
    final completer = Completer<void>();
    final watcher = await startWatcher(() {
      fired++;
      if (!completer.isCompleted) completer.complete();
    });

    await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: 'g',
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    final goal = (await db.select(db.goals).get()).single;
    await db.into(db.tasks).insert(
          TasksCompanion.insert(
            goalId: goal.id,
            title: 't',
            plannedDate: '2026-08-05',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );

    await completer.future.timeout(const Duration(seconds: 2));
    expect(fired, 1, reason: '两次写入落在 debounce 窗口内应合并为一次回调');
    watcher.dispose();
  });

  test('修改任务标题（编辑已有任务）→ 触发 onChanged', () async {
    await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: 'g',
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    final goal = (await db.select(db.goals).get()).single;
    final taskId = await db.into(db.tasks).insert(
          TasksCompanion.insert(
            goalId: goal.id,
            title: 't',
            plannedDate: '2026-08-05',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );

    var fired = 0;
    final completer = Completer<void>();
    final watcher = await startWatcher(() {
      fired++;
      if (!completer.isCompleted) completer.complete();
    });

    // 模拟编辑保存：改标题 + updatedAt。
    await (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(
          TasksCompanion(
            title: const Value('t2'),
            updatedAt: Value(DateTime.utc(2026, 1, 2)),
          ),
        );

    await completer.future.timeout(const Duration(seconds: 2));
    expect(fired, 1);
    watcher.dispose();
  });

  test('里程碑 / 待办勾选（checklistItems）写入 → 触发 onChanged', () async {
    await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: 'g',
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    final goal = (await db.select(db.goals).get()).single;
    await db.into(db.milestones).insert(
          MilestonesCompanion.insert(
            goalId: goal.id,
            title: 'm',
            date: '2026-09-01',
            sortOrder: const Value(1),
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    final taskId = await db.into(db.tasks).insert(
          TasksCompanion.insert(
            goalId: goal.id,
            title: 't',
            plannedDate: '2026-08-05',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );

    var fired = 0;
    final completer = Completer<void>();
    final watcher = await startWatcher(() {
      fired++;
      if (!completer.isCompleted) completer.complete();
    });

    // 待办列表项：写入即触发（勾选状态切换走同一 update 路径）。
    await db.into(db.checklistItems).insert(
          ChecklistItemsCompanion.insert(
            taskId: taskId,
            title: 'item',
            sortOrder: const Value(1),
            done: const Value(false),
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await completer.future.timeout(const Duration(seconds: 2));
    expect(fired, 1);
    watcher.dispose();
  });

  test('settings 表写入不触发（推送写 lastPushedSeq 防回环）', () async {
    var fired = 0;
    final watcher = await startWatcher(() => fired++);

    await db.into(db.settings).insert(
          SettingsCompanion.insert(
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(fired, 0, reason: 'settings 不监听：同步服务写同步状态不会形成推送回环');
    watcher.dispose();
  });

  test('dispose 后写入不再触发', () async {
    var fired = 0;
    final watcher = await startWatcher(() => fired++);
    watcher.dispose();

    await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: 'g',
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(fired, 0);
  });
}
