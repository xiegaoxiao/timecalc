import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
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
/// - 热力图：按完成日期统计的格子 tooltip、图例、空态
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
    final todayTodo = await tasks.create(
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
    expect(todayTodo.id, isNotNull);

    await pumpApp(tester);
    await openProgress(tester);

    // 完成 1/2 · 已完成 1 小时 · 目标剩余 2 小时
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('1 小时'), findsOneWidget);
    expect(find.text('目标剩余工作量 2 小时'), findsOneWidget);
  });

  testWidgets('热力图按完成日期统计并展示 tooltip（FR-7.2）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 直接写入带完成时间的已完成任务：completedAt 为 fixedNow 的 UTC，
    // 渲染时换算回本地日期 2026-08-05，tooltip 可确定断言。
    final now = fixedNow.toUtc();
    await db.into(db.tasks).insert(TasksCompanion.insert(
          goalId: goal.id,
          title: 'A',
          plannedDate: '2026-08-01',
          status: const Value('done'),
          completedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));
    await db.into(db.tasks).insert(TasksCompanion.insert(
          goalId: goal.id,
          title: 'B',
          plannedDate: '2026-08-01',
          status: const Value('done'),
          completedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));

    await pumpApp(tester);
    await openProgress(tester);

    // 热力图标题与图例文本存在（非颜色提示）。
    expect(find.text('完成热力图'), findsOneWidget);
    expect(find.text('1-2'), findsOneWidget);
    expect(find.text('少'), findsOneWidget);
    expect(find.text('多'), findsOneWidget);

    // 完成日期格子 tooltip。
    expect(find.byTooltip('2026-08-05 完成 2 项'), findsOneWidget);
  });

  testWidgets('无完成记录时展示空态与说明（FR-7.2 / PRD §8）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '未完成任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);
    await openProgress(tester);

    expect(find.text('还没有完成记录'), findsOneWidget);
    // FR-7.4 说明文本。
    expect(
      find.textContaining('无预估时长的任务只计入任务数'),
      findsOneWidget,
    );
    expect(find.text('完成热力图'), findsOneWidget);
  });
}
