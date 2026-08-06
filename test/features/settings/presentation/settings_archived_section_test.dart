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

/// 设置页「备份与恢复」已归档任务区 Widget 测试。
///
/// 替换导入时归档保留的已完成旧任务，在设置页数据管理卡中回看/恢复。
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

  /// 进入设置页并滚动到「备份与恢复」卡片（卡片在列表下方，惰性构建）。
  Future<void> openDataManagement(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
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

  testWidgets('已归档任务区显示计数，默认折叠', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final done = await tasks.create(
      goalId: goal.id,
      title: '已完成旧任务',
      plannedDate: '2026-08-01',
      estimatedMinutes: 60,
    );
    await tasks.setDone(done.id, true);
    await tasks.archiveAllActive(goal.id);

    await pumpApp(tester);
    await openDataManagement(tester);

    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('已归档任务（1）'), findsOneWidget);
    // 默认折叠：不展示归档行。
    expect(find.text('已完成旧任务'), findsNothing);
  });

  testWidgets('展开归档区显示归档任务（标题 + 完成日期）并可恢复', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final done = await tasks.create(
      goalId: goal.id,
      title: '已完成旧任务',
      plannedDate: '2026-08-01',
      estimatedMinutes: 60,
    );
    await tasks.setDone(done.id, true);
    await tasks.archiveAllActive(goal.id);

    await pumpApp(tester);
    await openDataManagement(tester);

    // 展开归档区。
    await tester.tap(find.byTooltip('展开已归档任务'));
    await tester.pumpAndSettle();

    expect(find.text('已完成旧任务'), findsOneWidget);
    // completedAt 为真实写入时间，只断言「完成」前缀 + 计划日期/时长。
    expect(find.textContaining('完成 '), findsOneWidget);
    expect(find.textContaining('2026-08-01 · 1 小时'), findsOneWidget);

    // 点击恢复：任务回到当前计划，归档区清空。
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(find.text('已归档任务（0）'), findsOneWidget);
    final active = await tasks.byGoal(goal.id);
    expect(active.map((t) => t.title), contains('已完成旧任务'));
    expect((await tasks.archivedByGoal(goal.id)), isEmpty);
  });

  testWidgets('无归档任务时提示且不可展开', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openDataManagement(tester);

    expect(find.text('已归档任务（0）'), findsOneWidget);
    expect(find.byTooltip('展开已归档任务'), findsNothing);
  });
}
