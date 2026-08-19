import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/milestone_repository.dart';

import '../../../shared/nav_helper.dart';

/// 里程碑区预览限制 + 目标全部里程碑页 Widget 测试（2026-08-18）。
///
/// 场景：详情页里程碑超过 8 条时只预览前 8 条 + 「查看全部」入口，
/// 进入全部里程碑页全量平铺展示，操作（勾选/删除/添加）可用。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late MilestoneRepository milestones;
  late int goalId;

  Future<void> pumpApp(WidgetTester tester) async {
    // 详情页内容长，放大视口避免「查看全部」行落在视口外
    // （ListView 惰性构建，视口外 find 不到）。
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => DateTime(2026, 8, 5, 12)),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openGoalDetail(WidgetTester tester) async {
    await pumpApp(tester);
    await tapNavDestination(tester, '目标');
    await tester.tap(find.text('考研'));
    await tester.pumpAndSettle();
  }

  Future<void> createMilestones(int count) async {
    for (var i = 1; i <= count; i++) {
      final day = i < 10 ? '0$i' : '$i';
      await milestones.create(
        goalId: goalId,
        title: '里程碑 $i',
        date: '2026-09-$day',
      );
    }
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    milestones = MilestoneRepository(db);
    goalId = (await goals.create(title: '考研', deadlineDate: '2026-12-20')).id;
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('详情页里程碑超过 8 条：只预览前 8 条 + 查看全部入口', (tester) async {
    await createMilestones(10);

    await openGoalDetail(tester);

    // 预览：前 8 条可见，第 9/10 条不出现。
    expect(find.text('里程碑 1'), findsOneWidget);
    expect(find.text('里程碑 8'), findsOneWidget);
    expect(find.text('里程碑 9'), findsNothing);
    expect(find.text('里程碑 10'), findsNothing);
    // 末尾「查看全部」行展示总数。
    expect(find.text('查看全部 10 个里程碑'), findsOneWidget);

    // 点「查看全部」进入目标全部里程碑页：全量出现。
    await tester.tap(find.text('查看全部 10 个里程碑'));
    await tester.pumpAndSettle();

    expect(find.text('全部里程碑'), findsOneWidget); // AppBar 标题
    expect(find.text('里程碑 9'), findsOneWidget);
    expect(find.text('里程碑 10'), findsOneWidget);
  });

  testWidgets('详情页里程碑 ≤ 8 条：不显示查看全部入口', (tester) async {
    await createMilestones(5);

    await openGoalDetail(tester);

    expect(find.text('里程碑 5'), findsOneWidget);
    expect(find.textContaining('查看全部'), findsNothing);
  });

  testWidgets('全部里程碑页：总览统计、勾选完成、删除与添加可用', (tester) async {
    await createMilestones(9);

    await openGoalDetail(tester);
    await tester.tap(find.text('查看全部 9 个里程碑'));
    await tester.pumpAndSettle();

    // 总览统计。
    expect(find.textContaining('共 9 个里程碑 · 0 个已完成'), findsOneWidget);

    // 勾选完成 → 状态更新并刷新总览。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('共 9 个里程碑 · 1 个已完成'), findsOneWidget);
    expect(find.text('里程碑 1'), findsOneWidget); // 划线行仍在

    // 删除：菜单 → 确认 → 条目消失、总览随之更新。
    await tester.tap(find.byTooltip('里程碑操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除里程碑「里程碑 1」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('里程碑 1'), findsNothing);
    // 删除的正是刚才勾选完成的「里程碑 1」，完成数回落为 0。
    expect(find.textContaining('共 8 个里程碑 · 0 个已完成'), findsOneWidget);

    // AppBar 添加按钮可用：弹窗打开后取消。
    await tester.tap(find.text('添加里程碑'));
    await tester.pumpAndSettle();
    expect(find.text('里程碑日期 *'), findsOneWidget); // 弹窗内容特有
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
