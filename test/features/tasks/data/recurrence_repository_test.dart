import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/recurrence_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_rule.dart';

/// RecurrenceRepository 内存数据库测试（FR-4，模板 + 实例）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
  late TaskRepository tasks;
  late RecurrenceRepository recurrence;

  final fixedToday = DateTime(2026, 8, 5, 12); // 周三

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    subjects = SubjectRepository(db);
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

    test('艾宾浩斯序列：窗口内按绝对复习日生成', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '复习单词',
        rule: rule('sequence', const {'offsets': [1, 2, 4, 7, 15, 30]}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      final instances = await tasks.byGoal(goal.id);
      // offsets 为绝对复习日：+1 +2 +4 +7 +15 +30（+30 恰为窗口终点）。
      expect(
        instances.map((t) => t.plannedDate).toList(),
        ['2026-08-05', '2026-08-06', '2026-08-07', '2026-08-09', '2026-08-12', '2026-08-20', '2026-09-04'],
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

    test('脏 generatedThroughDate（非日期文本）不中断其余模板（回归 #4）', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final dirty = await recurrence.create(
        goalId: goal.id,
        title: '脏模板',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );
      final clean = await recurrence.create(
        goalId: goal.id,
        title: '干净模板',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );
      // 模拟旧备份恢复等路径写入的空 generatedThroughDate（codec ?? '' 兜底）。
      await (db.update(db.recurrenceTemplates)
            ..where((t) => t.id.equals(dirty.id)))
          .write(
            RecurrenceTemplatesCompanion(generatedThroughDate: const Value('')),
          );

      // 修复前：_plusDays('') 抛 FormatException 使整个 generateDue 事务
      // 失败，所有 active 模板停止滚动生成。
      final later = DateTime(2026, 8, 15, 12);
      expect(await recurrence.generateDue(today: later), 10); // 干净模板补齐 10 条
      final cleanInstances = (await tasks.byGoal(goal.id))
          .where((t) => t.recurrenceTemplateId == clean.id);
      expect(cleanInstances, hasLength(41)); // 31 + 10
      // 脏模板被跳过且窗口未推进（下次启动仍会重试，而非永久跳过）。
      expect((await recurrence.byId(dirty.id))?.generatedThroughDate, '');
    });

    test('脏 startDate（非日期文本）跳过且不推进窗口（回归 #4）', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final dirty = await recurrence.create(
        goalId: goal.id,
        title: '脏起始日模板',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );
      await (db.update(db.recurrenceTemplates)
            ..where((t) => t.id.equals(dirty.id)))
          .write(
            RecurrenceTemplatesCompanion(startDate: const Value('')),
          );

      // 脏 startDate 被跳过，不抛异常、不推进窗口。
      final later = DateTime(2026, 8, 15, 12);
      expect(await recurrence.generateDue(today: later), 0);
      expect((await recurrence.byId(dirty.id))?.generatedThroughDate, '2026-09-04');
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

    test('编辑基础信息：标题/科目/时长/起始日期写入模板', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final subject = await subjects.create(
        goalId: goal.id,
        name: '数学',
        color: '#000000',
      );
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // 仅改基础信息，规则不变。
      await recurrence.updateRule(
        templateId: template.id,
        rule: rule('daily', const {}),
        applyTo: RecurrenceApplyTo.template,
        today: fixedToday,
        title: '数学真题',
        subjectId: Value(subject.id),
        estimatedMinutes: Value(45),
        startDate: '2026-08-10',
      );

      final updated = await recurrence.byId(template.id);
      expect(updated?.title, '数学真题');
      expect(updated?.subjectId, subject.id);
      expect(updated?.estimatedMinutes, 45);
      expect(updated?.startDate, '2026-08-10');
      // 仅改模板：已有实例不动。
      expect((await tasks.byGoal(goal.id)).length, 31);
    });

    test('编辑起始日期并应用未来实例：未来实例按新起始日重生成', () async {
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
        rule: rule('daily', const {}),
        applyTo: RecurrenceApplyTo.future,
        today: fixedToday,
        title: '改期背单词',
        startDate: '2026-08-10',
      );

      // applyTo.future 仅处理「严格晚于今天」的实例：今天（08-05）的
      // 实例不属于未来，保留；未来实例按新起始日 08-10 重新生成。
      final instances = await tasks.byGoal(goal.id);
      final dates = instances.map((t) => t.plannedDate).toList();
      expect(dates, contains('2026-08-05'));
      expect(dates, contains('2026-08-10'));
      expect(dates, isNot(contains('2026-08-06')));
      // 新标题用于重新生成的实例。
      final regenerated = instances.firstWhere((t) => t.plannedDate == '2026-08-10');
      expect(regenerated.title, '改期背单词');
    });

    test('future 应用后 generatedThroughDate 直接推进到窗口目标，不重复重算', () async {
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
        rule: rule('weekly', const {'weekdays': [1, 3, 5]}),
        applyTo: RecurrenceApplyTo.future,
        today: fixedToday,
      );

      // future 应用后已按新规则生成到 today+30：窗口应直接推进到位，
      // 后续 generateDue 无需对同一窗口重复重算（回归：曾停留在 today-1）。
      final updated = await recurrence.byId(template.id);
      expect(updated?.generatedThroughDate, '2026-09-04'); // 08-05 + 30

      final generated = await recurrence.generateDue(today: fixedToday);
      expect(generated, 0); // 窗口已完整，无新增实例。
    });

    test('仅修改模板缩短 endDate：generatedThroughDate 钳制到新结束日（回归 #5）', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );
      expect(template.generatedThroughDate, '2026-09-04'); // 08-05 + 30

      // 仅修改模板：结束日缩短到 08-20（早于旧窗口 09-04）。
      await recurrence.updateRule(
        templateId: template.id,
        rule: rule('daily', const {}),
        endDate: '2026-08-20',
        applyTo: RecurrenceApplyTo.template,
        today: fixedToday,
      );

      // 窗口记账钳制到新结束日；实例保留（31 条不变，符合「仅修改模板
      // 不触碰实例」语义，超窗实例不再由窗口推进逻辑生成）。
      final updated = await recurrence.byId(template.id);
      expect(updated?.generatedThroughDate, '2026-08-20');
      expect((await tasks.byGoal(goal.id)).length, 31);
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

  group('deleteWithInstances（删除模板及其全部实例）', () {
    test('模板与全部实例一并删除，不留普通任务', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );
      final instanceCount = (await tasks.byGoal(goal.id)).length;
      expect(instanceCount, greaterThanOrEqualTo(2));

      await recurrence.deleteWithInstances(template.id);

      expect(await recurrence.byId(template.id), isNull);
      expect(await tasks.byGoal(goal.id), isEmpty);
      expect(await tasks.allTodoTasks(), isEmpty);
    });

    test('其他模板的实例不受影响', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final keep = await recurrence.create(
        goalId: goal.id,
        title: '保留的重复',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );
      final remove = await recurrence.create(
        goalId: goal.id,
        title: '要删除的重复',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      await recurrence.deleteWithInstances(remove.id);

      expect(await recurrence.byId(remove.id), isNull);
      expect((await recurrence.byId(keep.id))?.title, '保留的重复');
      final instances = await tasks.byGoal(goal.id);
      expect(instances, isNotEmpty);
      expect(instances.every((t) => t.recurrenceTemplateId == keep.id), isTrue);
    });
  });

  group('科目删除联动（subject_id 外键，回归）', () {
    test('科目被重复模板引用时删除成功：模板与任务解除归属', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final subject = await subjects.create(
        goalId: goal.id,
        name: '数学',
        color: '#000000',
      );
      final template = await recurrence.create(
        goalId: goal.id,
        subjectId: subject.id,
        title: '数学真题',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // 修复前：DELETE FROM subjects 触发 recurrence_templates.subject_id
      // 外键约束异常导致删除科目失败。
      await subjects.delete(subject.id);

      expect(await subjects.byId(subject.id), isNull);
      final updated = await recurrence.byId(template.id);
      expect(updated?.subjectId, isNull);
      // 实例任务保留且解除科目归属。
      final instances = await tasks.byGoal(goal.id);
      expect(instances, isNotEmpty);
      expect(instances.every((t) => t.subjectId == null), isTrue);
    });
  });

  group('墓碑（deletedInstanceDates，schema v5）', () {
    test('删除实例后 generateDue 不再复活该日期（回归）', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      // updateRule(future) 会把 generatedThrough 重置到今日之前，
      // 使后续 generateDue 从今日起重扫窗口——墓碑日期此时才可能落入窗口。
      await recurrence.updateRule(
        templateId: template.id,
        rule: rule('daily', const {}),
        applyTo: RecurrenceApplyTo.future,
        today: fixedToday,
      );

      // 删除 08-20 的实例。
      final instances = await tasks.byGoal(goal.id);
      final target = instances.firstWhere((t) => t.plannedDate == '2026-08-20');
      await tasks.delete(target.id);

      // 模板墓碑已记录该日期。
      final updated = await recurrence.byId(template.id);
      expect(RecurrenceRepository.decodeTombstones(updated!.deletedInstanceDates),
          {'2026-08-20'});

      // 时间前移到 08-25：generateDue 窗口含 08-20，应跳过墓碑日期。
      final later = DateTime(2026, 8, 25, 12);
      expect(await recurrence.generateDue(today: later), 20); // 09-05 ~ 09-24 共 20 条
      final all = await tasks.byGoal(goal.id);
      expect(all.map((t) => t.plannedDate), isNot(contains('2026-08-20')));
      // 08-20 之后的日期正常生成。
      expect(all.map((t) => t.plannedDate), contains('2026-08-21'));
      expect(all.map((t) => t.plannedDate), contains('2026-09-24'));
    });

    test('updateRule 重生成时跳过墓碑日期，已完成实例保留', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      final instances = await tasks.byGoal(goal.id);
      final done = instances.firstWhere((t) => t.plannedDate == '2026-08-05');
      await tasks.setDone(done.id, true);
      final deleted = instances.firstWhere((t) => t.plannedDate == '2026-08-08');
      await tasks.delete(deleted.id);

      // 改为每周一三五并应用未来实例：重生成时跳过墓碑日期 08-08。
      await recurrence.updateRule(
        templateId: template.id,
        rule: rule('weekly', const {'weekdays': [1, 3, 5]}),
        applyTo: RecurrenceApplyTo.future,
        today: fixedToday,
      );

      final all = await tasks.byGoal(goal.id);
      // 已完成实例保留；墓碑日期（08-08，周五）不复活。
      expect(all.map((t) => t.plannedDate), contains('2026-08-05'));
      expect(all.map((t) => t.plannedDate), isNot(contains('2026-08-08')));
      // 其余日期落在一三五。
      final weekdays = all
          .where((t) => t.plannedDate != '2026-08-05')
          .map((t) => DateTime.parse(t.plannedDate).weekday)
          .toSet();
      expect(weekdays, {1, 3, 5});
    });

    test('墓碑编解码：空/null/非法 JSON 宽容处理', () async {
      expect(RecurrenceRepository.encodeTombstones({}), isNull);
      expect(RecurrenceRepository.encodeTombstones({'2026-08-10'}), '["2026-08-10"]');
      expect(RecurrenceRepository.decodeTombstones(null), isEmpty);
      expect(RecurrenceRepository.decodeTombstones(''), isEmpty);
      expect(RecurrenceRepository.decodeTombstones('not-json'), isEmpty);
      expect(RecurrenceRepository.decodeTombstones('["2026-08-10"]'), {'2026-08-10'});
      // 非法元素（非日期字符串）被过滤。
      expect(
        RecurrenceRepository.decodeTombstones('["2026-08-10", 42, "bad"]'),
        {'2026-08-10'},
      );
    });

    test('删除普通任务不写墓碑', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
      final template = await recurrence.create(
        goalId: goal.id,
        title: '背单词',
        rule: rule('daily', const {}),
        startDate: '2026-08-05',
        today: fixedToday,
      );

      final ordinary = await tasks.create(
        goalId: goal.id,
        title: '普通任务',
        plannedDate: '2026-08-06',
      );
      await tasks.delete(ordinary.id);

      final updated = await recurrence.byId(template.id);
      expect(updated?.deletedInstanceDates, isNull);
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
