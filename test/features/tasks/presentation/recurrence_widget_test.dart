import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/recurrence_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_rule.dart';

/// 重复任务用户流程 Widget 测试（FR-4）。
///
/// 固定时钟 2026-08-05（周三）。验证：
/// - 通过「重复任务」按钮创建：艾宾浩斯序列生成实例，实例出现在今天/列表并带重复标记
/// - 实例菜单「停止重复」：不再生成，历史保留
/// - 实例菜单「编辑重复规则」：FR-4.4 二选一
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late RecurrenceRepository recurrence;
  late int goalId;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    // 目标详情页含里程碑区（FR-2）后页面变长，放大视口避免任务区按钮
    // 落在 600px 默认视口外（ListView 惰性构建，视口外 find 不到）。
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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

  Future<void> openGoalDetail(WidgetTester tester) async {
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考研'));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    recurrence = RecurrenceRepository(db);
    goalId = (await goals.create(title: '考研', deadlineDate: '2026-12-31')).id;
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('创建艾宾浩斯重复任务：生成实例并出现在今日页/列表（FR-4.3）', (tester) async {
    await pumpApp(tester);
    await openGoalDetail(tester);

    await tester.tap(find.text('重复任务'));
    await tester.pumpAndSettle();
    expect(find.text('重复任务'), findsWidgets);

    // 规则类型默认「每天」；切换到「间隔序列」（艾宾浩斯）。
    await tester.enterText(find.byType(TextFormField).first, '复习单词');
    await tester.tap(find.text('间隔序列'));
    await tester.pumpAndSettle();

    // 默认序列 1,2,4,7,15,30；起始日今天 08-05 → 预览含 08-05、08-06、08-07。
    expect(find.textContaining('08-05'), findsWidgets);
    expect(find.textContaining('08-06'), findsWidgets);

    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    // 创建后生成 6 个实例（未分类区展示），均带重复标记。
    expect(find.text('复习单词'), findsWidgets);
    expect(find.byTooltip('重复任务'), findsWidgets);

    final instances = await tasks.byGoal(goalId);
    expect(instances.map((t) => t.plannedDate).toList(), [
      '2026-08-05',
      '2026-08-06',
      '2026-08-07',
      '2026-08-09',
      '2026-08-12',
      '2026-08-20',
      '2026-09-04',
    ]);
    expect(instances.every((t) => t.recurrenceTemplateId != null), isTrue);

    // 今天页也出现今日实例（先返回计划页，再切到今天）。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('今天'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('复习单词'), findsOneWidget);
  });

  testWidgets('停止重复：确认后不再生成，已生成实例保留（FR-4.5）', (tester) async {
    // 直接建模板 + 实例。
    final template = await recurrence.create(
      goalId: goalId,
      title: '背单词',
      rule: RecurrenceRule.fromMap(ruleType: 'daily', json: const {}),
      startDate: '2026-08-05',
      today: fixedNow,
    );

    await pumpApp(tester);
    await openGoalDetail(tester);

    // 打开第一个实例的操作菜单 → 停止重复。
    await tester.tap(find.byTooltip('任务操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止重复'));
    await tester.pumpAndSettle();
    expect(find.text('停止重复？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '停止重复'));
    await tester.pumpAndSettle();

    // 模板已停用；实例仍在。
    expect((await recurrence.byId(template.id))?.active, isFalse);
    expect((await tasks.byGoal(goalId)).isNotEmpty, isTrue);
    // 时间前移后也不再生。
    expect(await recurrence.generateDue(today: DateTime(2026, 8, 20)), 0);
  });

  testWidgets('编辑重复规则：保存时弹出 FR-4.4 二选一', (tester) async {
    await recurrence.create(
      goalId: goalId,
      title: '背单词',
      rule: RecurrenceRule.fromMap(ruleType: 'daily', json: const {}),
      startDate: '2026-08-05',
      today: fixedNow,
    );

    await pumpApp(tester);
    await openGoalDetail(tester);

    // 打开第一个实例的操作菜单 → 编辑重复规则。
    await tester.tap(find.byTooltip('任务操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑重复规则'));
    await tester.pumpAndSettle();

    // 对话框预填模板信息（编辑模式标题）。
    expect(find.text('编辑重复任务'), findsOneWidget);

    // 切换到「每周指定星期」规则。
    await tester.tap(find.text('每周指定星期'));
    await tester.pumpAndSettle();

    // 保存 → FR-4.4 二选一。
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.text('如何应用修改？'), findsOneWidget);
    expect(find.text('仅修改模板'), findsOneWidget);
    expect(find.text('仅修改未来实例'), findsOneWidget);
    await tester.tap(find.text('仅修改模板'));
    await tester.pumpAndSettle();

    // 模板规则已改为 weekly，实例数量不变（仅改模板）。
    final templates = await recurrence.byGoal(goalId);
    expect(templates.single.ruleType, 'weekly');
  });

  testWidgets('编辑未注册 ruleType 的模板：回退到默认规则，不崩溃（回归）', (tester) async {
    // 直接写入一条未知规则类型（如历史数据/未来扩展的 handler 未注册）。
    final template = await recurrence.create(
      goalId: goalId,
      title: '旧版规则任务',
      rule: RecurrenceRule.fromMap(ruleType: 'daily', json: const {}),
      startDate: '2026-08-05',
      today: fixedNow,
    );
    await db.customStatement(
      "UPDATE recurrence_templates SET rule_type = 'unknown-type' WHERE id = ?",
      [template.id],
    );

    await pumpApp(tester);
    await openGoalDetail(tester);

    // 打开第一个实例的操作菜单 → 编辑重复规则：不应崩溃。
    await tester.tap(find.byTooltip('任务操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑重复规则'));
    await tester.pumpAndSettle();

    // 对话框正常打开，规则类型回退到默认（每天）。
    expect(find.text('编辑重复任务'), findsOneWidget);
    expect(find.text('每天'), findsWidgets);
  });

  group('重复任务列表手风琴折叠（FR-4 迭代）', () {
    /// 建一个 daily 模板（startDate 今天 → 30 天窗口实例）。
    Future<void> seedDailyTemplate() async {
      await recurrence.create(
        goalId: goalId,
        title: '背单词',
        rule: RecurrenceRule.fromMap(ruleType: 'daily', json: const {}),
        startDate: '2026-08-05',
        today: fixedNow,
      );
    }

    testWidgets('多实例折叠：详情页只显示一张父卡片（区间 + N 个任务），不显示平铺实例', (tester) async {
      await seedDailyTemplate();
      expect((await tasks.byGoal(goalId)).length, greaterThanOrEqualTo(2));

      await pumpApp(tester);
      await openGoalDetail(tester);

      // 父卡片：标题 + 区间 + 实例数；重复标记一次。
      expect(find.text('背单词'), findsOneWidget);
      expect(find.textContaining('~'), findsOneWidget);
      expect(find.textContaining('个任务'), findsOneWidget);
      expect(find.byTooltip('重复任务'), findsOneWidget);
      // 折叠状态不渲染任何子任务行（无复选框）。
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('单实例模板不折叠：以普通任务行展示（FR-4 折叠边界）', (tester) async {
      await seedDailyTemplate();
      // 先停用模板（防止 bootstrap 补生成新实例），再删除多余实例，
      // 仅保留最早的一个 → 单实例模板。
      final template = (await recurrence.byGoal(goalId)).single;
      await recurrence.stop(template.id);
      final instances = await tasks.byGoal(goalId);
      for (final instance in instances.skip(1)) {
        await tasks.delete(instance.id);
      }
      expect((await tasks.byGoal(goalId)), hasLength(1));

      await pumpApp(tester);
      await openGoalDetail(tester);

      // 普通任务行：有复选框与日期，无父卡片区间文案。
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.textContaining('个任务'), findsNothing);
    });

    testWidgets('点击父卡片展开子任务列表（内缩、含复选框与日期），再次点击收起', (tester) async {
      await seedDailyTemplate();

      await pumpApp(tester);
      await openGoalDetail(tester);

      // 默认折叠，无子任务。
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byTooltip('展开重复任务'), findsOneWidget);

      // 点击展开图标 → 子任务出现（含复选框与日期）。
      await tester.tap(find.byTooltip('展开重复任务'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起重复任务'), findsOneWidget);
      expect(find.byType(Checkbox), findsWidgets);
      expect(find.textContaining('2026-08-05'), findsWidgets);

      // 再次点击收起 → 子任务消失。
      await tester.tap(find.byTooltip('收起重复任务'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('点击父卡片主体同样可展开/收起（整卡可点）', (tester) async {
      await seedDailyTemplate();

      await pumpApp(tester);
      await openGoalDetail(tester);
      expect(find.byType(Checkbox), findsNothing);

      // 折叠态父卡片标题唯一（展开前只有一个「背单词」）。
      await tester.tap(find.text('背单词'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsWidgets);

      // 展开后子任务标题同名，用 .first 命中父卡片标题再收起。
      await tester.tap(find.text('背单词').first);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('展开后勾选子任务复选框：写入完成状态并刷新', (tester) async {
      await seedDailyTemplate();

      await pumpApp(tester);
      await openGoalDetail(tester);
      await tester.tap(find.byTooltip('展开重复任务'));
      await tester.pumpAndSettle();

      // 勾选第一个实例（最早日期 2026-08-05）。
      final firstCheckbox = find.byType(Checkbox).first;
      expect(tester.widget<Checkbox>(firstCheckbox).value, isFalse);
      await tester.tap(firstCheckbox);
      await tester.pumpAndSettle();

      // 数据库断言：最早实例已标记完成。
      final instances = await tasks.byGoal(goalId);
      expect(instances.first.plannedDate, '2026-08-05');
      expect(instances.first.status, 'done');
      // UI 复选框响应为已完成。
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isTrue,
      );
    });

    testWidgets('父卡片菜单删除：二次确认后模板与全部实例一并删除', (tester) async {
      await seedDailyTemplate();
      final template = (await recurrence.byGoal(goalId)).single;

      await pumpApp(tester);
      await openGoalDetail(tester);

      // 父卡片菜单 → 删除。
      await tester.tap(find.byTooltip('任务操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      // 二次确认提示将删除实例。
      expect(find.textContaining('将同时删除'), findsOneWidget);
      expect(find.textContaining('个任务实例'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      // 数据库断言：模板不存在、实例为空。
      expect(await recurrence.byId(template.id), isNull);
      expect(await tasks.byGoal(goalId), isEmpty);
      // UI：父卡片消失。
      expect(find.text('背单词'), findsNothing);
    });

    testWidgets('父卡片菜单编辑重复规则：可打开模板编辑对话框（FR-4.4）', (tester) async {
      await seedDailyTemplate();

      await pumpApp(tester);
      await openGoalDetail(tester);

      await tester.tap(find.byTooltip('任务操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑重复规则'));
      await tester.pumpAndSettle();

      expect(find.text('编辑重复任务'), findsOneWidget);
    });

    testWidgets('模板停止后父卡片标记「已停止」，菜单不再提供停止重复', (tester) async {
      await seedDailyTemplate();
      final template = (await recurrence.byGoal(goalId)).single;
      await recurrence.stop(template.id);

      await pumpApp(tester);
      await openGoalDetail(tester);

      expect(find.textContaining('已停止'), findsOneWidget);
      await tester.tap(find.byTooltip('任务操作').first);
      await tester.pumpAndSettle();
      expect(find.text('停止重复'), findsNothing);
    });

    testWidgets('懒加载：展开后仅实例化视口内的子任务行（性能回归）', (tester) async {
      await seedDailyTemplate();
      final total = (await tasks.byGoal(goalId)).length;
      expect(total, greaterThanOrEqualTo(30), reason: 'daily 模板应生成 30+ 实例');

      // 用小视口模拟真实窗口：SliverList 应只构建视口内的行。
      tester.view.physicalSize = const Size(500, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpApp(tester);
      await openGoalDetail(tester);

      // 展开前：无子任务行（无复选框）。
      expect(find.byType(Checkbox), findsNothing);

      // 滚动到父卡片可见后展开。
      await tester.scrollUntilVisible(
        find.byTooltip('展开重复任务'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开重复任务'));
      await tester.pumpAndSettle();

      // 展开后：小视口下实例化的 ListTile 数必须远小于实例总数（懒加载，
      // 而非一次性全量实例化 30+ 行）。
      final instantiated = tester.widgetList(find.byType(ListTile)).length;
      expect(
        instantiated,
        lessThan(total),
        reason: '展开后不应一次性实例化全部 $total 个子任务行（性能回归）',
      );
      expect(find.byType(Checkbox), findsWidgets);
    });
  });
}
