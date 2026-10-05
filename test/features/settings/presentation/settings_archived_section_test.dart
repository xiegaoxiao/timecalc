import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 设置页「已归档任务」子页 Widget 测试。
///
/// 替换导入时归档保留的已完成旧任务，在设置页「已归档任务」菜单项进入的
/// 独立子页中平铺回看/恢复（批量删除已移除，只保留列表 + 单条「恢复」）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 进入设置页 → 点击「已归档任务」菜单项 → 归档子页。
  Future<void> openArchivedPage(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已归档任务'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('已归档任务子页平铺展示归档任务（标题 + 完成日期）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final done = await tasks.create(
      goalId: goal.id,
      title: '已完成旧任务',
      plannedDate: '2026-08-01',
      estimatedMinutes: 60,
    );
    await tasks.setDone(done.id, true);
    await _archiveGoal(db, goal.id, fixedNow);

    await pumpApp(tester);
    await openArchivedPage(tester);

    expect(find.text('已完成旧任务'), findsOneWidget);
    // completedAt 为真实写入时间，只断言「完成」前缀 + 计划日期/时长。
    expect(find.textContaining('完成 '), findsOneWidget);
    expect(find.textContaining('2026-08-01 · 1 小时'), findsOneWidget);
  });

  testWidgets('点击恢复：任务回到当前计划，归档列表清空', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final done = await tasks.create(
      goalId: goal.id,
      title: '已完成旧任务',
      plannedDate: '2026-08-01',
      estimatedMinutes: 60,
    );
    await tasks.setDone(done.id, true);
    await _archiveGoal(db, goal.id, fixedNow);

    await pumpApp(tester);
    await openArchivedPage(tester);

    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    // 恢复后子页回到空态。
    expect(find.text('暂无归档任务'), findsOneWidget);
    final active = await tasks.byGoal(goal.id);
    expect(active.map((t) => t.title), contains('已完成旧任务'));
    expect((await tasks.archivedByGoal(goal.id)), isEmpty);
  });

  testWidgets('无归档任务时子页展示空态提示', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openArchivedPage(tester);

    expect(find.text('暂无归档任务'), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
  });

  testWidgets('子页只保留列表与单条恢复：不再有批量删除入口', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    for (var i = 0; i < 2; i++) {
      final t = await tasks.create(
        goalId: goal.id,
        title: '旧任务$i',
        plannedDate: '2026-08-01',
        estimatedMinutes: 60,
      );
      await tasks.setDone(t.id, true);
    }
    await _archiveGoal(db, goal.id, fixedNow);

    await pumpApp(tester);
    await openArchivedPage(tester);

    // 列表与单条恢复仍在。
    expect(find.text('旧任务0'), findsOneWidget);
    expect(find.text('旧任务1'), findsOneWidget);
    expect(find.text('恢复'), findsNWidgets(2));
    // 批量删除链路已移除：无入口、无选择控件、无全选/反选。
    expect(find.byTooltip('批量删除'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('全选'), findsNothing);
    expect(find.text('反选'), findsNothing);
  });
}

/// 把 [goalId] 下全部任务置为已归档。
///
/// 归档的生产入口是导入替换（`importPlan` 内按完成状态分流），仓储层没有
/// 对外的单条归档 API，因此测试直接写库造数。
Future<void> _archiveGoal(AppDatabase db, int goalId, DateTime at) {
  return (db.update(db.tasks)..where((t) => t.goalId.equals(goalId)))
      .write(TasksCompanion(archivedAt: Value(at.toUtc())));
}
