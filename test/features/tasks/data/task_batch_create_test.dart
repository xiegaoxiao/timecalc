import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// TaskRepository.batchCreate 批量创建测试（NFR-2 事务原子性）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
  late TaskRepository tasks;
  late int goalId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    subjects = SubjectRepository(db);
    tasks = TaskRepository(db);
    goalId = (await goals.create(title: '考研', deadlineDate: '2026-12-19')).id;
  });

  tearDown(() async {
    await db.close();
  });

  group('批量创建（FR-3.2 批量录入）', () {
    test('全部同一天：多行标题一次创建，日期一致', () async {
      final count = await tasks.batchCreate(
        goalId: goalId,
        titles: ['严选题 第1章', '严选题 第2章', '严选题 第3章'],
        startDate: '2026-07-01',
        dateIntervalDays: 0,
      );
      expect(count, 3);

      final all = await tasks.byGoal(goalId);
      expect(all, hasLength(3));
      expect(all.every((t) => t.plannedDate == '2026-07-01'), isTrue);
    });

    test('每 N 天一个：日期按间隔递增', () async {
      await tasks.batchCreate(
        goalId: goalId,
        titles: ['真题 2013', '真题 2014', '真题 2015'],
        startDate: '2026-11-01',
        dateIntervalDays: 1,
      );

      final all = await tasks.byGoal(goalId);
      expect(all.map((t) => t.plannedDate).toList(),
          ['2026-11-01', '2026-11-02', '2026-11-03']);
    });

    test('每周一个：间隔 7 天', () async {
      await tasks.batchCreate(
        goalId: goalId,
        titles: ['模拟卷 1', '模拟卷 2'],
        startDate: '2026-11-20',
        dateIntervalDays: 7,
      );

      final all = await tasks.byGoal(goalId);
      expect(all.map((t) => t.plannedDate).toList(),
          ['2026-11-20', '2026-11-27']);
    });

    test('统一预估时长与科目归属', () async {
      final subject = await subjects.create(goalId: goalId, name: '数学', color: '#3F6C51');
      await tasks.batchCreate(
        goalId: goalId,
        subjectId: subject.id,
        titles: ['真题 2013', '真题 2014'],
        startDate: '2026-11-01',
        estimatedMinutes: 180,
      );

      final all = await tasks.byGoal(goalId);
      expect(all.every((t) => t.estimatedMinutes == 180), isTrue);
      expect(all.every((t) => t.subjectId == subject.id), isTrue);
    });

    test('空行与空白标题自动跳过', () async {
      final count = await tasks.batchCreate(
        goalId: goalId,
        titles: ['任务A', '', '   ', '任务B'],
        startDate: '2026-11-01',
      );
      expect(count, 2);
      expect(await tasks.byGoal(goalId), hasLength(2));
    });

    test('全部为空标题时不创建任何任务', () async {
      final count = await tasks.batchCreate(
        goalId: goalId,
        titles: ['  ', ''],
        startDate: '2026-11-01',
      );
      expect(count, 0);
      expect(await tasks.byGoal(goalId), isEmpty);
    });

    test('非法间隔天数抛出参数错误', () async {
      expect(
        () => tasks.batchCreate(
          goalId: goalId,
          titles: ['任务'],
          startDate: '2026-11-01',
          dateIntervalDays: -1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('批量创建事务原子性（NFR-2）', () {
    test('事务中途失败回滚，不留下半批任务', () async {
      await expectLater(
        db.transaction(() async {
          await tasks.batchCreate(
            goalId: goalId,
            titles: ['任务1', '任务2'],
            startDate: '2026-11-01',
          );
          throw StateError('模拟批量事务中途失败');
        }),
        throwsA(isA<StateError>()),
      );

      // 目标下没有任何任务残留。
      expect(await tasks.byGoal(goalId), isEmpty);
    });
  });
}
