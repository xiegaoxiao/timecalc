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

/// 日历视图 Widget 测试（FR-3.4 / checklists §11 M2）。
///
/// 固定时钟 2026-08-05（周三），验证：
/// - 月历网格聚合展示（任务数/完成数/预估时长/超出）
/// - 点击选日展示当日任务（FR-3.2）
/// - 历史日期补录任务（FR-3.6 顺带覆盖）
/// - 日历内完成/延期后聚合同步更新
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

  /// 切到「计划」页并选中「日历」分段。
  Future<void> openCalendar(WidgetTester tester) async {
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历'));
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

  testWidgets('月历展示每日任务数、完成数和预估总时长（FR-3.4）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: 'A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );
    await tasks.create(
      goalId: goal.id,
      title: 'B',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );
    final doneTask = await tasks.create(
      goalId: goal.id,
      title: 'C',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );
    await tasks.setDone(doneTask.id, true);

    await pumpApp(tester);
    await openCalendar(tester);

    // 08-05 单元格：完成 1/总数 3、未完成负载 150 分、超出可用 120 分钟 30 分钟。
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('2h30m'), findsOneWidget);
    expect(find.text('超出30m'), findsOneWidget);
  });

  testWidgets('无任务日期保持中性（不显示 0/0 或过载）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: 'A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 08-05 有任务；08-06 无任务格不渲染任何任务文本。
    expect(find.text('1h30m'), findsOneWidget);
    expect(find.text('0/0'), findsNothing);
  });

  testWidgets('点击日期在选日面板展示当日任务并可完成任务（FR-3.2）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '八五任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );
    await tasks.create(
      goalId: goal.id,
      title: '八六任务',
      plannedDate: '2026-08-06',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 默认选中今天（08-05），面板展示当日任务。
    expect(find.text('八五任务'), findsOneWidget);
    expect(find.text('八六任务'), findsNothing);

    // 点击 08-06 日格。
    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();
    expect(find.text('八六任务'), findsOneWidget);
    expect(find.text('八五任务'), findsNothing);
    // 回归：面板标题与网格高亮绑定同一选中日（08-06 为周四），
    // 防止「高亮 9 号却显示 18 号」的错位。
    expect(find.text('2026-08-06 星期四'), findsOneWidget);

    // 在选日面板完成任务，聚合同步更新（1/1）。
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);
  });

  testWidgets('可为历史日期补录任务（FR-3.6 顺带覆盖）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openCalendar(tester);

    // 点击上个月某一天（如 7 月 15 日）：先切到上一月。
    await tester.tap(find.byTooltip('上一月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('添加任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '补录任务');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('补录任务'), findsOneWidget);
    final list = await tasks.byDate('2026-07-15');
    expect(list.single.title, '补录任务');
    expect(list.single.goalId, goal.id);
  });

  testWidgets('选日面板可快捷延期至下一可用日（FR-3.3）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '待延期',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    await tester.ensureVisible(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('延期至下一可用日'));
    await tester.pumpAndSettle();

    // 08-05 选日面板不再显示该任务，原计划日期已记录。
    expect(find.text('待延期'), findsNothing);
    final fetched = await tasks.byId(created.id);
    expect(fetched?.plannedDate, '2026-08-06');
    expect(fetched?.originalPlannedDate, '2026-08-05');
  });

  testWidgets('日历与今天页数据一致：日历完成今日任务后今天页负载更新', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '共享任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 150,
    );

    await pumpApp(tester);
    await openCalendar(tester);
    expect(find.text('超出30m'), findsOneWidget);

    // 在日历选日面板完成任务。
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('超出30m'), findsNothing);

    // 回到今天页：负载归零，无「超出」提示。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('今天'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今日任务总计 0 分'), findsOneWidget);
    expect(find.text('可用 2 小时'), findsOneWidget);
  });

  testWidgets('今天页完成任务后日历格负载与超出同步更新（跨页一致）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '共享任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 150,
    );

    await pumpApp(tester);
    // 今天页：150 分超可用 120 分。
    expect(find.text('超出 30 分，请调整任务或可用时间'), findsOneWidget);

    // 在今天页完成任务。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('今日任务总计 0 分'), findsOneWidget);

    // 切到日历：该日格应同步为已完成状态，不再显示「超出」。
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('超出30m'), findsNothing);
  });

  testWidgets('FR-5.1：长按任务拖到另一天改期并记录原计划日期', (tester) async {
    // 日历网格与选日面板在 800x600 视口下无法同时可见（间距 > 视口高），
    // 放大测试表面使两者共存（真实窗口同理：拖动需目标格与任务同在可视区）。
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final task = await tasks.create(
      goalId: goal.id,
      title: '拖动任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 选日面板默认选中今天（08-05），任务出现在面板中。
    expect(find.text('拖动任务'), findsOneWidget);

    // 长按任务条目激活 LongPressDraggable，再移动到网格中「6」日格放置。
    final start = tester.getCenter(find.text('拖动任务'));
    final target = tester.getCenter(find.text('6')); // 08-06 日格
    expect(target.dy, greaterThan(0), reason: '目标日格应在可视区域内');

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 700)); // 长按阈值
    // 分段移动，让 DragTarget 正确进入候选区并命中放置。
    const steps = 10;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(start, target, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // 改期成功：原计划日期已记录，计划日期为新日期（FR-3.3 验收）。
    final fetched = await tasks.byId(task.id);
    expect(fetched?.plannedDate, '2026-08-06');
    expect(fetched?.originalPlannedDate, '2026-08-05');
    expect(fetched?.title, '拖动任务');
    expect(fetched?.estimatedMinutes, 30);
  });

  testWidgets('空选日空态提供「去添加任务」CTA 并可打开快速表单（引导态）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 默认选中今天（08-05）但没有任务：空态展示引导按钮。
    await pumpApp(tester);
    await openCalendar(tester);

    expect(find.text('这一天没有任务'), findsOneWidget);
    expect(find.text('去添加任务'), findsOneWidget);

    // 点击 CTA：打开所选日期（今天）的快速添加表单（先滚动到可视区）。
    final cta = find.text('去添加任务');
    await tester.ensureVisible(cta);
    await tester.pumpAndSettle();
    await tester.tap(cta);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Dialog, '添加任务'), findsOneWidget);

    // 取消关闭（不落库）。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(goal.id, greaterThan(0));
  });
}
