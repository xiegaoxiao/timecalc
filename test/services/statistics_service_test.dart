import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/services/statistics_service.dart';

/// StatisticsService 单元测试（FR-7.1 / FR-7.2 / FR-7.4）。
///
/// 热力图口径（M3 决策）：按「完成日期」（completedAt 换算本地日期）统计
/// 完成任务数量。
void main() {
  const service = StatisticsService();

  Task todo(String date, {int? minutes, int id = 0}) {
    return Task(
      id: id,
      goalId: 1,
      title: '任务$id',
      plannedDate: date,
      estimatedMinutes: minutes,
      status: 'todo',
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  Task done(String date, {int? minutes, int id = 0, DateTime? completedAt}) {
    return Task(
      id: id,
      goalId: 1,
      title: '完成$id',
      plannedDate: date,
      estimatedMinutes: minutes,
      status: 'done',
      completedAt: completedAt ?? DateTime.utc(2026, 1, 1, 12),
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

  group('heatLevel（热力图强度分桶）', () {
    test('五档分桶边界', () {
      expect(StatisticsService.heatLevel(0), 0);
      expect(StatisticsService.heatLevel(1), 1);
      expect(StatisticsService.heatLevel(2), 1);
      expect(StatisticsService.heatLevel(3), 2);
      expect(StatisticsService.heatLevel(5), 2);
      expect(StatisticsService.heatLevel(6), 3);
      expect(StatisticsService.heatLevel(8), 3);
      expect(StatisticsService.heatLevel(9), 4);
      expect(StatisticsService.heatLevel(99), 4);
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
}
