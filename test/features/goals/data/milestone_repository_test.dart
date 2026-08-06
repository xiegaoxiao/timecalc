import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/milestone_repository.dart';

/// MilestoneRepository 内存数据库测试（SOP S5：DAO/Repository 层用内存库）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late MilestoneRepository milestones;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    milestones = MilestoneRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('里程碑 CRUD（FR-2.1）', () {
    test('创建里程碑后可按 id 查询并出现在目标列表中', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      final created = await milestones.create(
        goalId: goal.id,
        title: '完成一轮复习',
        date: '2026-09-30',
      );

      expect(created.id, greaterThan(0));
      expect(created.title, '完成一轮复习');
      expect(created.status, MilestoneStatus.todo);

      final byId = await milestones.byId(created.id);
      expect(byId!.title, '完成一轮复习');
      final list = await milestones.byGoal(goal.id);
      expect(list.single.title, '完成一轮复习');
    });

    test('byGoal 按 sortOrder 升序返回', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      await milestones.create(
        goalId: goal.id,
        title: '第二个',
        date: '2026-10-01',
        sortOrder: 2,
      );
      await milestones.create(
        goalId: goal.id,
        title: '第一个',
        date: '2026-09-01',
        sortOrder: 1,
      );

      final list = await milestones.byGoal(goal.id);
      expect(list.map((m) => m.title).toList(), ['第一个', '第二个']);
    });

    test('编辑标题/日期与标记完成状态', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      final created = await milestones.create(
        goalId: goal.id,
        title: '一轮',
        date: '2026-09-30',
      );

      await milestones.update(
        id: created.id,
        title: '一轮复习（调整）',
        date: '2026-10-15',
      );
      await milestones.update(id: created.id, done: true);

      final updated = await milestones.byId(created.id);
      expect(updated!.title, '一轮复习（调整）');
      expect(updated.date, '2026-10-15');
      expect(updated.status, MilestoneStatus.done);

      // 可取消完成。
      await milestones.update(id: created.id, done: false);
      final reopened = await milestones.byId(created.id);
      expect(reopened!.status, MilestoneStatus.todo);
    });

    test('删除里程碑后不再出现', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      final created = await milestones.create(
        goalId: goal.id,
        title: '一轮',
        date: '2026-09-30',
      );

      await milestones.delete(created.id);
      expect(await milestones.byId(created.id), isNull);
      expect(await milestones.byGoal(goal.id), isEmpty);
    });
  });

  group('nextUpcoming（FR-2.3：最近未完成里程碑）', () {
    test('返回日期最近的未完成里程碑', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      await milestones.create(
        goalId: goal.id,
        title: '较晚',
        date: '2026-11-01',
      );
      await milestones.create(
        goalId: goal.id,
        title: '最近',
        date: '2026-10-15',
      );

      final upcoming = await milestones.nextUpcoming(
        goal.id,
        today: DateTime(2026, 10, 1),
      );
      expect(upcoming!.title, '最近');
    });

    test('已完成的里程碑不计入最近', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      final early = await milestones.create(
        goalId: goal.id,
        title: '早期已完成',
        date: '2026-09-30',
      );
      await milestones.create(
        goalId: goal.id,
        title: '尚未完成',
        date: '2026-10-15',
      );
      await milestones.update(id: early.id, done: true);

      final upcoming = await milestones.nextUpcoming(
        goal.id,
        today: DateTime(2026, 10, 1),
      );
      expect(upcoming!.title, '尚未完成');
    });

    test('日期早于今天的未完成里程碑不返回（今日起算）', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      await milestones.create(
        goalId: goal.id,
        title: '已过期未完成',
        date: '2026-09-01',
      );
      await milestones.create(
        goalId: goal.id,
        title: '未来节点',
        date: '2026-10-15',
      );

      final upcoming = await milestones.nextUpcoming(
        goal.id,
        today: DateTime(2026, 10, 1),
      );
      expect(upcoming!.title, '未来节点');
    });

    test('全部完成后返回 null', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      final m = await milestones.create(
        goalId: goal.id,
        title: '唯一',
        date: '2026-10-15',
      );
      await milestones.update(id: m.id, done: true);

      final upcoming = await milestones.nextUpcoming(
        goal.id,
        today: DateTime(2026, 10, 1),
      );
      expect(upcoming, isNull);
    });
  });

  group('目标级联删除（NFR-2）', () {
    test('删除目标连带删除其里程碑，不留孤儿数据', () async {
      final goal = await goals.create(title: '考研', deadlineDate: '2026-12-20');
      await milestones.create(
        goalId: goal.id,
        title: '一轮',
        date: '2026-09-30',
      );
      await milestones.create(
        goalId: goal.id,
        title: '二轮',
        date: '2026-10-30',
      );

      await goals.deleteWithCascade(goal.id);

      expect(await milestones.byGoal(goal.id), isEmpty);
      expect(
        await db.select(db.milestones).get(),
        isEmpty,
        reason: '删除目标后不应留下孤儿里程碑',
      );
    });
  });
}
