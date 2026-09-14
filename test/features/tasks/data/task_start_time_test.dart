import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/recurrence_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_rule.dart';

/// 小时级排程（schema v16，Tasks/RecurrenceTemplates.start_time）数据层测试。
///
/// 覆盖：写入/更新/清空时刻、同日按时刻排序（无时刻置顶）、重复模板的
/// 时刻继承到实例。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late RecurrenceRepository recurrences;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final fixedNow = DateTime(2026, 8, 5, 12);
    goals = GoalRepository(db, clock: () => fixedNow);
    tasks = TaskRepository(db, clock: () => fixedNow);
    recurrences = RecurrenceRepository(db, clock: () => fixedNow);
  });

  tearDown(() async {
    await db.close();
  });

  group('TaskRepository.startTime', () {
    test('创建时可带时刻，默认只排到天', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');

      final withTime = await tasks.create(
        goalId: goal.id,
        title: '背单词',
        plannedDate: '2026-08-06',
        startTime: '20:30',
      );
      expect(withTime.startTime, '20:30');

      final withoutTime = await tasks.create(
        goalId: goal.id,
        title: '复盘',
        plannedDate: '2026-08-06',
      );
      expect(withoutTime.startTime, isNull);
    });

    test('更新时刻与显式清空（Value(null) 回到只排到天）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      final task = await tasks.create(
        goalId: goal.id,
        title: '听课',
        plannedDate: '2026-08-06',
        startTime: '08:00',
      );

      await tasks.update(id: task.id, startTime: const Value('09:15'));
      expect((await tasks.byId(task.id))!.startTime, '09:15');

      // 不传 startTime 表示不修改。
      await tasks.update(id: task.id, title: '听课（改标题）');
      expect((await tasks.byId(task.id))!.startTime, '09:15');

      // 显式置空。
      await tasks.update(id: task.id, startTime: const Value(null));
      expect((await tasks.byId(task.id))!.startTime, isNull);
    });

    test('批量创建共用同一时刻', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      await tasks.batchCreate(
        goalId: goal.id,
        titles: ['套卷一', '套卷二'],
        startDate: '2026-08-06',
        dateIntervalDays: 7,
        startTime: '14:00',
      );
      final rows = await tasks.byGoal(goal.id);
      expect(rows.length, 2);
      expect(rows.every((t) => t.startTime == '14:00'), isTrue);
    });

    test('byDate：同一天内按时刻升序，无时刻（只排到天）置顶', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      // 故意乱序创建，验证查询侧排序。
      await tasks.create(
        goalId: goal.id,
        title: '晚上',
        plannedDate: '2026-08-06',
        startTime: '20:00',
      );
      await tasks.create(
        goalId: goal.id,
        title: '全天',
        plannedDate: '2026-08-06',
      );
      await tasks.create(
        goalId: goal.id,
        title: '早上',
        plannedDate: '2026-08-06',
        startTime: '07:30',
      );
      await tasks.create(
        goalId: goal.id,
        title: '其它日期',
        plannedDate: '2026-08-07',
        startTime: '06:00',
      );

      final rows = await tasks.byDate('2026-08-06');
      expect(rows.map((t) => t.title), ['全天', '早上', '晚上']);
    });

    test('延期只改日期，保留时刻', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      final task = await tasks.create(
        goalId: goal.id,
        title: '背单词',
        plannedDate: '2026-08-06',
        startTime: '20:30',
      );

      await tasks.defer(task.id, '2026-08-07');
      final deferred = (await tasks.byId(task.id))!;
      expect(deferred.plannedDate, '2026-08-07');
      expect(deferred.startTime, '20:30');
    });

    test('allActive 返回未归档任务（含时刻），排除归档任务', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      final active = await tasks.create(
        goalId: goal.id,
        title: '进行中',
        plannedDate: '2026-08-06',
        startTime: '20:30',
      );
      final archived = await tasks.create(
        goalId: goal.id,
        title: '已归档',
        plannedDate: '2026-08-05',
      );
      await tasks.archiveAllActive(goal.id);
      // 归档全部后手工恢复一条，构造「一条归档 + 一条活跃」。
      await tasks.restoreArchived(active.id);
      expect((await tasks.byId(archived.id))!.archivedAt, isNotNull);

      final rows = await tasks.allActive();
      expect(rows.map((t) => t.id), [active.id]);
      expect(rows.single.startTime, '20:30');
    });
  });

  group('RecurrenceRepository.startTime', () {
    test('模板时刻继承到每条生成的实例', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      final template = await recurrences.create(
        goalId: goal.id,
        title: '每天背单词',
        rule: const RecurrenceRule(ruleType: 'daily', ruleJson: '{}'),
        startDate: '2026-08-05',
        endDate: '2026-08-07',
        startTime: '20:00',
        today: DateTime(2026, 8, 5, 12),
      );
      expect(template.startTime, '20:00');

      final instances = await tasks.byDate('2026-08-05');
      expect(instances.single.startTime, '20:00');
      final later = await tasks.byDate('2026-08-07');
      expect(later.single.startTime, '20:00');
    });

    test('滚动生成（generateDue）的新实例继续带模板时刻', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      await recurrences.create(
        goalId: goal.id,
        title: '每天背单词',
        rule: const RecurrenceRule(ruleType: 'daily', ruleJson: '{}'),
        startDate: '2026-08-05',
        startTime: '21:00',
        today: DateTime(2026, 8, 5, 12),
      );

      // 时间推进 10 天后滚动生成新窗口实例。
      await recurrences.generateDue(today: DateTime(2026, 8, 15, 12));
      final rows = await tasks.byDate('2026-08-15');
      expect(rows.single.startTime, '21:00');
    });

    test('修改模板时刻：仅改模板不动实例 / 改未来实例同步新时刻', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-12-31');
      final template = await recurrences.create(
        goalId: goal.id,
        title: '每天背单词',
        rule: const RecurrenceRule(ruleType: 'daily', ruleJson: '{}'),
        startDate: '2026-08-05',
        startTime: '20:00',
        today: DateTime(2026, 8, 5, 12),
      );

      // 仅改模板：已生成实例（含今天）保持旧时刻。
      await recurrences.updateRule(
        templateId: template.id,
        rule: const RecurrenceRule(ruleType: 'daily', ruleJson: '{}'),
        applyTo: RecurrenceApplyTo.template,
        startTime: const Value('06:30'),
        today: DateTime(2026, 8, 5, 12),
      );
      expect((await recurrences.byId(template.id))!.startTime, '06:30');
      expect((await tasks.byDate('2026-08-05')).single.startTime, '20:00');

      // 改未来实例：今天之后重生成的实例用新时刻（FR-4.4 的「未来实例」
      // 不含今天，今天的实例保留旧时刻）。
      await recurrences.updateRule(
        templateId: template.id,
        rule: const RecurrenceRule(ruleType: 'daily', ruleJson: '{}'),
        applyTo: RecurrenceApplyTo.future,
        startTime: const Value('07:00'),
        today: DateTime(2026, 8, 5, 12),
      );
      expect((await tasks.byDate('2026-08-06')).single.startTime, '07:00');
      expect((await tasks.byDate('2026-08-05')).single.startTime, '20:00');
    });
  });
}
