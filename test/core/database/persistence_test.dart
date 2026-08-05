import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 重启持久化测试（checklists §11 M1：应用重启后数据持久化一致）。
///
/// 使用临时文件库模拟「应用退出 → 重新打开」：
/// 关闭数据库连接后重新打开同一文件，目标与任务数据保持一致。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('timecalc_persistence_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Windows 下文件句柄释放存在时序，忽略清理失败。
    }
  });

  test('关闭后重新打开数据库，目标与任务数据保持一致', () async {
    final dbPath = tempDir.path;

    // 第一次「运行」：写入数据后关闭。
    var db = AppDatabase(NativeDatabase(File('$dbPath/timecalc_test.db')));
    var goals = GoalRepository(db);
    var tasks = TaskRepository(db);
    final goal = await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
    await tasks.create(goalId: goal.id, title: '完成第一章', plannedDate: '2026-01-10', estimatedMinutes: 120);
    await db.close();

    // 模拟「重启」：重新打开同一文件。
    db = AppDatabase(NativeDatabase(File('$dbPath/timecalc_test.db')));
    goals = GoalRepository(db);
    tasks = TaskRepository(db);

    final goalsAfterRestart = await goals.watchAll();
    expect(goalsAfterRestart, hasLength(1));
    expect(goalsAfterRestart.single.title, '考研数学');
    expect(goalsAfterRestart.single.deadlineDate, '2026-12-20');

    final tasksAfterRestart = await tasks.byGoal(goal.id);
    expect(tasksAfterRestart, hasLength(1));
    expect(tasksAfterRestart.single.title, '完成第一章');
    expect(tasksAfterRestart.single.estimatedMinutes, 120);
    expect(tasksAfterRestart.single.status, 'todo');

    await db.close();
  });
}
