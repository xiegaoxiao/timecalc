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
    await tasks.create(
      goalId: goal.id,
      title: '任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );
    await tasks.create(
      goalId: goal.id,
      title: '任务B',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );

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
    // 联动：过期任务区块与红条一并消失。
    expect(find.text('过期任务'), findsNothing);
    final fetched = await tasks.byId(old.id);
    expect(fetched?.plannedDate, '2026-08-06');
    expect(fetched?.originalPlannedDate, '2026-08-04');
  });

  testWidgets('过期任务区块：逐条展示标题与已逾期天数，今日任务不在其中', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );
    await tasks.create(
      goalId: goal.id,
      title: '今日任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);

    expect(find.text('过期任务'), findsOneWidget);
    expect(find.text('1 个未处理'), findsOneWidget);
    expect(find.text('原计划 2026-08-04 · 已逾期 1 天'), findsOneWidget);
    // 过期任务标题在页面上；今日任务在区块下方，滚动后再断言。
    expect(find.text('昨日任务'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('今日任务A'), 100);
    expect(find.text('今日任务A'), findsOneWidget);
  });

  testWidgets('无过期任务时区块隐藏', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '今日任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);

    expect(find.text('过期任务'), findsNothing);
    expect(find.textContaining('已逾期'), findsNothing);
  });

  testWidgets('区块内完成过期任务后区块与红条联动消失（FR-3.7 扩展）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final old = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);
    expect(find.text('过期任务'), findsOneWidget);
    expect(find.text('昨日及更早有 1 个未完成任务'), findsOneWidget);

    // 区块内 TaskTile 的完成复选框。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(find.text('过期任务'), findsNothing);
    expect(find.text('昨日及更早有 1 个未完成任务'), findsNothing);
    expect((await tasks.byId(old.id))?.status, 'done');
  });

  testWidgets('区块内单个任务可经菜单延期，联动刷新（FR-3.7 扩展）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final old = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);

    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    // 菜单项与红条按钮同名，用 PopupMenuItem 精确匹配菜单项。
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '延期至下一可用日'));
    await tester.pumpAndSettle();

    expect(find.text('过期任务'), findsNothing);
    expect(find.text('昨日及更早有 1 个未完成任务'), findsNothing);
    final fetched = await tasks.byId(old.id);
    expect(fetched?.plannedDate, '2026-08-06');
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
    await tasks.create(
      goalId: goalA.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );
    await tasks.create(
      goalId: goalB.id,
      title: '写引言',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);

    expect(find.text('背单词'), findsOneWidget);
    // 列表较长时第二个任务在视口外，滚动后再断言。
    await tester.scrollUntilVisible(find.text('写引言'), 100);
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

  testWidgets('删除目标后今天页任务立即消失（回归：级联删除跨页刷新）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);
    // 今天页初始展示该任务。
    expect(find.text('背单词'), findsOneWidget);
    expect(find.text('今日任务总计 1 小时 30 分'), findsOneWidget);

    // 切到计划页，删除目标（二次确认）。
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目标操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    // 回到今天页：任务与负载卡都不再显示。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('今天'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('背单词'), findsNothing);
    expect(find.textContaining('今日任务总计'), findsNothing);
  });

  testWidgets('FR-3.7 横幅不被空态遮蔽：无活跃目标+无今日任务但有逾期任务（回归）', (tester) async {
    // 目标已放弃（不参与倒计时），仅剩昨日未完成任务。
    await goals.create(title: '考研', deadlineDate: '2026-08-03');
    await goals.update(id: 1, status: 'abandoned');
    await tasks.create(
      goalId: 1,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);

    // 修复前：空态早退导致 FR-3.7 横幅不显示，逾期任务不可见。
    // 逾期任务以横幅形式呈现（任务本身属于昨日，不在今日列表）。
    expect(find.text('昨日及更早有 1 个未完成任务'), findsOneWidget);
    // 仍处于正常页面结构（今日任务区块存在），而非外层全页空态。
    expect(find.text('今日任务'), findsOneWidget);
  });

  testWidgets('空态快捷添加后今日列表立即出现新任务（回归：await 后刷新）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    expect(find.text('今天没有安排'), findsOneWidget);

    // 空态内的「添加任务」按钮（FilledButton.icon）。
    await tester.tap(find.widgetWithText(FilledButton, '添加任务'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '空态新增任务');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 修复前：invalidate 早于数据写入，新任务不会出现在列表中。
    expect(find.text('空态新增任务'), findsOneWidget);
  });
}
