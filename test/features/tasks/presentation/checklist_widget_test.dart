import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/checklist_item_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 任务检查项 Widget 测试（FR-4.1，schema v8）。
///
/// 覆盖：菜单入口打开检查项对话框、添加/勾选/删除/上下移、
/// 完成任务时未完成检查项二次确认（确认/取消）、无检查项直接完成（回归）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late ChecklistItemRepository checklist;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
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

  /// 今天页：任务行弹出菜单 → 检查项…。
  Future<void> openChecklistDialog(WidgetTester tester, {String taskTitle = '背单词'}) async {
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查项…'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    checklist = ChecklistItemRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTask() async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final task = await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
    );
    return task.id;
  }

  testWidgets('任务菜单「检查项…」打开对话框，可添加/勾选/删除/上下移', (tester) async {
    final taskId = await seedTask();
    await pumpApp(tester);

    // 打开检查项对话框。
    await openChecklistDialog(tester);
    expect(find.textContaining('检查项 · 背单词'), findsOneWidget);
    expect(find.text('还没有检查项，输入内容点「添加」'), findsOneWidget);

    // 对话框内查找器：背景路由仍挂载，Checkbox/TextField 等需限定在
    // AlertDialog 内，避免误命中今天页任务行组件。
    Finder dialogCheckboxes() => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Checkbox),
        );
    Finder dialogInput() => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );

    // 添加两个检查项。
    await tester.enterText(dialogInput().first, '背 50 个单词');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogInput().first, '默写一遍');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    final items = await checklist.byTask(taskId);
    expect(items.map((c) => c.title), ['背 50 个单词', '默写一遍']);

    // 勾选第一个 → 划线 + done。
    await tester.tap(dialogCheckboxes().first);
    await tester.pumpAndSettle();
    final refreshed = await checklist.byTask(taskId);
    expect(refreshed.first.done, isTrue);
    expect(refreshed.first.id, items.first.id);

    // 下移第一个 → 排序交换。
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();
    final moved = await checklist.byTask(taskId);
    expect(moved.map((c) => c.title), ['默写一遍', '背 50 个单词']);

    // 删除「默写一遍」。
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect((await checklist.byTask(taskId)).single.title, '背 50 个单词');

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });

  testWidgets('任务存在未完成检查项时，勾选完成需二次确认；取消则保持未完成', (tester) async {
    final taskId = await seedTask();
    await checklist.create(taskId: taskId, title: '待办检查项');
    await pumpApp(tester);

    // 勾选任务完成 → 弹出二次确认。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('完成任务？'), findsOneWidget);
    expect(find.textContaining('还有 1 个检查项未完成'), findsOneWidget);

    // 取消 → 任务保持未完成。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await tasks.byId(taskId))?.status, 'todo');

    // 再次勾选 → 确认完成 → 任务完成，检查项保留。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定完成'));
    await tester.pumpAndSettle();
    expect((await tasks.byId(taskId))?.status, 'done');
    expect(await checklist.byTask(taskId), hasLength(1));
  });

  testWidgets('无未完成检查项时完成任务不弹确认（回归：既有流程不受影响）', (tester) async {
    final taskId = await seedTask();
    await pumpApp(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(find.text('完成任务？'), findsNothing);
    expect((await tasks.byId(taskId))?.status, 'done');
  });

  testWidgets('目标详情页任务行菜单也提供「检查项…」入口（P3.4 合并后的 TaskTile）', (tester) async {
    final goal = await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
    await tasks.create(
      goalId: goal.id,
      title: '真题卷',
      plannedDate: '2026-08-05',
    );
    await pumpApp(tester);

    // 计划 → 目标详情。
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考研数学'));
    await tester.pumpAndSettle();

    // 详情页任务行菜单含检查项入口。
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    expect(find.text('检查项…'), findsOneWidget);
    await tester.tap(find.text('检查项…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('检查项 · 真题卷'), findsOneWidget);
  });
}
