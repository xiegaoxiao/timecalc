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

/// 里程碑用户流程 Widget 测试（checklists §2.2 / §5.3）。
///
/// 使用内存数据库 + 固定时钟。测试数据：目标「考研」截止 2026-12-20，
/// 从计划页进入目标详情页操作里程碑区。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late MilestoneRepository milestones;
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

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    milestones = MilestoneRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
    // 预置一个目标（截止 2026-12-20），供详情页操作。
    await goals.create(title: '考研', deadlineDate: '2026-12-20');
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> openGoalDetail(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考研'));
    await tester.pumpAndSettle();
  }

  testWidgets('目标详情页显示里程碑区与空态（FR-2.1）', (tester) async {
    await openGoalDetail(tester);

    expect(find.text('里程碑'), findsOneWidget);
    expect(find.text('添加里程碑'), findsOneWidget);
    expect(
      find.text('还没有里程碑，点击「添加里程碑」设定阶段性节点'),
      findsOneWidget,
    );
  });

  testWidgets('添加里程碑 → 列表出现，编辑后即时更新（FR-2.1）', (tester) async {
    await openGoalDetail(tester);

    await tester.tap(find.text('添加里程碑'));
    await tester.pumpAndSettle();

    // 名称必填校验。
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();
    expect(find.text('请输入里程碑名称'), findsOneWidget);

    // 填写名称。
    await tester.enterText(find.byType(TextFormField).first, '完成一轮复习');
    await tester.pumpAndSettle();

    // 选择日期（当月 2026-08，选 20 日）。
    await tester.tap(find.text('请选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();

    expect(find.text('完成一轮复习'), findsOneWidget);
    expect(find.textContaining('2026-08-20'), findsOneWidget);

    // 编辑：改标题与日期。
    await tester.tap(find.byTooltip('编辑里程碑「完成一轮复习」'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '一轮复习完成');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(find.text('一轮复习完成'), findsOneWidget);
  });

  testWidgets('里程碑日期晚于目标截止日时阻断保存并提示（FR-2.2）', (tester) async {
    // 预置一个截止日较早的目标（2026-08-10），便于选择晚于它的日期。
    await goals.create(title: '期末复习', deadlineDate: '2026-08-10');

    await pumpApp(tester);
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('期末复习'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加里程碑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '晚于截止日');
    await tester.pumpAndSettle();

    // 当月（2026-08）选 20 日，晚于截止日 2026-08-10。
    await tester.tap(find.text('请选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 保存被阻断：提示出现，且不写入。
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('里程碑日期晚于目标截止日'), findsOneWidget);
    expect(await milestones.byGoal(2), isEmpty);
  });

  testWidgets('标记里程碑完成：划线 + 状态更新，可取消（FR-2.1）', (tester) async {
    // 预置一个里程碑。
    await milestones.create(
      goalId: 1,
      title: '完成一轮复习',
      date: '2026-09-30',
    );

    await openGoalDetail(tester);

    // 初始未完成。
    final checkbox = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);

    // 点击勾选 → 完成。
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
    expect(find.text('2026-09-30 · 已完成'), findsOneWidget);

    // 再点取消完成。
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
  });

  testWidgets('删除里程碑有二次确认（FR-2.1）', (tester) async {
    await milestones.create(
      goalId: 1,
      title: '临时节点',
      date: '2026-09-30',
    );

    await openGoalDetail(tester);

    // 打开删除菜单并确认。
    await tester.tap(find.byTooltip('里程碑操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除里程碑「临时节点」？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('临时节点'), findsNothing);
    expect(await milestones.byGoal(1), isEmpty);
  });
}
