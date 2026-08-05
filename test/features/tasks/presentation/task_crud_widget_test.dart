import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 任务与科目 CRUD 用户流程 Widget 测试（checklists §5.3）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
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
    subjects = SubjectRepository(db);
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

    // 填写标题。
    await tester.enterText(find.byType(TextFormField).first, '完成第一章');

    // 用步进器设置预估时长 120 分钟（2 小时）：点「小时加」两次。
    await tester.tap(find.byTooltip('小时加'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('小时加'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 2 小时'), findsOneWidget);

    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    // 任务出现在目标详情（任务条目标注预估时长）。
    expect(find.text('完成第一章'), findsOneWidget);
    expect(find.text('2026-08-05 · 2 小时'), findsOneWidget);
  });

  testWidgets('预估时长步进与无时长切换（FR-3 验收）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '任务');

    // 默认未设置时长（0 分起步，可直接步进）。
    expect(find.text('当前共 0 分'), findsOneWidget);

    // 分钟步进：一次 +5 分钟。
    await tester.tap(find.byTooltip('分钟加'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 5 分'), findsOneWidget);

    // 切到「无时长」再保存：任务预估时长为 null。
    await tester.tap(find.text('无时长'));
    await tester.pumpAndSettle();
    expect(find.text('未设置时长'), findsOneWidget);

    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    final created = (await tasks.byGoal(goalId)).single;
    expect(created.title, '任务');
    expect(created.estimatedMinutes, isNull);
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

  testWidgets('科目卡片上的编辑按钮可重命名（回归：科目重命名）', (tester) async {
    final subject = await subjects.create(goalId: goalId, name: '数学', color: '#3F6C51');
    await pumpApp(tester);
    await openGoalDetail(tester);

    // 科目以卡片展示，含重命名编辑按钮。
    expect(find.widgetWithText(Card, '数学'), findsOneWidget);

    // 点击编辑按钮打开重命名对话框。
    await tester.tap(find.byTooltip('重命名科目「数学」'));
    await tester.pumpAndSettle();
    expect(find.textContaining('重命名科目「数学」'), findsOneWidget);

    // 修改为「高等数学」。
    await tester.enterText(find.byType(TextField).last, '高等数学');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(Card, '高等数学'), findsOneWidget);
    expect(find.text('数学'), findsNothing);

    // 数据库同步更新。
    final renamed = await subjects.byId(subject.id);
    expect(renamed?.name, '高等数学');
  });

  testWidgets('点击科目进入科目任务页，仅显示该科目任务，创建任务默认归属（回归：科目任务页）', (tester) async {
    final subject = await subjects.create(goalId: goalId, name: '数学', color: '#3F6C51');
    await tasks.create(goalId: goalId, subjectId: subject.id, title: '第一章习题', plannedDate: '2026-08-05');
    await tasks.create(goalId: goalId, title: '未分类任务', plannedDate: '2026-08-05');

    await pumpApp(tester);
    await openGoalDetail(tester);

    // 点击科目卡片进入科目任务页。
    await tester.tap(find.widgetWithText(Card, '数学'));
    await tester.pumpAndSettle();

    // AppBar 显示科目名，只展示该科目的任务。
    expect(find.text('数学'), findsWidgets);
    expect(find.text('第一章习题'), findsOneWidget);
    expect(find.text('未分类任务'), findsNothing);

    // 科目页创建任务默认归属该科目。
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '第二章习题');
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    expect(find.text('第二章习题'), findsOneWidget);
    final created = (await tasks.byGoal(goalId))
        .firstWhere((t) => t.title == '第二章习题');
    expect(created.subjectId, subject.id);
  });

  testWidgets('批量添加：多行同一天创建（回归：批量录入）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    await tester.tap(find.text('批量添加'));
    await tester.pumpAndSettle();

    // 输入三行标题。
    await tester.enterText(
      find.byType(TextFormField).first,
      '严选题 第1章\n严选题 第2章\n严选题 第3章',
    );
    await tester.pumpAndSettle();

    // 预览显示将创建 3 个任务。
    expect(find.textContaining('将创建 3 个任务'), findsOneWidget);

    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final all = await tasks.byGoal(goalId);
    expect(all, hasLength(3));
    // 日期默认取注入时钟的今天（2026-08-05）。
    expect(all.every((t) => t.plannedDate == '2026-08-05'), isTrue);
  });

  testWidgets('批量添加：每 N 天一个日期递推（套卷场景）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    await tester.tap(find.text('批量添加'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).first,
      '真题 2013\n真题 2014\n真题 2015',
    );
    await tester.pumpAndSettle();

    // 选择「每 N 天一个」。
    await tester.tap(find.text('每 N 天一个（按顺序排列）'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final all = await tasks.byGoal(goalId);
    expect(all, hasLength(3));
    // 起始日期为注入时钟的今天（2026-08-05），每天递增。
    expect(all.map((t) => t.plannedDate).toList(), [
      '2026-08-05',
      '2026-08-06',
      '2026-08-07',
    ]);
  });

  testWidgets('批量添加：科目页入口默认归属该科目', (tester) async {
    final subject = await subjects.create(goalId: goalId, name: '数学', color: '#3F6C51');
    await pumpApp(tester);
    await openGoalDetail(tester);

    await tester.tap(find.widgetWithText(Card, '数学'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('批量添加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '660 第1天\n660 第2天');
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final all = (await tasks.byGoal(goalId))
        .where((t) => t.title.startsWith('660'))
        .toList();
    expect(all, hasLength(2));
    expect(all.every((t) => t.subjectId == subject.id), isTrue);
  });
}
