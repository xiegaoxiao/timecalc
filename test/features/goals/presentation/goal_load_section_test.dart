import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

import '../../../shared/nav_helper.dart';

/// 目标详情负载区 + 设置计划偏好 Widget 测试（FR-5.3/FR-5.4/PRD §5.1）。
///
/// 固定时钟 2026-08-05（周三）。默认偏好：120 分钟/天、每周 7 天。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late SettingsRepository settings;
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
    tasks = TaskRepository(db);
    settings = SettingsRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  /// 进入指定目标的目标详情页。
  Future<void> openGoalDetail(WidgetTester tester, String title) async {
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  /// 进度页「计划偏好」入口卡 → 独立偏好编辑页（计划偏好已移出设置页）。
  Future<void> openPlanPreference(WidgetTester tester) async {
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('计划偏好'));
    await tester.pumpAndSettle();
  }

  testWidgets('目标详情展示剩余任务时长、剩余可用天数和建议日均时长（FR-5.3）', (tester) async {
    // 截止 08-08（周五），距 08-05 还有 4 天全可用；任务共 360 分钟。
    final goal = await goals.create(title: '考研', deadlineDate: '2026-08-08');
    await tasks.create(
      goalId: goal.id,
      title: '任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );
    await tasks.create(
      goalId: goal.id,
      title: '任务B',
      plannedDate: '2026-08-06',
      estimatedMinutes: 240,
    );

    await pumpApp(tester);
    await openGoalDetail(tester, '考研');

    expect(find.text('剩余任务时长：6 小时'), findsOneWidget);
    expect(find.text('剩余可用天数（学习日）：4 天'), findsOneWidget);
    expect(find.text('建议日均时长：1 小时 30 分 · 可用 2 小时/天'), findsOneWidget);
    // 建议日均未超可用时长，不显示计划风险。
    expect(find.textContaining('计划风险'), findsNothing);
  });

  testWidgets('建议日均超过每日可用时长时显示计划风险（FR-5.4）', (tester) async {
    // 任务量远超剩余可用天数可承载范围。
    final goal = await goals.create(title: '考研', deadlineDate: '2026-08-07');
    await tasks.create(
      goalId: goal.id,
      title: '任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 300,
    );
    await tasks.create(
      goalId: goal.id,
      title: '任务B',
      plannedDate: '2026-08-06',
      estimatedMinutes: 300,
    );

    await pumpApp(tester);
    await openGoalDetail(tester, '考研');

    // 剩余 3 天（08-05/06/07）共 600 分钟 -> 建议日均 200 > 120。
    expect(find.text('剩余任务时长：10 小时'), findsOneWidget);
    expect(find.text('建议日均时长：3 小时 20 分 · 可用 2 小时/天'), findsOneWidget);
    expect(find.textContaining('计划风险'), findsOneWidget);
    // 系统只建议，不自动改计划（FR-5.5）。
    expect(find.textContaining('不会自动修改你的计划'), findsOneWidget);
  });

  testWidgets('每周可用日影响剩余可用天数（仅工作日时周末不计）', (tester) async {
    // 截止 08-11（下周二）。仅工作日可用：08-05~07、10、11 共 5 天。
    await settings.updateAvailableWeekdays({1, 2, 3, 4, 5});
    final goal = await goals.create(title: '论文', deadlineDate: '2026-08-11');
    await tasks.create(
      goalId: goal.id,
      title: '任务A',
      plannedDate: '2026-08-05',
      estimatedMinutes: 500,
    );

    await pumpApp(tester);
    await openGoalDetail(tester, '论文');

    expect(find.text('剩余可用天数（学习日）：5 天'), findsOneWidget);
    // 500 / 5 = 100 分钟/天，未超可用时长，无风险。
    expect(find.text('建议日均时长：1 小时 40 分 · 可用 2 小时/天'), findsOneWidget);
    expect(find.textContaining('计划风险'), findsNothing);
  });

  testWidgets('无任务时负载区显示 -- 分（区分「还没计划」与「已全部完成」）', (tester) async {
    // 目标下没有任何任务。
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openGoalDetail(tester, '考研');

    // 无任务状态：时长与建议日均显示 -- 分，而非误导性的 0 分。
    expect(find.text('剩余任务时长：-- 分'), findsOneWidget);
    expect(find.text('建议日均时长：-- 分 · 可用 2 小时/天'), findsOneWidget);
    // 学习日口径说明仍展示（有剩余学习日时）。
    expect(find.textContaining('按计划偏好排除休息日后的学习日'), findsOneWidget);
  });

  testWidgets('设置计划偏好：修改每日可用时长后今天页负载提示随之变化', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 150,
    );

    await pumpApp(tester);
    // 默认 120 分钟：今日负载 150 超 30。
    expect(find.text('超出 30 分，请调整任务或可用时间'), findsOneWidget);

    // 偏好页用步进器改为 3 小时（小时加 1）。
    await openPlanPreference(tester);
    await tester.tap(find.byTooltip('小时加'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 3 小时'), findsOneWidget);

    await tester.tap(find.text('保存').first);
    await tester.pumpAndSettle();
    expect(find.text('计划偏好已保存'), findsOneWidget);

    // 偏好页是独立路由（无底部导航），返回进度页后再切今天页。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tapNavDestination(tester, '今天');
    expect(find.text('今日任务总计 2 小时 30 分'), findsOneWidget);
    expect(find.text('可用 3 小时'), findsOneWidget);
    expect(find.textContaining('超出'), findsNothing);
  });

  testWidgets('设置计划偏好：修改每周可用日后快捷延期跳到下个可用日', (tester) async {
    // 仅周日可用：今天（周三）的任务延期应跳到周日（08-09）。
    await settings.updateAvailableWeekdays({7});
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final created = await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('延期至下一可用日'));
    await tester.pumpAndSettle();

    final fetched = await tasks.byId(created.id);
    expect(fetched?.plannedDate, '2026-08-09');
    expect(fetched?.originalPlannedDate, '2026-08-05');
  });

  testWidgets('偏好页步进器边界：小时不超过 24、分钟不低过 0、可回退', (tester) async {
    await pumpApp(tester);
    await openPlanPreference(tester);

    // 默认 2 小时 / 0 分。
    expect(find.text('当前共 2 小时'), findsOneWidget);

    // 小时步进：向下到 0 后不可再减。
    await tester.tap(find.byTooltip('小时减'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('小时减'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 0 分'), findsOneWidget);
    await tester.tap(find.byTooltip('小时减'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 0 分'), findsOneWidget);

    // 每日可用时长为 0 时保存被阻止。
    await tester.tap(find.text('保存').first);
    await tester.pumpAndSettle();
    expect(find.text('每日可用时长至少 1 分钟'), findsOneWidget);
    expect(find.text('计划偏好已保存'), findsNothing);

    // 分钟步进：向上到 5，向下回 0。
    await tester.tap(find.byTooltip('分钟加'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 5 分'), findsOneWidget);
    await tester.tap(find.byTooltip('分钟减'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 0 分'), findsOneWidget);

    // 小时向上到 24 后不可再增。
    for (var i = 0; i < 25; i++) {
      await tester.tap(find.byTooltip('小时加'));
    }
    await tester.pumpAndSettle();
    expect(find.text('当前共 24 小时'), findsOneWidget);
    await tester.tap(find.byTooltip('小时加'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 24 小时'), findsOneWidget);
  });

  testWidgets('点击小时中间数字区域可直接输入编辑并生效', (tester) async {
    // 今日有一个 60 分钟任务，负载概览卡会展示「今日 1 小时 · 可用 …」。
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);
    await openPlanPreference(tester);

    // 点击小时步进器的数字区域进入编辑态。
    final hourInput = find.descendant(
      of: find.byKey(const Key('hourStepField')),
      matching: find.byType(TextField),
    );
    await tester.tap(hourInput);
    await tester.pumpAndSettle();
    await tester.enterText(hourInput, '5');
    await tester.pumpAndSettle();
    // 回车确认并失焦，触发提交。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('当前共 5 小时'), findsOneWidget);

    // 保存后返回进度页，再切今天页：可用时长变为 5 小时。
    await tester.tap(find.text('保存').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tapNavDestination(tester, '今天');
    expect(find.text('今日任务总计 1 小时'), findsOneWidget);
    expect(find.text('可用 5 小时'), findsOneWidget);
  });

  testWidgets('编辑输入超出范围时夹取到边界（小时 30 → 24）', (tester) async {
    await pumpApp(tester);
    await openPlanPreference(tester);

    final hourInput = find.descendant(
      of: find.byKey(const Key('hourStepField')),
      matching: find.byType(TextField),
    );
    await tester.tap(hourInput);
    await tester.pumpAndSettle();
    await tester.enterText(hourInput, '30');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 30 小时超出上限，夹取到 24 小时。
    expect(find.text('当前共 24 小时'), findsOneWidget);
  });

  testWidgets('详情页不展示历史任务区（归档任务移入设置页数据管理）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '旧任务',
      plannedDate: '2026-08-06',
      estimatedMinutes: 60,
    );
    // 归档全部任务（模拟 JSON 导入替换）。
    await tasks.archiveAllActive(goal.id);
    expect((await tasks.archivedByGoal(goal.id)), isNotEmpty);

    await pumpApp(tester);
    await openGoalDetail(tester, '考研');

    // 详情页不再渲染「历史任务」区（已移入设置页「备份与恢复」）。
    expect(find.textContaining('历史任务'), findsNothing);
    // 归档任务不进入当前计划列表。
    expect(find.text('旧任务'), findsNothing);
  });

  testWidgets('分钟直接输入 60 自动进位到小时（避免「X 小时 60 分」矛盾）', (tester) async {
    await pumpApp(tester);
    await openPlanPreference(tester);

    // 默认 2 小时 0 分；分钟字段输入 60 → 自动进位为 3 小时 0 分。
    final minuteInput = find.descendant(
      of: find.byKey(const Key('minuteStepField')),
      matching: find.byType(TextField),
    );
    await tester.tap(minuteInput);
    await tester.pumpAndSettle();
    await tester.enterText(minuteInput, '60');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('当前共 3 小时'), findsOneWidget);
    expect(find.textContaining('60 分'), findsNothing);
  });

  testWidgets('每周可用日提供「全部选中/全部取消」快捷操作', (tester) async {
    await pumpApp(tester);
    await openPlanPreference(tester);

    bool chipSelected(String label) => tester
        .widget<FilterChip>(find.widgetWithText(FilterChip, label))
        .selected;
    const days = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    // 默认 7 天全选。
    for (final day in days) {
      expect(chipSelected(day), isTrue);
    }

    // 全部取消：一键清空（如只休周五/周六时先全部取消）。
    await tester.tap(find.text('全部取消'));
    await tester.pumpAndSettle();
    for (final day in days) {
      expect(chipSelected(day), isFalse);
    }

    // 全部选中：一键恢复。
    await tester.tap(find.text('全部选中'));
    await tester.pumpAndSettle();
    for (final day in days) {
      expect(chipSelected(day), isTrue);
    }
  });
}
