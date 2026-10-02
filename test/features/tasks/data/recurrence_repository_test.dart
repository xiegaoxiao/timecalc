import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/recurrence_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_rule.dart';

/// RecurrenceRepository 内存数据库测试（FR-4，模板 + 实例）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late RecurrenceRepository recurrence;

  final fixedToday = DateTime(2026, 8, 5, 12); // 周三

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    recurrence = RecurrenceRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  RecurrenceRule rule(String type, Map<String, dynamic> json) =>
      RecurrenceRule.fromMap(ruleType: type, json: json);

  group('create（创建模板 + 初始实例）', () {
    test('每天：生成 today~today+30 窗口内的实例', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        estimatedMinutes: 30,
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      expect(template.ruleType, 'daily');
      expect(template.active, isTrue);
      expect(template.generatedThroughDate, '2026-09-04'); // 08-05 + 30

      final instances = await tasks.byGoal(goal.id);
      expect(instances, hasLength(31));
      expect(instances.first.recurrenceTemplateId, template.id);
      expect(instances.first.plannedDate, '2026-08-05');
      expect(instances.last.plannedDate, '2026-09-04');
    });

    test('艾宾浩斯序列：窗口内按累计间隔生成', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '复习单词',
        rule: rule('sequence', const {'offsets': [1, 2, 4, 7, 15, 30]}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      final instances = await tasks.byGoal(goal.id);
      // 起始日 +1 +3 +7 +14 +29（+59 超出 30 天窗口）。
      expect(
        instances.map((t) => t.plannedDate).toList(),
        ['2026-08-05', '2026-08-06', '2026-08-08', '2026-08-12', '2026-08-19', '2026-09-03'],
      );
      expect(template.generatedThroughDate, '2026-09-04');
    });

    test('结束日期早于窗口：只生成到结束日期', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '期间任务',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        endDate: '2026-08-08',
        today: fixedToday,
      );

      expect(template.generatedThroughDate, '2026-08-08');
      final instances = await tasks.byGoal(goal.id);
      expect(instances.map((t) => t.plannedDate).toList(),
          ['2026-08-05', '2026-08-06', '2026-08-07', '2026-08-08']);
    });

    test('非法规则抛 ArgumentError，不产生任何写入', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      await expectLater(
        recurrence.create(
          goalId: goal.id,
          title: '坏规则',
          rule: rule('weekly', const {'weekdays': []}),
          startDate: '2026-08-05',
          today: fixedToday,
        ),
        throwsArgumentError,
      );
      expect(await tasks.byGoal(goal.id), isEmpty);
    });
  });

  group('generateDue（滚动窗口）', () {
    test('创建后重复调用幂等：不重复生成实例', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // 同一天重复调用：窗口未前移，生成 0 条。
      expect(await recurrence.generateDue(today: fixedToday), 0);
      expect((await tasks.byGoal(goal.id)).length, 31);
    });

    test('时间前进后补齐缺失实例', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // 模拟 10 天后：窗口前移到 09-14，补齐 10 条。
      final later = DateTime(2026, 8, 15, 12);
      expect(await recurrence.generateDue(today: later), 10);
      final instances = await tasks.byGoal(goal.id);
      expect(instances.last.plannedDate, '2026-09-14');
    });

    test('停止后不再生成新实例，历史实例保留（FR-4.5）', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      await recurrence.stop(template.id);
      expect((await recurrence.byId(template.id))?.active, isFalse);

      final later = DateTime(2026, 8, 20, 12);
      expect(await recurrence.generateDue(today: later), 0);
      expect((await tasks.byGoal(goal.id)).length, 31); // 实例保留
    });
  });

  group('updateRule（FR-4.4）', () {
    test('仅修改模板：已有实例不动', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      await recurrence.updateRule(
        templateId: template.id,
        rule: rule('weekly', const {'weekdays': [1, 3]}),
        applyTo: RecurrenceApplyTo.template,
        today: fixedToday,
      );

      // 实例保持 daily 的 31 条不变。
      expect((await tasks.byGoal(goal.id)).length, 31);
      final updated = await recurrence.byId(template.id);
      expect(updated?.ruleType, 'weekly');
    });

    test('修改未来实例：删除今天之后未完成，重新按新规则生成；已完成保留', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // 今天实例已完成（应保留，不覆盖）。
      final todayInstance = (await tasks.byGoal(goal.id)).first;
      await tasks.setDone(todayInstance.id, true);

      // 改为每周一三五，重新生成未来实例。
      await recurrence.updateRule(
        templateId: template.id,
        rule: rule('weekly', const {'weekdays': [1, 3, 5]}),
        applyTo: RecurrenceApplyTo.future,
        today: fixedToday,
      );

      final instances = await tasks.byGoal(goal.id);
      // 今天的已完成实例保留。
      expect(instances.map((t) => t.plannedDate), contains('2026-08-05'));
      // 其余实例全部落在一三五。
      final weekdays = instances
          .where((t) => t.plannedDate != '2026-08-05')
          .map((t) => DateTime.parse(t.plannedDate).weekday)
          .toSet();
      expect(weekdays, {1, 3, 5});
    });
  });

  group('delete（删除模板，实例降级）', () {
    test('实例解除模板关联并保留为普通任务', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      await recurrence.delete(template.id);

      expect(await recurrence.byId(template.id), isNull);
      final instances = await tasks.byGoal(goal.id);
      expect(instances, isNotEmpty);
      expect(instances.every((t) => t.recurrenceTemplateId == null), isTrue);
    });
  });

  group('替换导入联动', () {
    test('替换导入停用该目标 active 模板', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // 替换导入（即使 JSON 为空任务，也停用模板）。
      await tasks.importPlan(
        goalId: goal.id,
        items: const [],
        replaceExisting: true,
      );

      expect((await recurrence.byId(template.id))?.active, isFalse);
      // 模板停用后不再滚动生成。
      expect(await recurrence.generateDue(today: fixedToday), 0);
    });
  });
}
