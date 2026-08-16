import 'package:drift/drift.dart';
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

import '../../../shared/nav_helper.dart';

/// 计划页三视图（周/月/年）Widget 测试。
///
/// 固定时钟 2026-08-05（周三，处于 2026-08-03~08-09 那一周）。
/// 验证：
/// - 视图切换器存在（周/月/年三段）且默认月视图；
/// - 周视图：显示当周 7 天、跨月周正确（2026-08 月首 8/1 是周六）；
/// - 年视图：3×4 十二个月格、月完成数正确、点月格下钻月视图；
/// - 「回到今天」从任意视图回当前单元。
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

  Future<void> openCalendar(WidgetTester tester) async {
    await tapNavDestination(tester, '计划');
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

  testWidgets('视图切换器存在且默认月视图', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await pumpApp(tester);
    await openCalendar(tester);

    // 三段切换器。
    expect(find.text('周'), findsOneWidget);
    expect(find.text('月'), findsOneWidget);
    expect(find.text('年'), findsOneWidget);
    // 默认月视图标题。
    expect(find.text('2026年8月'), findsOneWidget);
  });

  testWidgets('周视图：显示当周 7 天与负载聚合，跨月周正常', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 当周（8/3 周一 ~ 8/9 周日）任务：周一 2 个（1 完成）、周三 1 个。
    await tasks.create(
      goalId: goal.id,
      title: '周一周一',
      plannedDate: '2026-08-03',
      estimatedMinutes: 60,
    );
    final done1 = await tasks.create(
      goalId: goal.id,
      title: '周一完成',
      plannedDate: '2026-08-03',
      estimatedMinutes: 30,
    );
    await tasks.setDone(done1.id, true);
    await tasks.create(
      goalId: goal.id,
      title: '周三任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );
    // 下周任务（不应出现在本周）。
    await tasks.create(
      goalId: goal.id,
      title: '下周任务',
      plannedDate: '2026-08-10',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 切到周视图。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();

    // 标题：本周 8/3~8/9（新格式：8月3日 – 9日 · 第 32 周）。
    expect(find.textContaining('8月3日'), findsOneWidget);
    expect(find.textContaining('第'), findsOneWidget);

    // 7 天都在（日期号）。
    for (final day in ['3', '4', '5', '6', '7', '8', '9']) {
      expect(find.text(day), findsWidgets);
    }
    // 周一的负载聚合（2/2 完成 1 + 时长 1h30）。
    expect(find.text('1/2'), findsOneWidget);
    // 下周任务不出现。
    expect(find.text('下周任务'), findsNothing);
  });

  testWidgets('年视图：12 月格 + 月完成数 + 点月格下钻月视图', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 直接插入已完成任务并指定 completedAt（setDone 用真实时钟，
    // 与固定时钟测试环境不一致，无法控制完成月份）。
    Future<void> insertDone(String title, String date, DateTime completedAt) async {
      await db.into(db.tasks).insert(
            TasksCompanion.insert(
              goalId: goal.id,
              title: title,
              plannedDate: date,
              status: const Value('done'),
              completedAt: Value(completedAt.toUtc()),
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
    }

    await insertDone('一月任务1', '2026-01-05', DateTime(2026, 1, 5, 8));
    await insertDone('一月任务2', '2026-01-15', DateTime(2026, 1, 15, 9));
    await insertDone('二月任务', '2026-02-10', DateTime(2026, 2, 10, 10));

    await pumpApp(tester);
    await openCalendar(tester);

    // 切到年视图。
    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();

    // 标题 + 12 个月格。
    expect(find.text('2026年'), findsOneWidget);
    expect(find.text('1 月'), findsOneWidget);
    expect(find.text('12 月'), findsOneWidget);
    // 完成数文本（1 月 2 个、2 月 1 个）。
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('完成'), findsWidgets);

    // 点 2 月格 → 下钻到月视图 2026年2月。
    await tester.tap(find.text('2 月'));
    await tester.pumpAndSettle();
    expect(find.text('2026年2月'), findsOneWidget);
  });

  testWidgets('周视图勾选任务后即时刷新（回归：invalidatePlanData 补上 tasksByWeek）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '周三任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 切到周视图（8/3~8/9）。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    // 选中周三 8/5：任务出现在周格任务条预览 + 选日面板（两处）。
    await tester.tap(find.text('5').first);
    await tester.pumpAndSettle();
    expect(find.text('周三任务'), findsWidgets);

    // 勾选前：8/5 周格聚合 0/1。
    expect(find.text('0/1'), findsOneWidget);

    // 勾选完成。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    // 勾选后：8/5 周格聚合即时更新为 1/1。
    // （此前 tasksByWeekProvider 未纳入失效清单，周视图在勾选后保持陈旧，
    //   2026-08-15 审查 #4；invalidatePlanData 补上后此回归通过。）
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('0/1'), findsNothing);
  });

  testWidgets('「回到今天」从周/年视图回当前单元', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await pumpApp(tester);
    await openCalendar(tester);

    // 周视图切到上一周，出现「回到今天」，点击回本周。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一单元'));
    await tester.pumpAndSettle();
    expect(find.text('回到今天'), findsOneWidget);
    await tester.tap(find.text('回到今天'));
    await tester.pumpAndSettle();
    expect(find.textContaining('8月3日'), findsOneWidget);
    expect(find.textContaining('第'), findsOneWidget);

    // 年视图切到上一年，回到今天回 2026。
    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一单元'));
    await tester.pumpAndSettle();
    expect(find.text('2025年'), findsOneWidget);
    await tester.tap(find.text('回到今天'));
    await tester.pumpAndSettle();
    expect(find.text('2026年'), findsOneWidget);
  });
}
