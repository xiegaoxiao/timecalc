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

/// 任务与科目 CRUD 用户流程 Widget 测试（checklists §5.3）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late int goalId;

  Future<void> openGoalDetail(WidgetTester tester) async {
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考研数学'));
    await tester.pumpAndSettle();
  }

  Future<void> pumpApp(WidgetTester tester) async {
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

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    goalId = (await goals.create(title: '考研数学', deadlineDate: '2026-12-20')).id;
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('在目标详情添加任务并显示（FR-3.1/FR-3.2）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    // 打开创建任务对话框。
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();

    // 必填校验：标题为空时提示。
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    expect(find.text('请输入任务标题'), findsOneWidget);

    // 填写标题与预估时长。
    await tester.enterText(find.byType(TextFormField).first, '完成第一章');
    await tester.enterText(find.byType(TextFormField).at(1), '120');
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    // 任务出现在目标详情。
    expect(find.text('完成第一章'), findsOneWidget);
    expect(find.textContaining('120 分钟'), findsOneWidget);
  });

  testWidgets('非法预估时长被阻止并提示（FR-3 验收）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '任务');
    // 非法值：0。
    await tester.enterText(find.byType(TextFormField).at(1), '0');
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    expect(find.text('请输入 1～1440 之间的整数'), findsOneWidget);

    // 非法值：1441。
    await tester.enterText(find.byType(TextFormField).at(1), '1441');
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    expect(find.text('请输入 1～1440 之间的整数'), findsOneWidget);

    // 对话框未关闭，数据库未创建任务。
    expect(find.text('创建任务'), findsOneWidget);
    expect(await tasks.byGoal(goalId), isEmpty);
  });

  testWidgets('完成任务后列表状态同步更新（FR-3 验收）', (tester) async {
    await tasks.create(goalId: goalId, title: '完成第一章', plannedDate: '2026-08-05', estimatedMinutes: 120);
    await pumpApp(tester);
    await openGoalDetail(tester);

    // 初始未完成。
    final checkbox = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);

    // 点击完成。
    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    // 状态同步为完成（删除线样式存在）。
    final updated = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(updated.value, isTrue);

    // 数据库中状态同步。
    final list = await tasks.byGoal(goalId);
    expect(list.single.status, 'done');
  });

  testWidgets('删除任务（FR-3.2）', (tester) async {
    await tasks.create(goalId: goalId, title: '要删除的任务', plannedDate: '2026-08-05');
    await pumpApp(tester);
    await openGoalDetail(tester);

    expect(find.text('要删除的任务'), findsOneWidget);
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('要删除的任务'), findsNothing);
    expect(await tasks.byGoal(goalId), isEmpty);
  });

  testWidgets('科目增删与任务归属科目显示（FR-1.5）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    // 添加科目「数学」。
    await tester.tap(find.text('添加科目'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '数学');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('数学'), findsOneWidget);

    // 添加任务时选择科目。
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '概率论练习');
    await tester.tap(find.text('（无）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    // 任务显示科目归属。
    expect(find.textContaining('数学'), findsWidgets);
  });
}
