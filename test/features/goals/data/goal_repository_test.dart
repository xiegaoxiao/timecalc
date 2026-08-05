import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// GoalRepository 内存数据库测试（SOP S5：DAO/Repository 层用内存库）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
  late TaskRepository tasks;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    subjects = SubjectRepository(db);
    tasks = TaskRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('目标 CRUD（FR-1.1）', () {
    test('创建目标后可按 id 查询并出现在全部列表中', () async {
      final created = await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
      expect(created.id, greaterThan(0));
      expect(created.title, '考研数学');
      expect(created.deadlineDate, '2026-12-20');
      expect(created.status, 'active');

      final fetched = await goals.byId(created.id);
      expect(fetched?.title, '考研数学');

      final all = await goals.watchAll();
      expect(all.map((g) => g.id), contains(created.id));
    });

    test('创建目标支持描述与排序（新目标在前）', () async {
      final first = await goals.create(title: '目标A', deadlineDate: '2026-01-01');
      final second = await goals.create(title: '目标B', deadlineDate: '2026-02-01', description: '备注');

      final all = await goals.watchAll();
      expect(all.map((g) => g.id).toList(), [second.id, first.id]);
      expect(all.first.description, '备注');
    });

    test('更新目标基础字段', () async {
      final created = await goals.create(title: '原标题', deadlineDate: '2026-01-01');
      await goals.update(id: created.id, title: '新标题', deadlineDate: '2026-03-15');

      final fetched = await goals.byId(created.id);
      expect(fetched?.title, '新标题');
      expect(fetched?.deadlineDate, '2026-03-15');
    });

    test('标记目标为已完成/已放弃（FR-1.4）', () async {
      final created = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      await goals.update(id: created.id, status: 'completed');
      expect((await goals.byId(created.id))?.status, 'completed');
      await goals.update(id: created.id, status: 'abandoned');
      expect((await goals.byId(created.id))?.status, 'abandoned');
    });
  });

  group('删除目标级联事务（NFR-2 / FR-1 验收）', () {
    test('删除目标连带删除其科目与任务', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final subject = await subjects.create(goalId: goal.id, name: '数学', color: '#FF0000');
      await tasks.create(goalId: goal.id, title: '任务1', plannedDate: '2026-01-01');
      await tasks.create(goalId: goal.id, subjectId: subject.id, title: '任务2', plannedDate: '2026-01-02');

      await goals.deleteWithCascade(goal.id);

      expect(await goals.byId(goal.id), isNull);
      expect(await subjects.byGoal(goal.id), isEmpty);
      expect(await tasks.byGoal(goal.id), isEmpty);
    });

    test('删除不存在的目标不报错且无副作用', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      await goals.deleteWithCascade(9999);
      expect(await goals.byId(goal.id), isNotNull);
    });

    test('删除目标在事务中途失败时回滚，不留下半删除数据', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      await tasks.create(goalId: goal.id, title: '任务', plannedDate: '2026-01-01');

      await expectLater(
        // 在级联删除事务内抛错，验证回滚：goals 行不应被删除。
        db.transaction(() async {
          await goals.deleteWithCascade(goal.id);
          throw StateError('模拟事务中途失败');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await goals.byId(goal.id), isNotNull);
      expect(await tasks.byGoal(goal.id), hasLength(1));
    });
  });
}
