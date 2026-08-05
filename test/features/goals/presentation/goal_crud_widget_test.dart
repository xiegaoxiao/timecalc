import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';

/// 目标 CRUD 用户流程 Widget 测试（checklists §5.3）。
///
/// 使用内存数据库 + 固定时钟，保证「创建目标 → 首页卡片与倒计时」可复现。
void main() {
  late AppDatabase db;
  late GoalRepository repository;
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
    repository = GoalRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('创建目标 → 计划页出现目标卡片', (tester) async {
    await pumpApp(tester);

    // 切到「计划」页并打开创建目标对话框。
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('创建目标'));
    await tester.pumpAndSettle();

    // 表单校验：名称为必填。
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    expect(find.text('请输入目标名称'), findsOneWidget);

    // 填写名称。
    await tester.enterText(find.byType(TextFormField).first, '考研数学');
    await tester.pumpAndSettle();

    // 填写截止日期：日期选择器默认显示当月（2026-08），选择 20 日。
    await tester.tap(find.text('请选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    // 目标卡片出现在计划页，截止日期为所选 2026-08-20。
    expect(find.text('考研数学'), findsOneWidget);
    expect(find.textContaining('截止 2026-08-20'), findsOneWidget);
  });

  testWidgets('创建目标后，今天页展示目标卡片与倒计时（FR-1 验收）', (tester) async {
    await repository.create(title: '考研数学', deadlineDate: '2026-12-20');
    await pumpApp(tester);

    // 首页（今天）应展示目标与倒计时：2026-08-05 距 2026-12-20 为 137 天。
    expect(find.text('考研数学'), findsOneWidget);
    expect(find.text('截止 2026-12-20'), findsOneWidget);
    expect(find.text('剩余 137 天'), findsOneWidget);
  });

  testWidgets('截止日为今天时显示「今天截止」（FR-1.2）', (tester) async {
    await repository.create(title: '论文终稿', deadlineDate: '2026-08-05');
    await pumpApp(tester);

    expect(find.text('论文终稿'), findsOneWidget);
    expect(find.text('今天截止'), findsOneWidget);
  });

  testWidgets('截止日已过显示「已逾期 N 天」（FR-1.3）', (tester) async {
    await repository.create(title: '已过期目标', deadlineDate: '2026-08-03');
    await pumpApp(tester);

    expect(find.text('已逾期 2 天'), findsOneWidget);
  });

  testWidgets('删除目标前二次确认并明确提示连带删除任务（FR-1 验收）', (tester) async {
    final goal = await repository.create(title: '考研数学', deadlineDate: '2026-12-20');
    await pumpApp(tester);

    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();

    // 打开目标操作菜单，选择删除。
    await tester.tap(find.byTooltip('目标操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 二次确认对话框出现，文案明确提示将删除任务。
    expect(find.text('删除目标？'), findsOneWidget);
    expect(
      find.textContaining('将删除「考研数学」及其全部任务'),
      findsOneWidget,
    );

    // 取消：目标仍在。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await repository.byId(goal.id), isNotNull);

    // 再次删除并确认：目标消失。
    await tester.tap(find.byTooltip('目标操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(await repository.byId(goal.id), isNull);
    expect(find.text('还没有目标'), findsOneWidget);
  });

  testWidgets('无目标时计划页展示空态与创建入口（PRD §8）', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();

    expect(find.text('还没有目标'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '创建目标'), findsOneWidget);
  });
}
