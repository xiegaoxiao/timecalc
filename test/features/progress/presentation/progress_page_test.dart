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

/// 进度页 Widget 测试（FR-7.1 / FR-7.2 / FR-7.4）。
///
/// 固定时钟 2026-08-05（周三），验证：
/// - 今日概览：完成数/总数、已完成时长、目标剩余工作量（FR-7.1）
/// - 热力图：LeetCode 图例文本、tooltip、空态
/// - 甘特图：按目标分组的周时长条形（M3 迭代）
/// - FR-7.4 说明文本
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

  /// 切到「进度」页。
  Future<void> openProgress(WidgetTester tester) async {
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
  }

  /// 在指定 UTC 时刻完成一项带时长的任务（供热力图/甘特图断言）。
  Future<void> completeTask({
    required int goalId,
    required String title,
    required int minutes,
    required DateTime completedAtUtc,
  }) async {
    await db.into(db.tasks).insert(TasksCompanion.insert(
          goalId: goalId,
          title: title,
          plannedDate: '2026-08-01',
          estimatedMinutes: Value(minutes),
          status: const Value('done'),
          completedAt: Value(completedAtUtc),
          createdAt: completedAtUtc,
          updatedAt: completedAtUtc,
        ));
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

  testWidgets('今日概览展示完成数/总数、已完成时长与目标剩余工作量（FR-7.1）',
      (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final today = await tasks.create(
      goalId: goal.id,
      title: '今日任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );
    await tasks.create(
      goalId: goal.id,
      title: '今日任务B',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );
    await tasks.create(
      goalId: goal.id,
      title: '后续未完成',
      plannedDate: '2026-08-10',
      estimatedMinutes: 90,
    );
    await tasks.setDone(today.id, true);

    await pumpApp(tester);
    await openProgress(tester);

    // 完成 1/2 · 已完成 1 小时 · 目标剩余 2 小时
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('1 小时'), findsOneWidget);
    expect(find.text('目标剩余工作量 2 小时'), findsOneWidget);
  });

  testWidgets('热力图 LeetCode 配色：图例文本与 tooltip（FR-7.2）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 本周完成 2 项（本地 2026-08-03 周一当周）→ level 1（1-3 档）。
    await completeTask(
      goalId: goal.id,
      title: 'A',
      minutes: 60,
      completedAtUtc: fixedNow.toUtc(),
    );
    await completeTask(
      goalId: goal.id,
      title: 'B',
      minutes: 30,
      completedAtUtc: fixedNow.toUtc(),
    );

    await pumpApp(tester);
    await openProgress(tester);

    // LeetCode 图例文本（非颜色提示）。
    expect(find.text('完成热力图'), findsOneWidget);
    expect(find.text('1-3'), findsOneWidget);
    expect(find.text('4-6'), findsOneWidget);
    expect(find.text('7-9'), findsOneWidget);
    expect(find.text('10+'), findsOneWidget);

    // 完成日期格子 tooltip（本地日期 2026-08-05）。
    expect(find.byTooltip('2026-08-05：完成 2 项'), findsOneWidget);
  });

  testWidgets('甘特图展示未来计划与已完成时长（M3 迭代）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await goals.create(title: '论文', deadlineDate: '2026-09-30');
    // 未来计划：2 周后（2026-08-19，周三）的任务 120 分钟。
    await tasks.create(
      goalId: goal.id,
      title: '高数强化',
      plannedDate: '2026-08-19',
      estimatedMinutes: 120,
    );
    // 本周完成 60 分钟。
    await completeTask(
      goalId: goal.id,
      title: '背单词',
      minutes: 60,
      completedAtUtc: fixedNow.toUtc(),
    );

    await pumpApp(tester);
    await openProgress(tester);

    expect(find.text('任务耗时甘特图'), findsOneWidget);
    // 只有有计划/完成记录的目标显示行。
    expect(find.text('考研'), findsOneWidget);
    expect(find.text('论文'), findsNothing);
    // 图例（在甘特图 Card 内断言，避免与底部导航「计划」标签歧义）。
    final ganttCard = find.widgetWithText(Card, '任务耗时甘特图');
    expect(
      find.descendant(of: ganttCard, matching: find.text('计划')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ganttCard, matching: find.text('完成')),
      findsOneWidget,
    );
    // 本周完成 tooltip。
    expect(
      find.byTooltip('2026-08-03 起一周：完成 1 小时'),
      findsOneWidget,
    );
    // 未来计划 tooltip（2026-08-17 起一周，含 08-19）。
    expect(
      find.byTooltip('2026-08-17 起一周：计划 2 小时'),
      findsOneWidget,
    );
  });

  testWidgets('无完成记录时热力图与甘特图展示空态与说明（FR-7.2 / PRD §8）',
      (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 无预估时长的任务不计入甘特图（FR-7.4），甘特图展示空态。
    await tasks.create(
      goalId: goal.id,
      title: '未完成任务',
      plannedDate: '2026-08-05',
    );

    await pumpApp(tester);
    await openProgress(tester);

    expect(find.text('还没有完成记录'), findsOneWidget);
    // 甘特图空态在下方，滚动后再断言。
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('还没有带预估时长的任务安排'), findsOneWidget);
    // FR-7.4 说明文本。
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('无预估时长的任务只计入任务数'),
      findsOneWidget,
    );
    expect(find.text('完成热力图'), findsOneWidget);
    expect(find.text('任务耗时甘特图'), findsOneWidget);
  });
}
