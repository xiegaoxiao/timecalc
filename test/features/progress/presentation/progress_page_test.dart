import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fl_chart/fl_chart.dart';
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

/// 进度页 Widget 测试（FR-7.1 / FR-7.2 / FR-7.3 / FR-7.4）。
///
/// 固定时钟 2026-08-05（周三），验证：
/// - 今日概览：完成数/总数、已完成时长、目标剩余工作量（FR-7.1）
/// - 热力图：LeetCode 图例文本、tooltip、无完成记录时全灰网格（无空态）
/// - 任务耗时图：按周堆叠条形（M7 迭代，fl_chart 重构）
/// - 燃尽趋势：剩余预估时长曲线（FR-7.3）
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

  /// 展开底部折叠的「数据统计说明」（默认折叠，断言说明文本前先点开）。
  Future<void> expandNote(WidgetTester tester) async {
    final toggle = find.text('数据统计说明');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  /// 在指定 UTC 时刻完成一项带时长的任务（供热力图/任务耗时图断言）。
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

    // 完成 1/2 · 已完成 1 小时 · 目标剩余 2 小时（燃尽图 Y 轴也会出现
    // 「2 小时」刻度，故限定在今日概览卡内断言）。
    final overviewCard = find.widgetWithText(Card, '今日概览');
    expect(find.text('1/2'), findsOneWidget);
    // 已完成时长「1 小时」也出现在任务耗时图 Y 轴刻度，限定在概览卡内断言。
    expect(
      find.descendant(of: overviewCard, matching: find.text('1 小时')),
      findsOneWidget,
    );
    expect(find.text('目标剩余工作量'), findsOneWidget);
    expect(
      find.descendant(of: overviewCard, matching: find.text('2 小时')),
      findsOneWidget,
    );
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

  testWidgets('任务耗时图展示未来计划与已完成时长（M7 迭代）', (tester) async {
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

    expect(find.text('任务耗时图'), findsOneWidget);
    expect(find.textContaining('按周展示未来计划与已完成时长'), findsOneWidget);
    // fl_chart 堆叠条形图已渲染（数据正确性由 statistics_service_test 保证）。
    expect(find.byType(BarChart), findsOneWidget);
    // 图例（在任务耗时图 Card 内断言，避免与底部导航「计划」标签歧义）。
    final chartCard = find.widgetWithText(Card, '任务耗时图');
    expect(
      find.descendant(of: chartCard, matching: find.text('计划')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chartCard, matching: find.text('完成')),
      findsOneWidget,
    );
  });

  testWidgets('无完成记录时热力图仍渲染全灰网格，耗时图展示空态（FR-7.2 / PRD §8）',
      (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 无预估时长的任务不计入任务耗时图（FR-7.4），展示空态。
    await tasks.create(
      goalId: goal.id,
      title: '未完成任务',
      plannedDate: '2026-08-05',
    );

    await pumpApp(tester);
    await openProgress(tester);

    // 热力图不再展示空态：网格（含 0 档工具提示）与图例始终渲染。
    expect(find.text('还没有完成记录'), findsNothing);
    final heatCard = find.widgetWithText(Card, '完成热力图');
    expect(
      find.descendant(of: heatCard, matching: find.byTooltip('2026-08-05：完成 0 项')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: heatCard, matching: find.text('0')),
      findsOneWidget,
    );
    // 任务耗时图空态保留（带预估时长数据缺失，引导排期）。
    expect(find.text('还没有带预估时长的任务安排'), findsOneWidget);
    // FR-7.4 说明折叠在「数据统计说明」下，展开后断言。
    await expandNote(tester);
    expect(
      find.textContaining('无预估时长的任务只计入任务数'),
      findsOneWidget,
    );
    expect(find.text('完成热力图'), findsOneWidget);
    expect(find.text('任务耗时图'), findsOneWidget);
  });

  testWidgets('任务耗时图最忙周堆叠条不溢出（回归：planned+completed 达最大值）',
      (tester) async {
    final goal =
        await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 本周同时存在计划与完成，且二者合计为全局最大值，触发归一化满高。
    // 计划 120 分钟（2026-08-05 当周）；完成 120 分钟（同周）。
    await tasks.create(
      goalId: goal.id,
      title: '计划任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );
    await completeTask(
      goalId: goal.id,
      title: '完成任务',
      minutes: 120,
      completedAtUtc: fixedNow.toUtc(),
    );

    await pumpApp(tester);
    await openProgress(tester);

    // 堆叠条 toY 达最大值（maxY ×1.1 含余量），不应触发 RenderFlex
    // overflow。pump 后无未处理异常即视为通过。
    expect(tester.takeException(), isNull);
    expect(find.text('任务耗时图'), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
  });

  testWidgets('宽屏下卡片随窗口宽度拉伸，任务耗时图/热力图消除右侧留白（布局回归）',
      (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '计划任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );

    // 模拟宽屏（1600×900 桌面窗口）。
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpApp(tester);
    await openProgress(tester);

    // 今日概览三项数据同一行横向排布（宽屏下不换行）。
    final overviewCard = find.widgetWithText(Card, '今日概览');
    expect(overviewCard, findsOneWidget);
    final overviewBox = tester.getRect(overviewCard);
    // 卡片随窗口拉伸：宽窗走 NavigationRail 侧栏（约 80px），内容区宽度
    // ≈ 1600-80=1520，再扣 5% 边距（≤48px）后卡片仍应铺满内容区
    // （>1600*0.85，比旧式整宽断言更贴近真实布局）。
    expect(overviewBox.width, greaterThan(1600 * 0.85));

    // 热力图卡片同样铺满，且色块随宽度放大（工具提示存在即已渲染）。
    final heatCard = find.widgetWithText(Card, '完成热力图');
    final heatBox = tester.getRect(heatCard);
    expect(heatBox.width, greaterThan(1600 * 0.85));

    // 任务耗时图无 RenderFlex overflow（宽屏等分拉伸）。
    expect(tester.takeException(), isNull);
  });

  testWidgets('任务耗时图宽度自适应：宽屏铺满、窄窗横向滚动（布局回归）',
      (tester) async {
    // 4 个目标（各带计划任务）：26 周窗口下有多个有数据周。
    for (final name in ['考研', '论文', '雅思', '驾照']) {
      final goal = await goals.create(title: name, deadlineDate: '2026-12-31');
      await tasks.create(
        goalId: goal.id,
        title: '$name 任务',
        plannedDate: '2026-08-05',
        estimatedMinutes: 120,
      );
    }

    // 窄窗：图表最小宽度 > 可用宽度时出现横向滚动，不溢出。
    await tester.binding.setSurfaceSize(const Size(500, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpApp(tester);
    await openProgress(tester);
    expect(find.byType(BarChart), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 整页纵向滚动可达底部说明（图表未被固定/截断）：先展开折叠说明。
    await expandNote(tester);
    final caption = find.textContaining('无预估时长的任务只计入任务数');
    await tester.ensureVisible(caption);
    await tester.pumpAndSettle();
    expect(caption, findsOneWidget);

    // 无布局溢出。
    expect(tester.takeException(), isNull);
  });

  testWidgets('进度页顶部展示计划偏好入口卡（摘要 + 点击进入独立页）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openProgress(tester);

    // 入口卡默认摘要：每日可用 2 小时 · 每周 7 天。
    expect(find.text('计划偏好'), findsOneWidget);
    expect(find.text('每日可用 2 小时 · 每周 7 天'), findsOneWidget);

    // 点击进入独立偏好编辑页。
    await tester.tap(find.text('计划偏好'));
    await tester.pumpAndSettle();
    expect(find.text('每周可用日'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('燃尽趋势展示剩余预估时长、匀速参考线与图例（FR-7.3）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-08-19');
    // 当前未完成 120 分钟。
    await tasks.create(
      goalId: goal.id,
      title: '后续任务',
      plannedDate: '2026-08-10',
      estimatedMinutes: 120,
    );
    // 窗口内（本地 2026-08-01）完成 60 分钟。
    await completeTask(
      goalId: goal.id,
      title: '已完成任务',
      minutes: 60,
      completedAtUtc: DateTime.utc(2026, 8, 1, 12),
    );

    await pumpApp(tester);
    await openProgress(tester);

    expect(find.text('剩余工作量趋势'), findsOneWidget);
    // 白话结论句：过去 30 天消化 60 分钟（1 小时）、还剩 120 分钟（2 小时）。
    expect(
      find.textContaining('过去 30 天消化了 1 小时，还剩 2 小时'),
      findsOneWidget,
    );

    // Header 当前剩余 = today 点剩余 120（FR-7.1 口径一致）。
    expect(find.text('当前剩余'), findsOneWidget);
    final burnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(of: burnCard, matching: find.text('2 小时')),
      findsOneWidget,
    );

    // 图例（只在燃尽 Card 内断言，避免与热力图图例/底部导航歧义）。
    expect(
      find.descendant(of: burnCard, matching: find.text('剩余工作量')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: burnCard, matching: find.text('匀速参考线')),
      findsOneWidget,
    );

    // fl_chart 折线图已渲染（数据正确性由 statistics_service_test 保证）。
    expect(find.byType(LineChart), findsOneWidget);
    // FR-7.4 说明折叠在「数据统计说明」下，展开后断言。
    await expandNote(tester);
    expect(find.textContaining('无预估时长的任务只计入任务数'), findsOneWidget);
  });

  testWidgets('无带时长任务时燃尽图展示空态（FR-7.3 / FR-7.4）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 无预估时长的任务不计入燃尽图。
    await tasks.create(
      goalId: goal.id,
      title: '无时长任务',
      plannedDate: '2026-08-05',
    );

    await pumpApp(tester);
    await openProgress(tester);

    expect(find.text('剩余工作量趋势'), findsOneWidget);
    // 燃尽空态文案与甘特图空态区分，避免歧义。
    expect(find.text('还没有可展示的剩余工作量数据'), findsOneWidget);

    // 无带时长数据时 Header「当前剩余」显示灰 `-- 分`（与今日概览无数据
    // 语义一致），而不是绿色「0 分」（那是「全部完成」才有的状态）。
    final burnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(of: burnCard, matching: find.text('-- 分')),
      findsOneWidget,
    );
  });

  testWidgets('燃尽图 X 轴最右端标注「今天」，结论句含窗口消化时长', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-08-19');
    await tasks.create(
      goalId: goal.id,
      title: '后续任务',
      plannedDate: '2026-08-10',
      estimatedMinutes: 120,
    );
    await completeTask(
      goalId: goal.id,
      title: '已完成任务',
      minutes: 60,
      completedAtUtc: DateTime.utc(2026, 8, 1, 12),
    );

    await pumpApp(tester);
    await openProgress(tester);

    final burnCard = find.widgetWithText(Card, '剩余工作量趋势');
    // 结论句四种状态中的「有消化 + 有剩余」分支。
    expect(
      find.textContaining('过去 30 天消化了 1 小时'),
      findsOneWidget,
    );
    expect(
      find.textContaining('还剩 2 小时'),
      findsOneWidget,
    );
    // X 轴最右端标注「今天」。
    expect(
      find.descendant(of: burnCard, matching: find.text('今天')),
      findsOneWidget,
    );
  });

  testWidgets('无任务时今日概览显示 -- 而非 0（区分「没计划」与「已完成」）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 无任何任务：今日概览三项均显示「无数据」占位。
    await pumpApp(tester);
    await openProgress(tester);

    final overviewCard = find.widgetWithText(Card, '今日概览');
    expect(
      find.descendant(of: overviewCard, matching: find.text('-- / --')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overviewCard, matching: find.text('-- 分')),
      findsNWidgets(2), // 已完成时长 + 目标剩余工作量
    );
  });

  testWidgets('有进行中目标时燃尽/耗时图空态显示引导按钮', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 无带时长数据：燃尽/耗时图展示空态与 CTA（热力图无完成记录时
    // 渲染全灰网格，不放引导按钮）。
    await pumpApp(tester);
    await openProgress(tester);

    // 燃尽/耗时图：需要带预估时长的数据 → 「去设置预估时长」。
    expect(find.text('去设置预估时长'), findsNWidgets(2));
    expect(find.text('去添加任务'), findsNothing);

    // 点击燃尽图空态的 CTA：跳转计划页排期（归属于进行中目标）。
    final cta = find.text('去设置预估时长').first;
    await tester.ensureVisible(cta);
    await tester.pumpAndSettle();
    await tester.tap(cta);
    await tester.pumpAndSettle();
    // 已切到计划页：v1.12 起计划页即纯日历，选日面板标题含星期。
    expect(find.textContaining('星期三'), findsOneWidget);
  });

  testWidgets('无目标时燃尽/耗时图空态不显示引导按钮', (tester) async {
    // 没有任何目标（也没有任务）：热力图渲染全灰网格，燃尽/耗时图空态
    // 无可归属目标，CTA 不显示。
    await pumpApp(tester);
    await openProgress(tester);

    expect(find.text('还没有带预估时长的任务安排'), findsOneWidget);
    expect(find.text('去添加任务'), findsNothing);
    expect(find.text('去设置预估时长'), findsNothing);
  });

  testWidgets('点击热力图方块查看当天完成任务（FR-7.2 交互）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 科目：让任务行展示科目名（subjectListProvider 经 UI 查询）。
    final subject = await db.into(db.subjects).insert(SubjectsCompanion.insert(
          goalId: goal.id,
          name: '数学',
          color: '#3F6C51',
          createdAt: fixedNow.toUtc(),
          updatedAt: fixedNow.toUtc(),
        ));
    // 固定时钟 2026-08-05 当天完成两个任务（completedAt UTC → 本地同一天）。
    await db.into(db.tasks).insert(TasksCompanion.insert(
          goalId: goal.id,
          subjectId: Value(subject),
          title: '背单词',
          plannedDate: '2026-08-05',
          estimatedMinutes: const Value(30),
          status: const Value('done'),
          completedAt: Value(fixedNow.toUtc()),
          createdAt: fixedNow.toUtc(),
          updatedAt: fixedNow.toUtc(),
        ));
    await db.into(db.tasks).insert(TasksCompanion.insert(
          goalId: goal.id,
          title: '复盘错题',
          plannedDate: '2026-08-05',
          estimatedMinutes: const Value(60),
          status: const Value('done'),
          completedAt: Value(fixedNow.toUtc()),
          createdAt: fixedNow.toUtc(),
          updatedAt: fixedNow.toUtc(),
        ));

    await pumpApp(tester);
    await openProgress(tester);

    // 热力图今天格子（2026-08-05，含「完成 2 项」工具提示）可点击。
    final cell = find.byTooltip('2026-08-05：完成 2 项');
    expect(cell, findsOneWidget);
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    // 弹窗标题 + 当天完成的任务清单（标题、目标、科目、时长、完成时刻）。
    expect(find.text('2026-08-05 完成的任务'), findsOneWidget);
    expect(find.text('背单词'), findsOneWidget);
    expect(find.text('复盘错题'), findsOneWidget);
    expect(find.textContaining('考研 · 数学 · 30 分 · 完成于'), findsOneWidget);
    expect(find.textContaining('复盘错题'), findsOneWidget);
    // 关闭弹窗。
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('2026-08-05 完成的任务'), findsNothing);
  });

  testWidgets('点击无完成记录的灰色热力图方块提示当日无任务', (tester) async {
    // 没有任何完成任务：热力图全灰（0 档）。
    await pumpApp(tester);
    await openProgress(tester);

    // 点今天的灰格：弹窗显示「这一天没有完成任务」。
    final cell = find.byTooltip('2026-08-05：完成 0 项');
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.text('2026-08-05 完成的任务'), findsOneWidget);
    expect(find.text('这一天没有完成任务'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('新增任务后剩余工作量趋势与任务耗时图及时刷新（回归）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 初始剩余工作量 120 分钟。
    await tasks.create(
      goalId: goal.id,
      title: '原有任务',
      plannedDate: '2026-08-10',
      estimatedMinutes: 120,
    );

    await pumpApp(tester);
    await openProgress(tester);

    // 燃尽卡「当前剩余」= 2 小时；任务耗时图已有计划数据。
    final burnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(of: burnCard, matching: find.text('2 小时')),
      findsOneWidget,
    );
    expect(find.byType(BarChart), findsOneWidget);

    // 切到「今天」页，经真实 UI 路径快速添加一个 90 分钟任务
    // （保存后今日页走 invalidateAppData 全量刷新）。
    // 限定在导航内定位：燃尽图 X 轴也标注「今天」，直接 find.text 歧义。
    await tapNavDestination(tester, '今天');
    await tester.tap(find.text('添加任务').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '新增任务');
    // 时长默认「未设置」禁用输入，先点「无时长」启用，再步进到 1 小时 30 分。
    await tester.tap(find.text('无时长'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('小时加'));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip('分钟加'));
      await tester.pump();
    }
    expect(find.text('当前共 1 小时 30 分'), findsOneWidget);
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 今日页自身已刷新（任务出现在今日列表，证明 invalidate 已触发）。
    expect(find.text('新增任务'), findsOneWidget);

    // 切回「进度」页：剩余工作量应变为 120+90=210 分钟（3 小时 30 分）。
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();

    final refreshedBurnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(
        of: refreshedBurnCard,
        matching: find.text('3 小时 30 分'),
      ),
      findsWidgets,
    );
    // 结论句同步更新（白话文案走「还没完成 + 还剩」分支）。
    expect(
      find.textContaining('还剩 3 小时 30 分'),
      findsOneWidget,
    );
  });

  testWidgets('编辑任务（改预估时长）后剩余工作量趋势与任务耗时图及时刷新（回归）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 初始剩余工作量 120 分钟（今天，便于今日页直接编辑）。
    await tasks.create(
      goalId: goal.id,
      title: '待编辑任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );

    await pumpApp(tester);
    await openProgress(tester);

    // 燃尽卡「当前剩余」= 2 小时。
    final burnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(of: burnCard, matching: find.text('2 小时')),
      findsWidgets,
    );

    // 切到「今天」页，经真实 UI 路径编辑该任务：时长 +30 分钟。
    await tapNavDestination(tester, '今天');
    // 任务条目 trailing 的「任务操作」菜单 → 编辑。
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    // 任务表单时长快捷按钮 +30 分（showQuickButtons 开启）。
    await tester.tap(find.text('+30分'));
    await tester.pump();
    expect(find.text('当前共 2 小时 30 分'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 切回「进度」页：剩余工作量应变为 150 分钟（2 小时 30 分）。
    await tapNavDestination(tester, '进度');

    final refreshedBurnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(
        of: refreshedBurnCard,
        matching: find.text('2 小时 30 分'),
      ),
      findsWidgets,
    );
    // 结论句同步更新（还没完成 + 还剩分支）。
    expect(
      find.textContaining('还剩 2 小时 30 分'),
      findsOneWidget,
    );
  });
}
