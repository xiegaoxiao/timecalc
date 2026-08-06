import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/services/statistics_service.dart';

/// StatisticsService 单元测试（FR-7.1 / FR-7.2 / FR-7.4）。
///
/// 热力图口径（M3 决策）：按「完成日期」（completedAt 换算本地日期）统计
/// 完成任务数量。
void main() {
  const service = StatisticsService();

  Task todo(String date, {int? minutes, int id = 0, int goalId = 1}) {
    return Task(
      id: id,
      goalId: goalId,
      title: '任务$id',
      plannedDate: date,
      estimatedMinutes: minutes,
      status: 'todo',
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  Task done(String date, {int? minutes, int id = 0, int goalId = 1, DateTime? completedAt}) {
    return Task(
      id: id,
      goalId: goalId,
      title: '完成$id',
      plannedDate: date,
      estimatedMinutes: minutes,
      status: 'done',
      completedAt: completedAt ?? DateTime(2026, 1, 1, 12),
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  group('completedCountsByLocalDate（FR-7.2 按完成日期）', () {
    test('只统计已完成任务，按 completedAt 本地日期归组', () {
      // completedAt 使用本地 DateTime，避免 UTC→本地换算跨日不确定性。
      final counts = service.completedCountsByLocalDate([
        done('2026-01-02', completedAt: DateTime(2026, 1, 2, 8)),
        done('2026-01-02', completedAt: DateTime(2026, 1, 2, 20)),
        done('2026-01-03', completedAt: DateTime(2026, 1, 3, 8)),
        todo('2026-01-02', minutes: 30),
      ]);
      expect(counts['2026-01-02'], 2);
      expect(counts['2026-01-03'], 1);
      expect(counts['2026-01-01'], isNull);
      // 无完成记录日期不出现。
      expect(counts.length, 2);
    });

    test('completedAt 为 null 的任务不计入', () {
      // 已完成但未记录完成时间（异常数据）不计入热力图。
      final counts = service.completedCountsByLocalDate([
        Task(
          id: 9,
          goalId: 1,
          title: '无完成时间',
          plannedDate: '2026-01-02',
          status: 'done',
          completedAt: null,
          sortOrder: 0,
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ]);
      expect(counts, isEmpty);
    });

    test('已完成但无预估时长的任务计入任务数', () {
      final counts = service.completedCountsByLocalDate([
        done('2026-01-02', minutes: 60, completedAt: DateTime(2026, 1, 2)),
        done('2026-01-02', completedAt: DateTime(2026, 1, 2)),
      ]);
      expect(counts['2026-01-02'], 2);
    });
  });

  group('completionStats（FR-7.1）', () {
    test('统计完成数 / 总数 / 已完成预估时长', () {
      final stats = service.completionStats([
        done('2026-01-01', minutes: 60),
        done('2026-01-01'),
        todo('2026-01-01', minutes: 30),
        todo('2026-01-01'),
      ]);
      expect(stats.totalCount, 4);
      expect(stats.doneCount, 2);
      // 无预估时长的已完成任务不计入时长（FR-7.4）。
      expect(stats.doneMinutes, 60);
    });

    test('空列表返回空统计', () {
      final stats = service.completionStats([]);
      expect(stats.totalCount, 0);
      expect(stats.doneCount, 0);
      expect(stats.doneMinutes, 0);
    });
  });

  group('remainingMinutes（FR-7.1 / FR-5.3）', () {
    test('只累计未完成任务预估时长', () {
      final minutes = service.remainingMinutes([
        todo('2026-01-01', minutes: 60),
        todo('2026-01-01'),
        done('2026-01-01', minutes: 30),
      ]);
      expect(minutes, 60);
    });
  });

  group('heatLevel（热力图强度分桶，LeetCode 五档）', () {
    test('五档分桶边界', () {
      expect(StatisticsService.heatLevel(0), 0);
      expect(StatisticsService.heatLevel(1), 1);
      expect(StatisticsService.heatLevel(3), 1);
      expect(StatisticsService.heatLevel(4), 2);
      expect(StatisticsService.heatLevel(6), 2);
      expect(StatisticsService.heatLevel(7), 3);
      expect(StatisticsService.heatLevel(9), 3);
      expect(StatisticsService.heatLevel(10), 4);
      expect(StatisticsService.heatLevel(99), 4);
    });
  });

  group('minutesLevel（甘特图时长分桶）', () {
    test('五档分桶边界（分钟）', () {
      expect(StatisticsService.minutesLevel(0), 0);
      expect(StatisticsService.minutesLevel(1), 1);
      expect(StatisticsService.minutesLevel(59), 1);
      expect(StatisticsService.minutesLevel(60), 2);
      expect(StatisticsService.minutesLevel(119), 2);
      expect(StatisticsService.minutesLevel(120), 3);
      expect(StatisticsService.minutesLevel(299), 3);
      expect(StatisticsService.minutesLevel(300), 4);
      expect(StatisticsService.minutesLevel(999), 4);
    });
  });

  group('goalGanttData（甘特图周聚合：计划 + 完成）', () {
    test('按目标分组：未完成按计划日期归周，已完成按完成日期归周', () {
      final weekStarts = StatisticsService.ganttWeekStarts(
        DateTime(2026, 8, 5), // 周三
        pastWeeks: 1,
        futureWeeks: 1,
      );
      // 窗口共 3 周：[上周一, 本周一(08-03), 下周一(08-10)]。
      final lastStart = weekStarts[1]; // 2026-08-03
      final prevStart = lastStart.subtract(const Duration(days: 7));

      final data = service.goalGanttData(
        todoTasks: [
          todo('2026-08-12', minutes: 120, id: 1, goalId: 1), // 下周计划
        ],
        completedTasks: [
          done(
            '2026-07-29',
            minutes: 90,
            id: 2,
            goalId: 1,
            completedAt: prevStart.add(const Duration(hours: 10)),
          ),
          done(
            '2026-08-04',
            minutes: 60,
            id: 3,
            goalId: 2,
            completedAt: lastStart.add(const Duration(hours: 10)),
          ),
        ],
        weekStarts: weekStarts,
      );

      // 目标 1：上周完成 90 + 下周计划 120。
      expect(data[1]!.planned[2], 120);
      expect(data[1]!.completed[0], 90);
      // 目标 2：本周完成 60。
      expect(data[2]!.completed[1], 60);
    });

    test('无预估时长 / completedAt 为空的任务不计入', () {
      final weekStarts = StatisticsService.ganttWeekStarts(DateTime(2026, 8, 5));
      final data = service.goalGanttData(
        todoTasks: [
          todo('2026-08-06', id: 1), // 无预估时长
        ],
        completedTasks: [
          Task(
            id: 2,
            goalId: 1,
            title: '无完成时间',
            plannedDate: '2026-08-04',
            status: 'done',
            completedAt: null,
            estimatedMinutes: 60,
            sortOrder: 0,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        weekStarts: weekStarts,
      );
      expect(data, isEmpty);
    });

    test('ganttWeekStarts：过去 12 + 当前 + 未来 13 周，当前周居中', () {
      final starts = StatisticsService.ganttWeekStarts(DateTime(2026, 8, 5));
      expect(starts, hasLength(26));
      // 2026-08-05 是周三 → 本周一为 2026-08-03。
      expect(starts[12], DateTime(2026, 8, 3)); // 当前周
      expect(starts[0], DateTime(2026, 5, 11)); // 12 周前
      expect(starts[25], DateTime(2026, 11, 2)); // 13 周后
      // 逐周递增 7 天。
      expect(starts[1].difference(starts[0]), const Duration(days: 7));
    });
  });

  group('recentWeekStarts（周起始计算）', () {
    test('最后一项是包含今天的周一（周一开头）', () {
      final starts = StatisticsService.recentWeekStarts(DateTime(2026, 8, 5, 10));
      expect(starts, hasLength(26));
      // 2026-08-05 是周三 → 本周一为 2026-08-03。
      expect(starts.last, DateTime(2026, 8, 3));
      // 逐周递增 7 天。
      expect(starts[1].difference(starts[0]), const Duration(days: 7));
    });

    test('周一当天作为周起始', () {
      final starts = StatisticsService.recentWeekStarts(DateTime(2026, 8, 3));
      expect(starts.last, DateTime(2026, 8, 3));
    });

    test('周日归属本周（7 天后同一周）', () {
      final starts = StatisticsService.recentWeekStarts(DateTime(2026, 8, 9));
      expect(starts.last, DateTime(2026, 8, 3));
    });
  });

  group('burndownSeries（FR-7.3 燃尽趋势）', () {
    // 固定时钟：2026-08-05 → 窗口 [2026-07-07 .. 2026-08-05] 共 30 天。
    final today = DateTime(2026, 8, 5, 12);

    test('窗口边界：30 个点，起点 today-29，末点 today', () {
      final points = StatisticsService.burndownSeries(
        todoTasks: const [],
        completedTasks: const [],
        today: today,
        endDate: DateTime(2026, 8, 5),
      );
      expect(points, hasLength(30));
      expect(points.first.date, DateTime(2026, 7, 7));
      expect(points.last.date, DateTime(2026, 8, 5));
      // 逐日递增。
      expect(points[1].date.difference(points[0].date), const Duration(days: 1));
    });

    test('无完成、有当前未完成：剩余水平 = 当前未完成时长和（today 点）', () {
      final points = StatisticsService.burndownSeries(
        todoTasks: [
          todo('2026-08-10', minutes: 120),
          todo('2026-08-12', minutes: 60),
        ],
        completedTasks: const [],
        today: today,
        endDate: DateTime(2026, 8, 5),
      );
      // 无窗口内完成：全程剩余 = 180（today 点 = 当前剩余）。
      for (final point in points) {
        expect(point.remaining, 180);
      }
    });

    test('窗口内完成的任务：越早的日期剩余越多，today 点=当前剩余', () {
      final points = StatisticsService.burndownSeries(
        todoTasks: [todo('2026-08-10', minutes: 120)],
        completedTasks: [
          // 窗口内（8-01）完成 60 分钟任务。
          done('2026-08-01', minutes: 60, completedAt: DateTime(2026, 8, 1, 9)),
        ],
        today: today,
        endDate: DateTime(2026, 8, 5),
      );
      // 窗口起点（07-07）：尚未完成 → 180。
      expect(points.first.remaining, 180);
      // 8-01 当天起：该 60 分钟已消化 → 120。
      final aug1 = points.firstWhere((p) => p.date == DateTime(2026, 8, 1));
      expect(aug1.remaining, 120);
      // today 点 = 当前剩余 120。
      expect(points.last.remaining, 120);
    });

    test('理想参考线：从起点实际剩余按 endDate 线性递减到 0', () {
      final points = StatisticsService.burndownSeries(
        todoTasks: [todo('2026-08-10', minutes: 180)],
        completedTasks: const [],
        today: today,
        // 截止日 2026-07-20：起点 07-07 起 13 天线性递减到 0。
        endDate: DateTime(2026, 7, 20),
      );
      expect(points.first.remaining, 180);
      // 参考线起点 = 180，截止日当天归 0，此后保持 0。
      expect(points.first.ideal, 180);
      final deadline = points.firstWhere((p) => p.date == DateTime(2026, 7, 20));
      expect(deadline.ideal, 0);
      expect(points.last.ideal, 0);
      // 单调不增。
      for (var i = 1; i < points.length; i++) {
        expect(points[i].ideal, lessThanOrEqualTo(points[i - 1].ideal));
      }
    });

    test('endDate 不晚于窗口起点：理想参考线全 0', () {
      final points = StatisticsService.burndownSeries(
        todoTasks: [todo('2026-08-10', minutes: 90)],
        completedTasks: const [],
        today: today,
        endDate: DateTime(2026, 7, 1), // 早于窗口起点 07-07
      );
      expect(points.first.ideal, 0);
      expect(points.last.ideal, 0);
    });

    test('无预估时长的任务不计入（FR-7.4）', () {
      final points = StatisticsService.burndownSeries(
        todoTasks: [
          todo('2026-08-10', minutes: 120),
          todo('2026-08-12'), // 无时长，不计入
        ],
        completedTasks: [
          done('2026-08-02'), // 无时长，不计入
        ],
        today: today,
        endDate: DateTime(2026, 8, 5),
      );
      for (final point in points) {
        expect(point.remaining, 120);
      }
    });
  });
}
