import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/desktop/desktop_providers.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

import '../../../shared/nav_helper.dart';

/// 任务日期选择器范围测试（修复：计划日期不得晚于目标截止日）。
///
/// 固定时钟 2026-08-05（今天），验证：
/// - 添加任务日期选择器区间 = [今天, 目标截止日]；
/// - 目标截止日 = 今天：区间退化为 [今天, 今天]（不崩溃）；
/// - 逾期目标（截止日早于今天）：区间仍可用（[今天, 今天]）；
/// - 保存越界日期的守卫提示（批量添加递推铺到截止日后被拦截）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    // 放大视口：目标详情页/对话框较长。
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
          // widget 测试中桌面能力禁用（不触碰 windowManager/trayManager）。
          desktopControllerProvider.overrideWithValue(null),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openGoalDetail(WidgetTester tester, String goalTitle) async {
    await tapNavDestination(tester, '目标');
    await tester.tap(find.text(goalTitle));
    await tester.pumpAndSettle();
  }

  /// 打开「添加任务」对话框并展开日期选择器，返回其中的 CalendarDatePicker。
  Future<CalendarDatePicker> openDatePicker(WidgetTester tester) async {
    await tester.tap(find.text('添加任务').first);
    await tester.pumpAndSettle();
    // 计划日期字段：InputDecorator 内是 InkWell 包裹的日期文本（初始=今天）。
    await tester.tap(find.text('2026-08-05'));
    await tester.pumpAndSettle();
    return tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
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

  testWidgets('日期选择器区间 = [今天, 目标截止日]（正常目标）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await pumpApp(tester);
    await openGoalDetail(tester, '考研');

    final picker = await openDatePicker(tester);

    expect(picker.firstDate, DateTime(2026, 8, 5)); // 今天（注入时钟）
    expect(picker.lastDate, DateTime(2026, 12, 31)); // 目标截止日
  });

  testWidgets('目标截止日 = 今天：区间退化为 [今天, 今天]（不崩溃）', (tester) async {
    await goals.create(title: '当天截止', deadlineDate: '2026-08-05');
    await pumpApp(tester);
    await openGoalDetail(tester, '当天截止');

    final picker = await openDatePicker(tester);

    expect(picker.firstDate, DateTime(2026, 8, 5));
    expect(picker.lastDate, DateTime(2026, 8, 5));
  });

  testWidgets('逾期目标（截止日早于今天）：区间仍可用，不抛断言', (tester) async {
    await goals.create(title: '已逾期', deadlineDate: '2026-08-03');
    await pumpApp(tester);
    await openGoalDetail(tester, '已逾期');

    final picker = await openDatePicker(tester);

    // 截止日已过 → 退化为只能选今天。
    expect(picker.firstDate, DateTime(2026, 8, 5));
    expect(picker.lastDate, DateTime(2026, 8, 5));
  });

  testWidgets('批量添加：递推任务铺到截止日后被拦截并提示（不静默消失）', (tester) async {
    // 截止日为 08-07；起始今天（08-05）起每 3 天一个，第 2 个任务落在 08-08（超截止）。
    final goal = await goals.create(title: '套卷', deadlineDate: '2026-08-07');
    await pumpApp(tester);
    await openGoalDetail(tester, '套卷');

    await tester.tap(find.text('批量添加'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      '卷1\n卷2',
    );
    // 打开起始日期选择器，断言区间后保持默认（今天）。
    await tester.tap(find.text('2026-08-05'));
    await tester.pumpAndSettle();
    final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
    expect(picker.firstDate, DateTime(2026, 8, 5)); // 下界今天
    expect(picker.lastDate, DateTime(2026, 8, 7)); // 上界截止日
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 启用「每 N 天一个」，间隔 3。
    await tester.tap(find.text('每 N 天一个'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '间隔天数'),
      '3',
    );
    await tester.pumpAndSettle();
    // 弹窗内容限高后可滚动，底部「创建」可能落在视口外：先滚动到可见。
    await tester.ensureVisible(find.text('创建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 守卫拦截：第二个任务（08-08）晚于截止日，不写库并明确提示。
    expect(find.textContaining('不能晚于目标截止日'), findsOneWidget);
    expect(await tasks.byGoal(goal.id), isEmpty);
  });
}
