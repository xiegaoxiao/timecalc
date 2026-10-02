import 'package:drift/drift.dart' show DatabaseConnection;
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

void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late DateTime fixedNow;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });
  tearDown(() async => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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

  Future<void> openCalendar(WidgetTester tester) async {
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
  }

  testWidgets('今天页完成任务后，已打开的日历任务数与负载同步', (tester) async {
    final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '共享任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 150,
    );
    await pumpApp(tester);
    await openCalendar(tester);
    expect(find.text('0/1'), findsOneWidget);
    expect(find.text('超出30'), findsOneWidget);

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();

    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('0分'), findsOneWidget);
    expect(find.text('150分'), findsNothing);
    expect(find.text('超出30'), findsNothing);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });

  testWidgets('跨月延期后，之前查看过的目标日期与月份更新', (tester) async {
    fixedNow = DateTime(2026, 8, 31, 12);
    final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
    final task = await tasks.create(
      goalId: goal.id,
      title: '延期任务',
      plannedDate: '2026-08-31',
      estimatedMinutes: 90,
    );
    await pumpApp(tester);
    await openCalendar(tester);
    await tester.tap(find.byTooltip('下一月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.text('这一天没有任务'), findsOneWidget);
    await tester.tap(find.byTooltip('上一月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('31'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('任务操作'));
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('延期至下一可用日'));
    await tester.pumpAndSettle();
    expect((await tasks.byId(task.id))!.plannedDate, '2026-09-01');
    expect(find.text('延期任务'), findsNothing);

    await tester.tap(find.byTooltip('下一月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.text('延期任务'), findsOneWidget);
    expect(find.text('0/1'), findsOneWidget);
    expect(find.text('90分'), findsOneWidget);
  });

  testWidgets('目标级联删除后，已打开的日历不保留幽灵任务', (tester) async {
    final goal = await goals.create(title: '待删除目标', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '关联任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 150,
    );
    await pumpApp(tester);
    await openCalendar(tester);
    expect(find.text('关联任务'), findsOneWidget);
    await tester.tap(find.text('目标'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目标操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    expect(await tasks.byDate('2026-08-05'), isEmpty);
    expect(find.text('关联任务'), findsNothing);
    expect(find.text('0/1'), findsNothing);
    expect(find.text('150分'), findsNothing);
    expect(find.text('这一天没有任务'), findsOneWidget);
  });
}
