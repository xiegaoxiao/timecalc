import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// TaskRepository 内存数据库测试（FR-3）。
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

  group('任务 CRUD（FR-3.1 / FR-3.2）', () {
    test('创建任务：字段完整保存且可查询', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final subject = await subjects.create(goalId: goal.id, name: '数学', color: '#112233');
      final created = await tasks.create(
        goalId: goal.id,
        subjectId: subject.id,
        title: '完成第一章',
        note: '重点公式',
        plannedDate: '2026-01-10',
        estimatedMinutes: 120,
      );

      expect(created.title, '完成第一章');
      expect(created.subjectId, subject.id);
      expect(created.note, '重点公式');
      expect(created.plannedDate, '2026-01-10');
      expect(created.estimatedMinutes, 120);
      expect(created.status, 'todo');
      expect(created.completedAt, isNull);
    });

    test('任务按计划日期排序返回', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      await tasks.create(goalId: goal.id, title: '次日任务', plannedDate: '2026-01-02');
      await tasks.create(goalId: goal.id, title: '首日任务', plannedDate: '2026-01-01');

      final list = await tasks.byGoal(goal.id);
      expect(list.map((t) => t.title).toList(), ['首日任务', '次日任务']);
    });

    test('任务可指定科目，也可不指定（FR-1.5）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final subject = await subjects.create(goalId: goal.id, name: '数学', color: '#112233');
      await tasks.create(goalId: goal.id, subjectId: subject.id, title: '带科目', plannedDate: '2026-01-01');
      await tasks.create(goalId: goal.id, title: '无科目', plannedDate: '2026-01-01');

      final list = await tasks.byGoal(goal.id);
      expect(list.firstWhere((t) => t.title == '带科目').subjectId, subject.id);
      expect(list.firstWhere((t) => t.title == '无科目').subjectId, isNull);
    });

    test('更新任务字段', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final created = await tasks.create(goalId: goal.id, title: '原标题', plannedDate: '2026-01-01', estimatedMinutes: 60);

      await tasks.update(
        id: created.id,
        title: '新标题',
        note: '新备注',
        plannedDate: '2026-01-05',
        estimatedMinutes: const Value(90),
      );

      final fetched = await tasks.byId(created.id);
      expect(fetched?.title, '新标题');
      expect(fetched?.note, '新备注');
      expect(fetched?.plannedDate, '2026-01-05');
      expect(fetched?.estimatedMinutes, 90);
    });

    test('任务可显式清除预估时长与科目（Value(null)）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final subject = await subjects.create(goalId: goal.id, name: '数学', color: '#112233');
      final created = await tasks.create(
        goalId: goal.id, subjectId: subject.id, title: '任务', plannedDate: '2026-01-01', estimatedMinutes: 60,
      );

      await tasks.update(
        id: created.id,
        estimatedMinutes: const Value(null),
        subjectId: const Value(null),
      );

      final fetched = await tasks.byId(created.id);
      expect(fetched?.estimatedMinutes, isNull);
      expect(fetched?.subjectId, isNull);
    });

    test('删除任务', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final created = await tasks.create(goalId: goal.id, title: '任务', plannedDate: '2026-01-01');
      await tasks.delete(created.id);
      expect(await tasks.byId(created.id), isNull);
    });
  });

  group('完成任务状态切换（FR-3.2）', () {
    test('完成与取消完成：状态与 completedAt 同步更新', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final created = await tasks.create(goalId: goal.id, title: '任务', plannedDate: '2026-01-01');

      await tasks.setDone(created.id, true);
      var fetched = await tasks.byId(created.id);
      expect(fetched?.status, 'done');
      expect(fetched?.completedAt, isNotNull);

      await tasks.setDone(created.id, false);
      fetched = await tasks.byId(created.id);
      expect(fetched?.status, 'todo');
      expect(fetched?.completedAt, isNull);
    });

    test('完成/取消完成切换在事务内执行', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final created = await tasks.create(goalId: goal.id, title: '任务', plannedDate: '2026-01-01');

      await expectLater(
        db.transaction(() async {
          await tasks.setDone(created.id, true);
          throw StateError('模拟事务中途失败');
        }),
        throwsA(isA<StateError>()),
      );

      final fetched = await tasks.byId(created.id);
      expect(fetched?.status, 'todo');
      expect(fetched?.completedAt, isNull);
    });
  });

  group('科目（FR-1.5）', () {
    test('科目增删改查', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final created = await subjects.create(goalId: goal.id, name: '数学', color: '#112233', sortOrder: 1);
      expect(created.name, '数学');

      await subjects.rename(id: created.id, name: '高等数学');
      expect((await subjects.byId(created.id))?.name, '高等数学');

      final list = await subjects.byGoal(goal.id);
      expect(list.map((s) => s.id), contains(created.id));
    });

    test('删除科目时任务保留但解除科目归属', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final subject = await subjects.create(goalId: goal.id, name: '数学', color: '#112233');
      final task = await tasks.create(goalId: goal.id, subjectId: subject.id, title: '任务', plannedDate: '2026-01-01');

      await subjects.delete(subject.id);

      expect(await subjects.byId(subject.id), isNull);
      final fetched = await tasks.byId(task.id);
      expect(fetched, isNotNull);
      expect(fetched?.subjectId, isNull);
    });
  });
}
