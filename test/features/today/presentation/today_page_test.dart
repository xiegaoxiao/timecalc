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
import 'package:timecalc/features/tasks/presentation/task_tile.dart';
import 'package:timecalc/shared/widgets/completion_checkbox.dart';

import '../../../shared/nav_helper.dart';

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
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  testWidgets('首页在紧凑窗口和桌面窗口下无布局溢出，今日任务优先展示', (tester) async {
    final goal = await goals.create(title: '研究生入学准备计划', deadlineDate: '2026-12-31');
    await tasks.create(goalId: goal.id, title: '今日阅读', plannedDate: '2026-08-05', estimatedMinutes: 90);
    await tasks.create(goalId: goal.id, title: '补充笔记', plannedDate: '2026-08-04', estimatedMinutes: 30);
    await pumpApp(tester);
    expect(tester.getTopLeft(find.text('今日任务')).dy,
        lessThan(tester.getTopLeft(find.text('过期任务')).dy));
    for (final width in [520.0, 900.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('今日任务展示，勾选即时完成，负载归零（FR-3.2）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);

    expect(find.text('背单词'), findsOneWidget);
    // 负载概览仪表盘化（2026-08-16）：整句文案改为指标格 label + value，
    // 时长值与任务行时长 chip 可能同文案，用 findsWidgets。
    expect(find.text('今日总计'), findsOneWidget);
    expect(find.text('1 小时 30 分'), findsWidgets);
    expect(find.text('今日可用'), findsOneWidget);
    expect(find.text('2 小时'), findsWidgets);

    // 勾选：立即反馈为勾选态并写库完成（3afc8ac 起设计——今日任务即时完成，
    // 不进入 5 秒撤回批次，FAB 不出现）。
    await tester.tap(find.byType(CompletionCheckbox));
    // confirmCompleteTask（检查项查询）与 setDone 都是真实 DB IO，runAsync 推进。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox)).value, isTrue);
    expect(find.byTooltip('撤回 1 项勾选'), findsNothing); // 无批次，FAB 不出现
    expect((await tasks.byId(created.id))?.status, 'done'); // 已写库完成
    expect(find.text('0 分'), findsWidgets); // 今日总计/目标剩余均归零
    expect(find.text('背单词'), findsOneWidget);
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

    expect(find.text('2 小时 30 分'), findsWidgets);
    expect(find.text('2 小时'), findsWidgets);
    expect(find.text('超出 30 分'), findsOneWidget);
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

  testWidgets('区块内完成过期任务：5 秒撤回窗口内保持显示，定稿后区块与红条联动消失（FR-3.7 扩展）', (tester) async {
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

    // 区块内 TaskTile 的完成复选框（今日概览常驻后区块在首屏外，先滚动）。
    final checkbox = find.byType(CompletionCheckbox);
    await tester.ensureVisible(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(checkbox);
    await tester.pump();

    // 撤回窗口内：任务保持勾选显示，区块与红条仍在，数据库仍 todo。
    expect(find.text('过期任务'), findsOneWidget);
    expect(find.text('昨日及更早有 1 个未完成任务'), findsOneWidget);
    expect((await tasks.byId(old.id))?.status, 'todo');

    // 5 秒定稿：过期任务从区块与红条中消失（联动）。
    await tester.pump(const Duration(seconds: 5));
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

    // 区块在首屏外（今日概览常驻后），先滚动再打开任务菜单。
    final more = find.byTooltip('任务操作');
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
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
    // 今日页含倒计时卡 + 负载卡，默认 600px 视口下任务列表被推出视口外
    //（ProgressiveRows 懒加载不构建），加大视口让任务首屏可见。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
    // 副标题 chips 化（2026-08-16）：目标名/时长为任务行内的独立 chip，
    // 以 TaskTile 为界断言（目标名同时出现在倒计时卡标题上）。
    expect(
      find.descendant(of: find.byType(TaskTile), matching: find.text('考研')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(TaskTile),
        matching: find.text('1 小时 30 分'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(TaskTile), matching: find.text('论文')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(TaskTile), matching: find.text('1 小时')),
      findsOneWidget,
    );
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

    // 有科目的任务展示「目标 / 科目 / 时长」三个 chip（两个任务同属
    // 「考研」，目标 chip 各出现一次）。
    expect(
      find.descendant(of: find.byType(TaskTile), matching: find.text('考研')),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: find.byType(TaskTile), matching: find.text('数学')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(TaskTile),
        matching: find.text('1 小时 30 分'),
      ),
      findsOneWidget,
    );
    // 无科目的任务没有科目 chip（时长 chip 仍在）。
    expect(
      find.descendant(of: find.byType(TaskTile), matching: find.text('30 分')),
      findsOneWidget,
    );
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
    expect(find.text('今日总计'), findsOneWidget);
    expect(find.text('1 小时 30 分'), findsWidgets);

    // 切到目标页，删除目标（二次确认）。
    await tapNavDestination(tester, '目标');
    await tester.tap(find.byTooltip('目标操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    // 回到今天页：任务与负载卡都不再显示。
    await tapNavDestination(tester, '今天');
    expect(find.text('背单词'), findsNothing);
    expect(find.text('今日负载'), findsNothing);
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

  testWidgets('有活跃目标无任务时：今日概览显示 -- 数据 + 空态引导 + 无重复入口', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);

    // 今日概览常驻（有活跃目标即显示）：无任务用 `--` 无数据语义。
    expect(find.text('今日总计'), findsOneWidget);
    expect(find.text('-- 分'), findsWidgets); // 今日总计/目标剩余均为 --
    expect(find.text('--'), findsOneWidget); // 进度环中心
    expect(find.text('目标剩余'), findsOneWidget);

    // 空态 + 引导小字；标题行不再出现重复的右上角「添加任务」。
    expect(find.text('今天没有安排'), findsOneWidget);
    expect(find.text('小提示：可以在「计划」页按周批量添加学习任务'), findsOneWidget);
    expect(find.text('添加任务'), findsOneWidget); // 仅空态大按钮一个入口
  });

  testWidgets('目标卡片展示时间进度条与「约 N 个学习日」', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);

    // 学习日剩余（固定时钟 2026-08-05 周三，默认每周 7 天全可用）。
    expect(find.textContaining('约 '), findsOneWidget);
    expect(find.textContaining('个学习日'), findsOneWidget);

    // 时间进度条（LinearProgressIndicator）已渲染。
    expect(find.byType(LinearProgressIndicator), findsWidgets);
  });

  testWidgets('「延期到指定日期」禁止改期到过去（firstDate=今天，回归 #1）',
      (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '过期任务',
      plannedDate: '2026-08-03', // 昨天，逾期
    );

    await pumpApp(tester);

    // 过期任务在首屏外（今日概览常驻后），先滚动再打开任务菜单。
    final more = find.byTooltip('任务操作');
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '延期…'));
    await tester.pumpAndSettle();

    // 与今日页 FR-3.7 横幅同口径（L40）：下界 = 今天，不再允许改期到过去。
    final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
    expect(picker.firstDate, DateTime(2026, 8, 5)); // 今天（注入时钟）
  });

  testWidgets('过期任务勾选后 5 秒内可整批撤回：任务恢复未勾选、数据库保持 todo', (tester) async {
    // 主任务即时完成（无批次）；5 秒撤回批次仅服务过期任务区。此用例验证
    // 批次撤回机制，故用昨日任务（进过期任务区）。
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);

    final checkbox = find.byType(CompletionCheckbox);
    await tester.ensureVisible(checkbox);
    await tester.pump();
    await tester.tap(checkbox);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox)).value, isTrue);
    // 右下角撤回 FAB（v1.11 起替代 SnackBar）。
    expect(find.byTooltip('撤回 1 项勾选'), findsOneWidget);

    // 点撤回：任务恢复未勾选、数据库仍 todo、FAB 收起、负载不变。
    // 撤回后 FAB 的倒计时 _controller 仍在播放，不能用 pumpAndSettle。
    await tester.tap(find.byTooltip('撤回 1 项勾选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox)).value, isFalse);
    expect(find.byTooltip('撤回 1 项勾选'), findsNothing);
    expect((await tasks.byId(created.id))?.status, 'todo');
    expect(find.text('1 小时 30 分'), findsWidgets);
  });

  testWidgets('撤回 FAB 倒计时圆环：5 秒窗口内收缩，到时定稿完成', (tester) async {
    // 批次机制仅服务过期任务区（主任务即时完成）。
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);

    final checkbox = find.byType(CompletionCheckbox);
    await tester.ensureVisible(checkbox);
    await tester.pump();
    await tester.tap(checkbox);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 初始：FAB 显示，倒计时圆环满环（value 接近 1 = 刚开始收缩）。
    expect(find.byTooltip('撤回 1 项勾选'), findsOneWidget);
    // 圆环是 FAB 的 Stack 首层（Tooltip 只包中央按钮），经 Tooltip 的
    // 祖先链定位：ancestor(of: tooltip) 里唯一 56×56 SizedBox 即 FAB 外壳。
    final fabBox = find.ancestor(
      of: find.byTooltip('撤回 1 项勾选'),
      matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 56 && w.height == 56,
      ),
    );
    CircularProgressIndicator ringOf() => tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: fabBox,
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(ringOf().value, greaterThan(0.8)); // 刚勾选不久，环几乎满

    // 时间推移：圆环收缩（value 减小）。
    await tester.pump(const Duration(seconds: 3));
    expect(ringOf().value, lessThan(0.8));

    // 第 5 秒定稿：任务完成、FAB 消失。
    await tester.pump(const Duration(seconds: 3));
    // finalize 里 setDoneMany 是真实 DB 写库，runAsync 推进；随后定步长
    // pump 处理刷新（FAB 已消失，无持续动画，但仍避免 pumpAndSettle 卡计时）。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect((await tasks.byId(created.id))?.status, 'done');
    expect(find.byTooltip('撤回 1 项勾选'), findsNothing);
    // 收尾：等 FAB 倒计时 _controller 彻底播完，避免测试结束时有 pending timer。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('5 秒内勾选多个任务：可整批撤回，全部恢复未勾选', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 批次机制仅服务过期任务区（主任务即时完成），用昨日任务进入该区。
    await tasks.create(goalId: goal.id, title: '任务A', plannedDate: '2026-08-04', estimatedMinutes: 30);
    await tasks.create(goalId: goal.id, title: '任务B', plannedDate: '2026-08-04', estimatedMinutes: 30);

    await pumpApp(tester);

    await tester.tap(find.byType(CompletionCheckbox).at(0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(CompletionCheckbox).at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 同一 5 秒窗口内的多次勾选并入同一批次，右下角撤回 FAB 显示总数。
    expect(find.byTooltip('撤回 2 项勾选'), findsOneWidget);
    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox).at(0)).value, isTrue);
    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox).at(1)).value, isTrue);

    // 整批撤回：两任务全部恢复未勾选，数据库仍 todo。
    // 撤回后 FAB 倒计时 _controller 仍在播放，不能用 pumpAndSettle。
    await tester.tap(find.byTooltip('撤回 2 项勾选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox).at(0)).value, isFalse);
    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox).at(1)).value, isFalse);
    final list = await tasks.byDate('2026-08-04');
    expect(list.every((t) => t.status == 'todo'), isTrue);
  });

  testWidgets('5 秒内勾选多个任务且未撤回：到期全部完成', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final a = await tasks.create(goalId: goal.id, title: '任务A', plannedDate: '2026-08-04', estimatedMinutes: 30);
    final b = await tasks.create(goalId: goal.id, title: '任务B', plannedDate: '2026-08-04', estimatedMinutes: 30);

    await pumpApp(tester);

    await tester.tap(find.byType(CompletionCheckbox).at(0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(CompletionCheckbox).at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byTooltip('撤回 2 项勾选'), findsOneWidget);

    // 无撤回：5 秒后整批定稿为完成。过期任务定稿后区块消失（设计），
    // 以 DB 状态与 FAB 消失为验证点。
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect((await tasks.byId(a.id))?.status, 'done');
    expect((await tasks.byId(b.id))?.status, 'done');
    expect(find.byTooltip('撤回 2 项勾选'), findsNothing);
    expect(find.text('过期任务'), findsNothing); // 区块随定稿消失
    // 收尾：等 FAB 倒计时 _controller 彻底播完，避免 pending timer。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('过期任务勾选后撤回：区块与红条保留，任务恢复未勾选', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final old = await tasks.create(
      goalId: goal.id,
      title: '昨日任务',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);
    expect(find.text('过期任务'), findsOneWidget);

    final checkbox = find.byType(CompletionCheckbox);
    await tester.ensureVisible(checkbox);
    await tester.pump();
    await tester.tap(checkbox);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // FAB 滑入（倒计时动画中不能用 pumpAndSettle）

    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox)).value, isTrue);

    await tester.tap(find.byTooltip('撤回 1 项勾选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 撤回后：过期任务仍在区块与红条中，且恢复未勾选、数据库 todo。
    expect(find.text('过期任务'), findsOneWidget);
    expect(find.text('昨日及更早有 1 个未完成任务'), findsOneWidget);
    expect(tester.widget<CompletionCheckbox>(find.byType(CompletionCheckbox)).value, isFalse);
    expect((await tasks.byId(old.id))?.status, 'todo');
  });
}
