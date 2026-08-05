import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/domain/task_import_parser.dart';

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
        note: const Value('新备注'),
        plannedDate: '2026-01-05',
        estimatedMinutes: const Value(90),
      );

      final fetched = await tasks.byId(created.id);
      expect(fetched?.title, '新标题');
      expect(fetched?.note, '新备注');
      expect(fetched?.plannedDate, '2026-01-05');
      expect(fetched?.estimatedMinutes, 90);
    });

    test('编辑时备注可显式清空（Value(null)，回归）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-01-01');
      final created = await tasks.create(
        goalId: goal.id,
        title: '任务',
        note: '旧备注',
        plannedDate: '2026-01-01',
      );

      // 修复前：传 null 被当作「不修改」，备注无法清空。
      await tasks.update(id: created.id, note: const Value(null));

      final fetched = await tasks.byId(created.id);
      expect(fetched?.note, isNull);
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

  group('按日期查询（M2：今日任务与日历）', () {
    test('byDate 返回指定日期的全部任务（跨目标）', () async {
      final goalA = await goals.create(title: '目标A', deadlineDate: '2026-02-01');
      final goalB = await goals.create(title: '目标B', deadlineDate: '2026-02-01');
      await tasks.create(goalId: goalA.id, title: 'A-当日', plannedDate: '2026-01-10');
      await tasks.create(goalId: goalA.id, title: 'A-其他日', plannedDate: '2026-01-11');
      await tasks.create(goalId: goalB.id, title: 'B-当日', plannedDate: '2026-01-10');

      final list = await tasks.byDate('2026-01-10');
      expect(list.map((t) => t.title).toSet(), {'A-当日', 'B-当日'});
    });

    test('byDateRange 返回日期范围内的任务（含首尾）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      await tasks.create(goalId: goal.id, title: '月初', plannedDate: '2026-02-01');
      await tasks.create(goalId: goal.id, title: '月中', plannedDate: '2026-02-15');
      await tasks.create(goalId: goal.id, title: '月末', plannedDate: '2026-02-28');
      await tasks.create(goalId: goal.id, title: '范围外', plannedDate: '2026-03-05');

      final list = await tasks.byDateRange('2026-02-01', '2026-02-28');
      expect(list.map((t) => t.title).toSet(), {'月初', '月中', '月末'});
    });

    test('unfinishedBefore 只返回早于指定日且未完成的任务', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      final early = await tasks.create(goalId: goal.id, title: '昨日未完成', plannedDate: '2026-01-05');
      await tasks.create(goalId: goal.id, title: '当日任务', plannedDate: '2026-01-10');

      // 未完成时进入结果。
      var list = await tasks.unfinishedBefore('2026-01-10');
      expect(list.map((t) => t.title), ['昨日未完成']);

      // 完成后不再进入结果。
      await tasks.setDone(early.id, true);
      list = await tasks.unfinishedBefore('2026-01-10');
      expect(list, isEmpty);
    });
  });

  group('延期（FR-3.3）', () {
    test('defer 记录原计划日期一次，任务内容与归属保持不变', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      final subject = await subjects.create(goalId: goal.id, name: '数学', color: '#112233');
      final created = await tasks.create(
        goalId: goal.id,
        subjectId: subject.id,
        title: '套卷',
        note: '含解析',
        plannedDate: '2026-01-10',
        estimatedMinutes: 90,
      );

      await tasks.defer(created.id, '2026-01-12');
      var fetched = await tasks.byId(created.id);
      expect(fetched?.plannedDate, '2026-01-12');
      expect(fetched?.originalPlannedDate, '2026-01-10');
      expect(fetched?.title, '套卷');
      expect(fetched?.subjectId, subject.id);
      expect(fetched?.note, '含解析');
      expect(fetched?.estimatedMinutes, 90);

      // 再次延期不覆盖原计划日期。
      await tasks.defer(created.id, '2026-01-15');
      fetched = await tasks.byId(created.id);
      expect(fetched?.plannedDate, '2026-01-15');
      expect(fetched?.originalPlannedDate, '2026-01-10');
    });

    test('defer 到同一日期为 no-op，不产生 updatedAt 变更', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      final created = await tasks.create(goalId: goal.id, title: '任务', plannedDate: '2026-01-10');
      final before = await tasks.byId(created.id);

      await tasks.defer(created.id, '2026-01-10');
      final after = await tasks.byId(created.id);
      expect(after?.plannedDate, '2026-01-10');
      expect(after?.originalPlannedDate, isNull);
      expect(after?.updatedAt, before?.updatedAt);
    });

    test('deferMany 批量延期在同一事务内完成，无半写入', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      final task1 = await tasks.create(goalId: goal.id, title: '任务1', plannedDate: '2026-01-05');
      final task2 = await tasks.create(goalId: goal.id, title: '任务2', plannedDate: '2026-01-06');

      final changed = await tasks.deferMany([task1.id, task2.id], '2026-01-20');
      expect(changed, 2);
      expect((await tasks.byId(task1.id))?.plannedDate, '2026-01-20');
      expect((await tasks.byId(task1.id))?.originalPlannedDate, '2026-01-05');
      expect((await tasks.byId(task2.id))?.plannedDate, '2026-01-20');
      expect((await tasks.byId(task2.id))?.originalPlannedDate, '2026-01-06');
    });

    test('deferMany 中途失败整体回滚（NFR-2）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      final task1 = await tasks.create(goalId: goal.id, title: '任务1', plannedDate: '2026-01-05');
      final task2 = await tasks.create(goalId: goal.id, title: '任务2', plannedDate: '2026-01-06');

      await expectLater(
        db.transaction(() async {
          await tasks.deferMany([task1.id, task2.id], '2026-01-20');
          throw StateError('模拟批量延期中途失败');
        }),
        throwsA(isA<StateError>()),
      );

      expect((await tasks.byId(task1.id))?.plannedDate, '2026-01-05');
      expect((await tasks.byId(task1.id))?.originalPlannedDate, isNull);
      expect((await tasks.byId(task2.id))?.plannedDate, '2026-01-06');
    });

    test('update 改期时自动记录原计划日期（编辑改期同样满足 FR-3.3 验收）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-03-01');
      final created = await tasks.create(goalId: goal.id, title: '任务', plannedDate: '2026-01-10');

      await tasks.update(id: created.id, plannedDate: '2026-01-15');
      final fetched = await tasks.byId(created.id);
      expect(fetched?.plannedDate, '2026-01-15');
      expect(fetched?.originalPlannedDate, '2026-01-10');
    });
  });

  group('JSON 批量导入（importPlan）', () {
    const parser = TaskImportParser();
    final today = DateTime(2026, 8, 5);

    test('科目与未分类任务隔离写入，不存在的科目自动创建', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-09-01');
      // 预先存在的科目「英语」。
      await subjects.create(goalId: goal.id, name: '英语', color: '#111111');

      const json = '''
      {
        "subjects": {
          "数学": [ { "title": "真题 2013", "date": "2026-08-06", "minutes": 180 } ],
          "英语": [ { "title": "真题 2023", "date": "2026-08-07" } ]
        },
        "unclassified": [ { "title": "复盘", "date": "2026-08-06", "minutes": 30 } ]
      }''';
      final plan = parser.parse(json, today: today).plan!;

      final stats = await tasks.importPlan(goalId: goal.id, items: plan.items);
      expect(stats.createdSubjects, 1); // 仅「数学」是新建
      expect(stats.createdTasks, 3);

      final goalTasks = await tasks.byGoal(goal.id);
      expect(goalTasks, hasLength(3));
      expect(goalTasks.map((t) => t.title).toSet(), {'真题 2013', '真题 2023', '复盘'});

      final subjectList = await subjects.byGoal(goal.id);
      expect(subjectList.map((s) => s.name).toSet(), {'英语', '数学'});

      final mathTask = goalTasks.firstWhere((t) => t.title == '真题 2013');
      final englishTask = goalTasks.firstWhere((t) => t.title == '真题 2023');
      final reviewTask = goalTasks.firstWhere((t) => t.title == '复盘');
      expect(mathTask.subjectId, isNotNull);
      expect(englishTask.subjectId, isNotNull);
      expect(reviewTask.subjectId, isNull); // 未分类
      expect(mathTask.estimatedMinutes, 180);
      expect(reviewTask.estimatedMinutes, 30);
      expect(mathTask.plannedDate, '2026-08-06');
    });

    test('导入在单事务内完成：中途失败整体回滚（NFR-2）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-09-01');
      const json = '''
      {
        "subjects": {
          "数学": [ { "title": "A", "date": "2026-08-06" } ]
        },
        "unclassified": [ { "title": "B", "date": "2026-08-07" } ]
      }''';
      final plan = parser.parse(json, today: today).plan!;

      await expectLater(
        db.transaction(() async {
          await tasks.importPlan(goalId: goal.id, items: plan.items);
          throw StateError('模拟导入中途失败');
        }),
        throwsA(isA<StateError>()),
      );

      // 科目与任务均未写入。
      expect(await tasks.byGoal(goal.id), isEmpty);
      expect(await subjects.byGoal(goal.id), isEmpty);
    });

    test('replaceExisting 替换：旧任务归档保留，新任务写入（导入替换语义）', () async {
      final goal = await goals.create(title: '目标', deadlineDate: '2026-09-01');
      final oldTask = await tasks.create(
        goalId: goal.id,
        title: '旧任务',
        plannedDate: '2026-08-06',
        estimatedMinutes: 60,
      );
      await tasks.create(goalId: goal.id, title: '旧任务2', plannedDate: '2026-08-07');

      const json = '{"unclassified": [{"title":"新任务","date":"2026-08-10"}]}';
      final plan = parser.parse(json, today: today).plan!;

      final stats = await tasks.importPlan(
        goalId: goal.id,
        items: plan.items,
        replaceExisting: true,
      );
      expect(stats.createdTasks, 1);
      expect(stats.replacedTasks, 2);

      // 当前列表只剩新任务；旧任务进入归档（历史保留）。
      final active = await tasks.byGoal(goal.id);
      expect(active.map((t) => t.title).toList(), ['新任务']);
      final archived = await tasks.archivedByGoal(goal.id);
      expect(archived.map((t) => t.title).toSet(), {'旧任务', '旧任务2'});

      // 归档任务不进入常规查询（今日/日历/未完成）。
      expect(await tasks.byDate('2026-08-06'), isEmpty);
      expect(await tasks.byDateRange('2026-08-01', '2026-08-31'), hasLength(1));
      expect(await tasks.unfinishedBefore('2026-08-10'), isEmpty);

      // 恢复归档任务后重新进入当前计划。
      await tasks.restoreArchived(oldTask.id);
      final afterRestore = await tasks.byGoal(goal.id);
      expect(afterRestore.map((t) => t.title).toSet(), {'新任务', '旧任务'});
      expect(await tasks.byDate('2026-08-06'), hasLength(1));
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
