import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/services/load_service.dart';

/// LoadService 单元测试（FR-3.5 / FR-5.2 / FR-5.3 / FR-5.4）。
void main() {
  const service = LoadService();

  Task todo(String date, {int? minutes, int id = 0}) {
    return Task(
      id: id,
      goalId: 1,
      subjectId: null,
      title: '任务$id',
      note: null,
      plannedDate: date,
      estimatedMinutes: minutes,
      status: 'todo',
      completedAt: null,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      originalPlannedDate: null,
    );
  }

  Task done(String date, {int? minutes, int id = 0}) {
    return Task(
      id: id,
      goalId: 1,
      subjectId: null,
      title: '完成$id',
      note: null,
      plannedDate: date,
      estimatedMinutes: minutes,
      status: 'done',
      completedAt: DateTime.utc(2026, 1, 1),
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      originalPlannedDate: null,
    );
  }

  group('dayLoad（FR-5.2：当日未完成任务预估时长之和）', () {
    test('只累计未完成任务时长', () {
      final tasks = [
        todo('2026-01-01', minutes: 60),
        done('2026-01-01', minutes: 30),
      ];
      expect(service.dayLoad(tasks), 60);
    });

    test('无预估时长的任务不计入时长（FR-7.4）', () {
      final tasks = [
        todo('2026-01-01', minutes: null),
        todo('2026-01-01', minutes: 45),
      ];
      expect(service.dayLoad(tasks), 45);
    });

    test('空列表负载为 0', () {
      expect(service.dayLoad([]), 0);
    });
  });

  group('overMinutes（FR-3.5）', () {
    test('超过可用时长时返回超出分钟数', () {
      expect(service.overMinutes(load: 150, available: 120), 30);
    });

    test('未超过时返回 0', () {
      expect(service.overMinutes(load: 120, available: 120), 0);
      expect(service.overMinutes(load: 60, available: 120), 0);
    });
  });

  group('remainingMinutes（FR-5.3）', () {
    test('返回目标全部未完成任务时长之和', () {
      final tasks = [
        todo('2026-01-01', minutes: 60),
        todo('2026-01-02', minutes: 90),
        done('2026-01-01', minutes: 300),
      ];
      expect(service.remainingMinutes(tasks), 150);
    });
  });

  group('remainingAvailableDays（FR-5.3）', () {
    test('截止日当天且当天可用为 1 天', () {
      expect(
        service.remainingAvailableDays(
          deadlineDate: '2026-08-05',
          today: DateTime(2026, 8, 5), // 周三
          availableWeekdays: {3},
        ),
        1,
      );
    });

    test('按可用星期数计数', () {
      // 8/5(三)~8/11(二) 共 7 天，仅工作日可用 -> 8/5,6,7,10,11 共 5 天。
      expect(
        service.remainingAvailableDays(
          deadlineDate: '2026-08-11',
          today: DateTime(2026, 8, 5),
          availableWeekdays: {1, 2, 3, 4, 5},
        ),
        5,
      );
    });

    test('截止日已过返回 0', () {
      expect(
        service.remainingAvailableDays(
          deadlineDate: '2026-08-01',
          today: DateTime(2026, 8, 5),
          availableWeekdays: {1, 2, 3, 4, 5, 6, 7},
        ),
        0,
      );
    });

    test('空集合回退为全部可用', () {
      expect(
        service.remainingAvailableDays(
          deadlineDate: '2026-08-06',
          today: DateTime(2026, 8, 5),
          availableWeekdays: {},
        ),
        2,
      );
    });
  });

  group('suggestedDailyMinutes（FR-5.3）', () {
    test('剩余时长除以剩余可用天数向上取整', () {
      expect(service.suggestedDailyMinutes(remainingMinutes: 151, remainingDays: 2), 76);
      expect(service.suggestedDailyMinutes(remainingMinutes: 120, remainingDays: 1), 120);
    });

    test('剩余可用天数为 0 时返回 0', () {
      expect(service.suggestedDailyMinutes(remainingMinutes: 300, remainingDays: 0), 0);
    });
  });

  group('hasPlanRisk（FR-5.4）', () {
    test('建议日均超过每日可用时长视为计划风险', () {
      expect(service.hasPlanRisk(suggestedDailyMinutes: 180, dailyAvailableMinutes: 120), isTrue);
    });

    test('不超或等于不算风险', () {
      expect(service.hasPlanRisk(suggestedDailyMinutes: 120, dailyAvailableMinutes: 120), isFalse);
      expect(service.hasPlanRisk(suggestedDailyMinutes: 60, dailyAvailableMinutes: 120), isFalse);
    });
  });

  group('calendarAggregate（FR-3.4）', () {
    test('无任务日期为中性（不视为过载或完成率 0%）', () {
      final agg = service.calendarAggregate(
        tasks: [],
        availableMinutes: 120,
        availableWeekdays: {1, 2, 3, 4, 5, 6, 7},
      );
      expect(agg, isEmpty);
    });

    test('按日期聚合任务数、完成数、负载与超出分钟数', () {
      final tasks = [
        todo('2026-08-05', minutes: 60, id: 1),
        todo('2026-08-05', minutes: 90, id: 2),
        done('2026-08-05', minutes: 30, id: 3),
        todo('2026-08-06', minutes: 30, id: 4),
      ];
      final agg = service.calendarAggregate(
        tasks: tasks,
        availableMinutes: 120,
        availableWeekdays: {1, 2, 3, 4, 5, 6, 7},
      );

      final day5 = agg['2026-08-05']!;
      expect(day5.totalCount, 3);
      expect(day5.doneCount, 1);
      expect(day5.loadMinutes, 150); // 未完成任务时长
      expect(day5.overMinutes, 30);

      final day6 = agg['2026-08-06']!;
      expect(day6.totalCount, 1);
      expect(day6.loadMinutes, 30);
      expect(day6.overMinutes, 0);
    });

    test('不可用星期置灰：不产生「超出」徽标（超出概念仅对可用日成立）', () {
      // 2026-08-08 为周六；仅工作日可用时周六不标超出。
      final tasks = [todo('2026-08-08', minutes: 500, id: 1)];
      final agg = service.calendarAggregate(
        tasks: tasks,
        availableMinutes: 120,
        availableWeekdays: {1, 2, 3, 4, 5},
      );
      expect(agg['2026-08-08']!.loadMinutes, 500);
      expect(agg['2026-08-08']!.overMinutes, 0);
    });
  });
}
