import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/services/load_service.dart';

/// 性能基线测试（NFR-1，checklists §9）。
///
/// 10,000 条任务数据下验证月历切换性能：查询（byDateRange）+ 聚合
/// （calendarAggregate）总耗时 ≤ 500ms（NFR-1）。同时记录今日页 byDate
/// 查询耗时（打印，不硬断言，避免 CI 环境波动导致 flaky）。
///
/// 说明：内存数据库（NativeDatabase.memory()）在 SQLite 执行速度上通常
/// 不慢于文件库，作为回归基线足够；生产文件库的绝对耗时由 Windows
/// 冒烟验证补充。
void main() {
  const taskCount = 10000;

  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late int goalId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    goalId = (await goals.create(title: '性能目标', deadlineDate: '2027-12-31')).id;

    // 造 10,000 条任务，均匀分布在最近 12 个月（每天 ~27 条）。
    // 直接用自定义列批量插入（不经过 batchCreate，日期逐条指定）。
    final now = DateTime.now().toUtc();
    final start = DateTime(2026, 8, 1);
    final totalDays = 370;
    final perDay = (taskCount / totalDays).ceil();

    await db.transaction(() async {
      for (var i = 0; i < taskCount; i++) {
        final day = start.add(Duration(days: i ~/ perDay));
        await db.into(db.tasks).insert(TasksCompanion.insert(
              goalId: goalId,
              title: '任务 $i',
              plannedDate: _formatDate(day),
              estimatedMinutes: const Value(60),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
  });

  tearDown(() async {
    await db.close();
  });

  test('10,000 条任务：月历切换（查询+聚合）≤ 500ms（NFR-1）', () async {
    final settings = SettingsRepository(db);
    final plan = await settings.get();
    final weekdays = SettingsRepository.decodeWeekdays(plan.availableWeekdays);
    const load = LoadService();

    // 选取中间月份（数据最密的月份）。
    final month = '2026-11';
    final parts = month.split('-');
    final firstDay = DateTime(int.parse(parts[0]), int.parse(parts[1]), 1);
    final lastDay = DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);

    // 预热一次（首查建索引/缓存）。
    await tasks.byDateRange(
      _formatDate(firstDay),
      _formatDate(lastDay),
    );

    final stopwatch = Stopwatch()..start();
    final monthTasks = await tasks.byDateRange(
      _formatDate(firstDay),
      _formatDate(lastDay),
    );
    load.calendarAggregate(
      tasks: monthTasks,
      availableMinutes: plan.dailyAvailableMinutes,
      availableWeekdays: weekdays,
    );
    stopwatch.stop();

    // ignore: avoid_print
    print(
      '性能基线：10,000 条任务中 2026-11 月视图查询+聚合耗时 '
      '${stopwatch.elapsedMilliseconds}ms（${monthTasks.length} 条/月）',
    );
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(500),
      reason: 'NFR-1：10,000 条任务数据下月历切换 ≤ 500ms',
    );
  });

  test('10,000 条任务：今日任务查询（byDate）记录耗时', () async {
    // 数据集中在 2026-08~2027-07；今日用 2026-11-05（数据密集日）。
    final stopwatch = Stopwatch()..start();
    final dayTasks = await tasks.byDate('2026-11-05');
    stopwatch.stop();

    // ignore: avoid_print
    print(
      '性能基线：10,000 条任务中单日任务查询耗时 '
      '${stopwatch.elapsedMilliseconds}ms（${dayTasks.length} 条/日）',
    );
    // 今日页操作反馈基线 ≤ 200ms（NFR-1）；查询单日不涉及聚合，通常 <10ms。
    expect(stopwatch.elapsedMilliseconds, lessThan(200));
  });
}

String _formatDate(DateTime date) {
  final mm = date.month.toString().padLeft(2, '0');
  final dd = date.day.toString().padLeft(2, '0');
  return '${date.year}-$mm-$dd';
}
