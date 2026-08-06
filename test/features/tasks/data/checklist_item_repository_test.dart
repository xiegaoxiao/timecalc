import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/checklist_item_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/domain/task_import_parser.dart';

/// ChecklistItemRepository 内存数据库测试（FR-4.1，schema v8）。
///
/// 覆盖：CRUD、任务内上移/下移排序、未完成计数、任务删除/目标删除/导入
/// 替换的级联删除（防孤儿数据，NFR-2）。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late ChecklistItemRepository checklist;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    checklist = ChecklistItemRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTask({String title = '背单词'}) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final task = await tasks.create(
      goalId: goal.id,
      title: title,
      plannedDate: '2026-08-05',
    );
    return task.id;
  }

  group('CRUD', () {
    test('创建按 sortOrder 追加排序，id 为稳定次序', () async {
      final taskId = await seedTask();
      final a = await checklist.create(taskId: taskId, title: '第一步');
      final b = await checklist.create(taskId: taskId, title: '第二步');

      expect(a.sortOrder, 0);
      expect(b.sortOrder, 1);

      final items = await checklist.byTask(taskId);
      expect(items.map((c) => c.title), ['第一步', '第二步']);
    });

    test('重命名标题', () async {
      final taskId = await seedTask();
      final item = await checklist.create(taskId: taskId, title: '旧标题');
      await checklist.rename(item.id, '新标题');
      expect((await checklist.byTask(taskId)).single.title, '新标题');
    });

    test('完成状态切换与未完成计数', () async {
      final taskId = await seedTask();
      final a = await checklist.create(taskId: taskId, title: 'A');
      await checklist.create(taskId: taskId, title: 'B');
      expect(await checklist.unfinishedCount(taskId), 2);

      await checklist.setDone(a.id, true);
      expect(await checklist.unfinishedCount(taskId), 1);
      expect((await checklist.byTask(taskId)).firstWhere((c) => c.id == a.id).done, isTrue);

      await checklist.setDone(a.id, false);
      expect(await checklist.unfinishedCount(taskId), 2);
      // 空任务未完成计数为 0。
      expect(await checklist.unfinishedCount(999), 0);
    });

    test('删除检查项', () async {
      final taskId = await seedTask();
      final item = await checklist.create(taskId: taskId, title: '待删');
      await checklist.delete(item.id);
      expect(await checklist.byTask(taskId), isEmpty);
    });
  });

  group('排序（上移/下移）', () {
    test('下移后与新邻居交换 sortOrder', () async {
      final taskId = await seedTask();
      final a = await checklist.create(taskId: taskId, title: 'A');
      await checklist.create(taskId: taskId, title: 'B');
      await checklist.create(taskId: taskId, title: 'C');

      await checklist.move(taskId, a.id, 1);
      final items = await checklist.byTask(taskId);
      expect(items.map((c) => c.title), ['B', 'A', 'C']);
    });

    test('上移后与新邻居交换 sortOrder', () async {
      final taskId = await seedTask();
      await checklist.create(taskId: taskId, title: 'A');
      await checklist.create(taskId: taskId, title: 'B');
      final c = await checklist.create(taskId: taskId, title: 'C');

      await checklist.move(taskId, c.id, -1);
      final items = await checklist.byTask(taskId);
      expect(items.map((c) => c.title), ['A', 'C', 'B']);
    });

    test('越界移动不改变顺序（首项上移 / 末项下移）', () async {
      final taskId = await seedTask();
      final a = await checklist.create(taskId: taskId, title: 'A');
      final b = await checklist.create(taskId: taskId, title: 'B');

      await checklist.move(taskId, a.id, -1);
      await checklist.move(taskId, b.id, 1);
      expect((await checklist.byTask(taskId)).map((c) => c.title), ['A', 'B']);
    });

    test('仅影响同一任务内的排序（不同任务互不干扰）', () async {
      final task1 = await seedTask(title: '任务一');
      final task2 = await seedTask(title: '任务二');
      final a = await checklist.create(taskId: task1, title: 'A1');
      await checklist.create(taskId: task1, title: 'A2');
      await checklist.create(taskId: task2, title: 'B1');

      await checklist.move(task1, a.id, 1);
      final task2Items = await checklist.byTask(task2);
      expect(task2Items.map((c) => c.title), ['B1']);
    });
  });

  group('级联删除（防孤儿数据，NFR-2）', () {
    test('删除任务时其检查项一并删除', () async {
      final taskId = await seedTask();
      await checklist.create(taskId: taskId, title: 'A');
      await checklist.create(taskId: taskId, title: 'B');

      await tasks.delete(taskId);
      expect(await checklist.byTask(taskId), isEmpty);
    });

    test('删除目标时其全部任务的检查项一并删除', () async {
      final taskId = await seedTask();
      await checklist.create(taskId: taskId, title: 'A');
      await checklist.create(taskId: taskId, title: 'B');

      await goals.deleteWithCascade(1);
      expect(await checklist.byTask(taskId), isEmpty);
    });

    test('JSON 替换导入删除未完成任务时，其检查项一并删除', () async {
      final taskId = await seedTask();
      await checklist.create(taskId: taskId, title: 'A');
      await checklist.create(taskId: taskId, title: 'B');

      await tasks.importPlan(
        goalId: 1,
        items: [
          ImportedTaskItem(title: '新任务', date: '2026-08-06'),
        ],
        replaceExisting: true,
      );
      expect(await checklist.byTask(taskId), isEmpty);
    });

    test('替换导入后新任务可正常添加检查项', () async {
      final taskId = await seedTask();
      await checklist.create(taskId: taskId, title: '旧检查项');
      final stats = await tasks.importPlan(
        goalId: 1,
        items: [
          ImportedTaskItem(title: '新任务', date: '2026-08-06'),
        ],
        replaceExisting: true,
      );
      expect(stats.deletedTasks, 1);

      final newTask = (await tasks.byGoal(1)).single;
      await checklist.create(taskId: newTask.id, title: '新检查项');
      expect((await checklist.byTask(newTask.id)).single.title, '新检查项');
    });
  });
}
