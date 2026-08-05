import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 今天页每日执行闭环 Widget 测试（checklists §11 M2）。
///
/// 内存数据库 + 固定时钟（2026-08-05 周三）：
/// - 今日任务展示、完成同步、负载与「超出 X 分钟」（FR-3.2/FR-3.5/FR-5.2）
/// - 快捷延期至下一可用日（FR-3.3）
/// - FR-3.7 次日未完成任务集中提示（不自动改计划）
/// - 空态与快速添加（PRD §8）
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
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

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    subjects = SubjectRepository(db);
    tasks = TaskRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('今日任务展示，完成任务后负载与列表同步更新（FR-3.2/FR-5.2）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);

    expect(find.text('背单词'), findsOneWidget);
    expect(find.text('今日任务总计 1 小时 30 分'), findsOneWidget);
    expect(find.text('可用 2 小时'), findsOneWidget);

    // 完成任务：列表保留（划线），负载归零。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(find.text('今日任务总计 0 分'), findsOneWidget);
    expect(find.text('可用 2 小时'), findsOneWidget);
    expect((await tasks.byId(created.id))?.status, 'done');
  });

  testWidgets('当日负载超过可用时长时显示「超出 X 分钟」（FR-3.5）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(goalId: goal.id, title: '任务A', plannedDate: '2026-08-05', estimatedMinutes: 90);
    await tasks.create(goalId: goal.id, title: '任务B', plannedDate: '2026-08-05', estimatedMinutes: 60);

    await pumpApp(tester);

    expect(find.text('今日任务总计 2 小时 30 分'), findsOneWidget);
    expect(find.text('可用 2 小时'), findsOneWidget);
    expect(find.text('超出 30 分，请调整任务或可用时间'), findsOneWidget);
  });

  testWidgets('任务可快捷延期至下一可用日（FR-3.3）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);
    expect(find.text('背单词'), findsOneWidget);

    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('延期至下一可用日'));
    await tester.pumpAndSettle();

    // 延期后从今日列表消失（移至 08-06），原计划日期已记录，内容保留。
    expect(find.text('背单词'), findsNothing);
    final fetched = await tasks.byId(created.id);
    expect(fetched?.plannedDate, '2026-08-06');
    expect(fetched?.originalPlannedDate, '2026-08-05');
    expect(fetched?.title, '背单词');
    expect(fetched?.estimatedMinutes, 90);
  });

  testWidgets('FR-3.7：昨日未完成任务集中提示，可批量延期至下一可用日', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final old = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);

    expect(find.text('昨日及更早有 1 个未完成任务'), findsOneWidget);
    expect(find.text('原计划不会被自动更改，请选择处理方式'), findsOneWidget);

    await tester.tap(find.text('延期至下一可用日'));
    await tester.pumpAndSettle();

    expect(find.text('昨日及更早有 1 个未完成任务'), findsNothing);
    final fetched = await tasks.byId(old.id);
    expect(fetched?.plannedDate, '2026-08-06');
    expect(fetched?.originalPlannedDate, '2026-08-04');
  });

  testWidgets('FR-3.7：保留原日期不改变任务计划（仅本会话关闭横幅）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final old = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);
    await tester.tap(find.text('保留原日期'));
    await tester.pumpAndSettle();

    expect(find.text('昨日及更早有 1 个未完成任务'), findsNothing);
    final fetched = await tasks.byId(old.id);
    expect(fetched?.plannedDate, '2026-08-04');
    expect(fetched?.originalPlannedDate, isNull);
  });

  testWidgets('今日页可快速添加任务（目标下拉默认首个进行中目标）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    expect(find.text('今天没有安排'), findsOneWidget);

    await tester.tap(find.text('添加任务').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '新背单词');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('新背单词'), findsOneWidget);
    final list = await tasks.byDate('2026-08-05');
    expect(list.single.goalId, goal.id);
  });

  testWidgets('今日任务跨目标展示并标注目标名（FR-1.5）', (tester) async {
    final goalA = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final goalB = await goals.create(title: '论文', deadlineDate: '2026-09-30');
    await tasks.create(goalId: goalA.id, title: '背单词', plannedDate: '2026-08-05', estimatedMinutes: 90);
    await tasks.create(goalId: goalB.id, title: '写引言', plannedDate: '2026-08-05', estimatedMinutes: 60);

    await pumpApp(tester);

    expect(find.text('背单词'), findsOneWidget);
    expect(find.text('写引言'), findsOneWidget);
    // 副标题标注目标名（考研卡片标题外，任务条目中也出现）。
    expect(find.textContaining('考研 · 1 小时 30 分'), findsOneWidget);
    expect(find.textContaining('论文 · 1 小时'), findsOneWidget);
  });

  testWidgets('今日任务条目展示归属科目名（FR-1.5）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final subject = await subjects.create(
      goalId: goal.id,
      name: '数学',
      color: '#112233',
    );
    await tasks.create(
      goalId: goal.id,
      subjectId: subject.id,
      title: '刷题',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );
    // 无科目任务作为对照。
    await tasks.create(
      goalId: goal.id,
      title: '复盘',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);

    // 有科目的任务展示「目标 · 科目 · 时长」。
    expect(find.textContaining('考研 · 数学 · 1 小时 30 分'), findsOneWidget);
    // 无科目的任务不展示科目段。
    expect(find.textContaining('考研 · 30 分'), findsOneWidget);
  });

  testWidgets('没有任务的日期不显示过载（空态中性）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);

    expect(find.text('今天没有安排'), findsOneWidget);
    expect(find.textContaining('今日 '), findsNothing);
    expect(find.textContaining('超出'), findsNothing);
  });
}
