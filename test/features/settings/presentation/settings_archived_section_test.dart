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

/// 设置页「已归档任务」子页 Widget 测试。
///
/// 替换导入时归档保留的已完成旧任务，在设置页「已归档任务」菜单项进入的
/// 独立子页中平铺回看/恢复。
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

  /// 进入设置页 → 点击「已归档任务」菜单项 → 归档子页。
  Future<void> openArchivedPage(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已归档任务'));
    await tester.pumpAndSettle();
  }

  /// 建一个目标并归档 [count] 个已完成任务，返回任务 id。
  Future<List<int>> seedArchived(int count) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final ids = <int>[];
    for (var i = 0; i < count; i++) {
      final t = await tasks.create(
        goalId: goal.id,
        title: '旧任务$i',
        plannedDate: '2026-08-01',
        estimatedMinutes: 60,
      );
      await tasks.setDone(t.id, true);
      ids.add(t.id);
    }
    await tasks.archiveAllActive(goal.id);
    return ids;
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

  testWidgets('已归档任务子页平铺展示归档任务（标题 + 完成日期）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final done = await tasks.create(
      goalId: goal.id,
      title: '已完成旧任务',
      plannedDate: '2026-08-01',
      estimatedMinutes: 60,
    );
    await tasks.setDone(done.id, true);
    await tasks.archiveAllActive(goal.id);

    await pumpApp(tester);
    await openArchivedPage(tester);

    expect(find.text('已完成旧任务'), findsOneWidget);
    // completedAt 为真实写入时间，只断言「完成」前缀 + 计划日期/时长。
    expect(find.textContaining('完成 '), findsOneWidget);
    expect(find.textContaining('2026-08-01 · 1 小时'), findsOneWidget);
  });

  testWidgets('点击恢复：任务回到当前计划，归档列表清空', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final done = await tasks.create(
      goalId: goal.id,
      title: '已完成旧任务',
      plannedDate: '2026-08-01',
      estimatedMinutes: 60,
    );
    await tasks.setDone(done.id, true);
    await tasks.archiveAllActive(goal.id);

    await pumpApp(tester);
    await openArchivedPage(tester);

    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    // 恢复后子页回到空态。
    expect(find.text('暂无归档任务'), findsOneWidget);
    final active = await tasks.byGoal(goal.id);
    expect(active.map((t) => t.title), contains('已完成旧任务'));
    expect((await tasks.archivedByGoal(goal.id)), isEmpty);
  });

  testWidgets('无归档任务时子页展示空态提示', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openArchivedPage(tester);

    expect(find.text('暂无归档任务'), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
  });

  testWidgets('选择模式全选后一键删除：确认后归档清空回到空态', (tester) async {
    await seedArchived(2);

    await pumpApp(tester);
    await openArchivedPage(tester);

    // 进入选择模式：每行出现勾选框。
    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('已选 0 项'), findsOneWidget);

    // 全选：计数更新。
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    // 删除 → 确认对话框 → 确认。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除所选 2 项归档任务？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    // 归档已清空：空态展示、数据库确认。
    expect(find.text('暂无归档任务'), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
    expect(await tasks.allArchived(), isEmpty);
    // 删除后退出选择模式。
    expect(find.text('已归档任务'), findsOneWidget);
  });

  testWidgets('反选：全选→反选=全不选（删除不生效），再反选=全选', (tester) async {
    await seedArchived(3);

    await pumpApp(tester);
    await openArchivedPage(tester);
    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();

    // 全选后反选 → 全不选。
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsOneWidget);

    // 无勾选时点删除不弹确认框，任务保留。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除所选'), findsNothing);
    expect(await tasks.allArchived(), hasLength(3));

    // 再反选 = 全选。
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
  });

  testWidgets('删除确认点取消：任务保留且仍处于选择模式', (tester) async {
    await seedArchived(2);

    await pumpApp(tester);
    await openArchivedPage(tester);
    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await tasks.allArchived(), hasLength(2));
    expect(find.text('旧任务0'), findsOneWidget);
    expect(find.text('旧任务1'), findsOneWidget);
    // 取消后仍处于选择模式（可继续调整勾选）。
    expect(find.text('已选 2 项'), findsOneWidget);
  });

  testWidgets('长按某条进入选择模式并只选中该条', (tester) async {
    await seedArchived(2);

    await pumpApp(tester);
    await openArchivedPage(tester);

    await tester.longPress(find.text('旧任务1'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));
    final checked = tester
        .widgetList<Checkbox>(find.byType(Checkbox))
        .where((c) => c.value == true)
        .length;
    expect(checked, 1);
  });

  testWidgets('列表为空时「批量删除」入口不进入选择模式', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);
    await openArchivedPage(tester);

    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    // 无可选内容：标题保持普通态，无选择控件。
    expect(find.text('已归档任务'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });
}
