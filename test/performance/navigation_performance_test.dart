import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';

import '../shared/nav_helper.dart';

/// 页面切换性能测量（诊断用）：量化「今天 → 进度」切页首帧渲染成本。
///
/// 背景：IndexedStack 常驻各分支页，切页瞬间目标页 build + 首次布局/绘制
/// （进度页含 3 个 fl_chart 图表）集中在首帧。逐帧 pump 模拟真实帧率，
/// 打印帧数不硬断言（JIT 与 release 有差异），用于定位切页掉帧来源。
void main() {
  const taskCount = 5000;

  late AppDatabase db;
  late GoalRepository goals;

  Future<void> seedTasks(int goalId) async {
    final now = DateTime.now().toUtc();
    final start = DateTime(2026, 8, 1);
    final totalDays = 370;
    final perDay = (taskCount / totalDays).ceil();
    await db.transaction(() async {
      for (var i = 0; i < taskCount; i++) {
        final day = start.add(Duration(days: i ~/ perDay));
        final mm = day.month.toString().padLeft(2, '0');
        final dd = day.day.toString().padLeft(2, '0');
        // 前 60% 已完成（供热力图/燃尽/耗时图数据），后 40% 未完成。
        final done = i < taskCount * 0.6;
        await db.into(db.tasks).insert(TasksCompanion.insert(
              goalId: goalId,
              title: '任务 $i',
              plannedDate: '${day.year}-$mm-$dd',
              status: Value(done ? 'done' : 'todo'),
              completedAt: Value(done ? now : null),
              estimatedMinutes: const Value(60),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    DateTime? fixedNow,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow ?? DateTime(2026, 8, 5, 12)),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点击导航并逐帧推进到 [target] 可见，返回帧数。
  Future<int> navUntilVisible(
    WidgetTester tester,
    String label,
    Finder target,
  ) async {
    final rail = find.byType(NavigationRail);
    final navTarget = rail.evaluate().isNotEmpty
        ? find.descendant(of: rail, matching: find.text(label))
        : find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          );
    await tester.tap(navTarget);
    await tester.pump();
    var frames = 1;
    while (target.evaluate().isEmpty && frames < 120) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    return frames;
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    final goal = await goals.create(title: '性能目标', deadlineDate: '2027-12-31');
    await seedTasks(goal.id);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('今天 → 进度切页首帧耗时测量（数据就绪，5000 任务）', (tester) async {
    await pumpApp(tester);

    // 数据就绪：先切到进度页等全部异步收敛（pumpAndSettle 等 provider
    // 查询完成），再切回今天，模拟「数据已缓存」下的真实切页。
    await tapNavDestination(tester, '进度');
    await tester.pumpAndSettle();
    await tapNavDestination(tester, '今天');
    await tester.pumpAndSettle();

    final sw = Stopwatch()..start();
    final frames = await navUntilVisible(tester, '进度', find.text('今日概览'));
    sw.stop();
    // ignore: avoid_print
    print('切页（数据就绪）：今天 → 进度 ${sw.elapsedMilliseconds}ms / $frames 帧');
    await tester.pumpAndSettle();
  });

  testWidgets('今天 → 进度切页首帧耗时测量（数据未就绪，5000 任务）', (tester) async {
    await pumpApp(tester);

    // 不预热进度数据：切页瞬间触发 progressTasksProvider 全量查询。
    final sw = Stopwatch()..start();
    final frames = await navUntilVisible(tester, '进度', find.text('今日概览'));
    sw.stop();
    // ignore: avoid_print
    print('切页（数据未就绪）：今天 → 进度 ${sw.elapsedMilliseconds}ms / $frames 帧');
    await tester.pumpAndSettle();
  });
}
