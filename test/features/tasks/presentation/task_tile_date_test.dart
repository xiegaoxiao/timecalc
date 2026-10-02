import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/presentation/task_tile.dart';

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late SettingsRepository settings;
  late int goalId;
  late int subjectId;
  late int changes;
  final today = DateTime(2026, 8, 5, 12);

  setUp(() async {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    tasks = TaskRepository(db);
    settings = SettingsRepository(db);
    goalId = (await GoalRepository(
      db,
    ).create(title: '考研', deadlineDate: '2040-12-31')).id;
    subjectId = (await SubjectRepository(
      db,
    ).create(goalId: goalId, name: '数学', color: '#3F6C51')).id;
    changes = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<Task> pumpTask(WidgetTester tester, String date) async {
    final task = await tasks.create(
      goalId: goalId,
      subjectId: subjectId,
      title: '完成第一章',
      note: '保留笔记',
      plannedDate: date,
      estimatedMinutes: 90,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => today),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TaskTile(task: task, onChanged: () => changes++),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return task;
  }

  Future<void> chooseAction(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('未来任务快捷延期从原计划日期之后寻找可用日并保留字段', (tester) async {
    // 8 月 10 日是周一；偏好只允许周四，下一可用日应是 8 月 13 日。
    await settings.updateAvailableWeekdays({DateTime.thursday});
    final task = await pumpTask(tester, '2026-08-10');

    await chooseAction(tester, '延期至下一可用日');

    final updated = (await tasks.byId(task.id))!;
    expect(updated.plannedDate, '2026-08-13');
    expect(updated.originalPlannedDate, '2026-08-10');
    expect(updated.goalId, goalId);
    expect(updated.subjectId, subjectId);
    expect(updated.title, task.title);
    expect(updated.note, task.note);
    expect(updated.estimatedMinutes, task.estimatedMinutes);
    expect(updated.status, task.status);
    expect(changes, 1);
  });

  for (final plannedDate in ['2026-08-05', '2026-08-04']) {
    testWidgets('今日及积压任务 $plannedDate 从今天之后快捷延期', (tester) async {
      final task = await pumpTask(tester, plannedDate);

      await chooseAction(tester, '延期至下一可用日');

      final updated = (await tasks.byId(task.id))!;
      expect(updated.plannedDate, '2026-08-06');
      expect(updated.originalPlannedDate, plannedDate);
      expect(changes, 1);
    });
  }

  for (final plannedDate in ['2024-03-10', '2040-03-10']) {
    testWidgets('历史及远期任务 $plannedDate 可打开延期日期选择器并保存', (tester) async {
      final task = await pumpTask(tester, plannedDate);

      await chooseAction(tester, '延期…');

      expect(tester.takeException(), isNull);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      final picker = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(picker.initialDate, DateTime.parse(plannedDate));
      expect(picker.currentDate, DateTime(2026, 8, 5));
      // 初始月份中选择另一个日期，验证完整 UI 到数据库的延期流程。
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final updated = (await tasks.byId(task.id))!;
      expect(updated.plannedDate, '${plannedDate.substring(0, 8)}15');
      expect(updated.originalPlannedDate, plannedDate);
      expect(changes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
