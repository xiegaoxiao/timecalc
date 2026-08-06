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
    expect(find.text('目标剩余工作量'), findsOneWidget);
    expect(find.text('2 小时'), findsOneWidget);
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
    // 甘特图空态在下方固定区（Expanded），说明文字固定页面底部，
    // 无需滚动即可断言（进度页改为「上半滚动 + 甘特图固定拉伸」布局）。
    expect(find.text('还没有带预估时长的任务安排'), findsOneWidget);
    // FR-7.4 说明文本。
    expect(
      find.textContaining('无预估时长的任务只计入任务数'),
      findsOneWidget,
    );
    expect(find.text('完成热力图'), findsOneWidget);
    expect(find.text('任务耗时甘特图'), findsOneWidget);
  });

  testWidgets('甘特图最忙周条形不溢出（回归：planned+completed 达最大值）',
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

    // 最忙周两段条形高度之和等于 (maxBarHeight - minBarHeight)，不应触发
    // RenderFlex overflow。pump 后无未处理异常即视为通过。
    expect(tester.takeException(), isNull);
    expect(find.text('任务耗时甘特图'), findsOneWidget);
  });

  testWidgets('宽屏下卡片随窗口宽度拉伸，甘特图/热力图消除右侧留白（布局回归）',
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
    // 卡片宽度铺满容器（两侧仅约 5% 边距），即约 95% 屏宽以上。
    expect(overviewBox.width, greaterThan(1600 * 0.9));

    // 热力图卡片同样铺满，且色块随宽度放大（工具提示存在即已渲染）。
    final heatCard = find.widgetWithText(Card, '完成热力图');
    final heatBox = tester.getRect(heatCard);
    expect(heatBox.width, greaterThan(1600 * 0.9));

    // 甘特图无 RenderFlex overflow（宽屏等分拉伸）。
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口高度增大时甘特图行随纵向拉伸，且整页可滚动查看底部（布局回归）',
      (tester) async {
    // 4 个目标（各带计划任务）：行高 = 窗口高度×45%/4，未达上限时
    // 窗口拉高 → 行高/卡高增大。
    for (final name in ['考研', '论文', '雅思', '驾照']) {
      final goal = await goals.create(title: name, deadlineDate: '2026-12-31');
      await tasks.create(
        goalId: goal.id,
        title: '$name 任务',
        plannedDate: '2026-08-05',
        estimatedMinutes: 120,
      );
    }

    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpApp(tester);
    await openProgress(tester);
    final shortHeight =
        tester.getRect(find.widgetWithText(Card, '任务耗时甘特图')).height;

    // 拉高窗口 → 甘特图行高随窗口增大（卡高增大），不再是固定小尺寸。
    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpAndSettle();
    final tallHeight =
        tester.getRect(find.widgetWithText(Card, '任务耗时甘特图')).height;
    expect(tallHeight, greaterThan(shortHeight + 80));

    // 整页纵向滚动可达底部说明文字（甘特图未被固定/截断）。
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
}
