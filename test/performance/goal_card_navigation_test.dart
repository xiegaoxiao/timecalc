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

/// 目标页点击卡片 → 详情页渲染 性能测量（诊断用）。
///
/// 对比不同任务量下「tap 卡片 → pumpAndSettle」耗时，用于定位点击卡顿
/// 是来自详情页数据加载/构建（随任务量增长）还是页面过渡/合成（与任务
/// 量无关）。打印结果，不硬断言（测试环境 JIT 与 release 有差异）。
void main() {
  testWidgets('点击目标卡片跳转详情页耗时测量（任务量对比）', (tester) async {
    for (final taskCount in [10, 1000]) {
      final db = AppDatabase(NativeDatabase.memory());
      final goals = GoalRepository(db);
      final fixedNow = DateTime(2026, 8, 5, 12);

      final goal = await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
      final now = DateTime.now().toUtc();
      await db.transaction(() async {
        for (var i = 0; i < taskCount; i++) {
          final day = DateTime(2026, 8, 5).add(Duration(days: i % 60));
          final mm = day.month.toString().padLeft(2, '0');
          final dd = day.day.toString().padLeft(2, '0');
          await db.into(db.tasks).insert(TasksCompanion.insert(
                goalId: goal.id,
                title: '任务 $i',
                plannedDate: '${day.year}-$mm-$dd',
                estimatedMinutes: const Value(60),
                createdAt: now,
                updatedAt: now,
              ));
        }
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            clockProvider.overrideWithValue(() => fixedNow),
          ],
          child: const TimeCalcApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tapNavDestination(tester, '目标');

      // 点击卡片：逐帧推进到「详情页真实内容（目标详情 AppBar 文案）已
      // 可见」，记录帧数与墙钟耗时——测量用户可感知的首帧呈现，而非
      // 仅测量 pumpAndSettle 收敛。
      final sw = Stopwatch()..start();
      await tester.tap(find.text('考研数学'));
      await tester.pump();
      var frames = 1;
      while (find.text('目标详情').evaluate().isEmpty && frames < 60) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
      }
      sw.stop();

      final headerVisible = find.text('目标详情').evaluate().length;
      // ignore: avoid_print
      print('目标页点击卡片 → 详情页首帧内容可见：$taskCount 条任务 '
          '${sw.elapsedMilliseconds}ms / $frames 帧（目标详情=$headerVisible）');

      // 软护栏（NFR-1 精神）：首帧内容应在合理时间内出现；上限宽松，
      // 避免 CI 环境波动导致 flaky，但能拦住「详情页新增逐任务 N+1 查询
      // 或阻塞式构建」这类数量级回归（基线实测 1000 条任务 <200ms；
      // 2026-08-16 曾因任务区单卡全量构建回落到 4s+，帧数护栏拦不住
      // 「单帧超长」，故补墙钟护栏）。
      expect(
        frames,
        lessThan(30),
        reason: '点击目标卡片后详情页应在约半秒内呈现首帧内容（当前 $frames 帧）',
      );
      expect(
        sw.elapsedMilliseconds,
        lessThan(1500),
        reason: '详情页首帧内容墙钟耗时应远低于 1.5s（当前 '
            '${sw.elapsedMilliseconds}ms；2026-08-16 单卡全量构建回归时 4s+）',
      );

      await db.close();
      // 重置 widget 树，避免多个 db 实例交叉。
      await tester.pumpWidget(const SizedBox());
    }
  });
}
