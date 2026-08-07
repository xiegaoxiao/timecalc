import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/services/countdown_service.dart';

/// 倒计时规则单元测试（checklists §5.1：跨日、跨年、DST）。
void main() {
  const service = CountdownService();

  group('FR-1.2 倒计时按本地日期计算', () {
    test('截止日未到：显示剩余天数', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-12-20',
        today: DateTime(2026, 8, 5),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.upcoming);
      expect(days, 137);
    });

    test('截止日当天：今天截止', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-08-05',
        today: DateTime(2026, 8, 5, 23, 59),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.today);
      expect(days, 0);
    });

    test('截止日为昨天：已逾期 1 天', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-08-04',
        today: DateTime(2026, 8, 5),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.overdue);
      expect(days, 1);
    });

    test('不按小时取整：今天早于截止时刻仍是今天截止', () {
      final (phase, _) = service.evaluate(
        deadlineDate: '2026-08-05',
        today: DateTime(2026, 8, 5, 1),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.today);
    });
  });

  group('FR-1.3 逾期显示', () {
    test('逾期 30 天', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-07-06',
        today: DateTime(2026, 8, 5),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.overdue);
      expect(days, 30);
    });
  });

  group('FR-1.4 完成/放弃停止逾期提醒', () {
    test('已完成目标不计逾期', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-07-01',
        today: DateTime(2026, 8, 5),
        status: GoalStatus.completed,
      );
      expect(phase, CountdownPhase.terminated);
      // terminated 的 days 恒为 0（截止日为过去日期也不外漏负数，P3.5）。
      expect(days, 0);
    });

    test('已放弃目标不计逾期', () {
      final (phase, _) = service.evaluate(
        deadlineDate: '2026-07-01',
        today: DateTime(2026, 8, 5),
        status: GoalStatus.abandoned,
      );
      expect(phase, CountdownPhase.terminated);
    });

    test('归档目标不计逾期（归档同样停止倒计时与逾期提醒）', () {
      final (phase, _) = service.evaluate(
        deadlineDate: '2026-07-01',
        today: DateTime(2026, 8, 5),
        status: GoalStatus.archived,
      );
      expect(phase, CountdownPhase.terminated);
    });
  });

  group('日期边界：跨年、闰年、DST', () {
    test('跨年倒计时', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2027-01-01',
        today: DateTime(2026, 12, 31),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.upcoming);
      expect(days, 1);
    });

    test('跨年逾期', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-12-31',
        today: DateTime(2027, 1, 1),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.overdue);
      expect(days, 1);
    });

    test('闰年 2 月 29 日', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2028-02-29',
        today: DateTime(2028, 2, 1),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.upcoming);
      expect(days, 28);
    });

    test('DST 切换日（春令时开始日）不产生天数偏差', () {
      // 模拟 DST 切换日：本地日期差 1 天，按日历日计算必须是 1。
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-03-09',
        today: DateTime(2026, 3, 8, 10),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.upcoming);
      expect(days, 1);
    });

    test('非闰年 2 月 28 日边界', () {
      final (phase, days) = service.evaluate(
        deadlineDate: '2026-02-28',
        today: DateTime(2026, 2, 27),
        status: GoalStatus.active,
      );
      expect(phase, CountdownPhase.upcoming);
      expect(days, 1);
    });
  });

  group('文案（CountdownService.label）', () {
    test('四种阶段文案', () {
      expect(CountdownService.label(CountdownPhase.upcoming, 5), '剩余 5 天');
      expect(CountdownService.label(CountdownPhase.today, 0), '今天截止');
      expect(CountdownService.label(CountdownPhase.overdue, 3), '已逾期 3 天');
      expect(CountdownService.label(CountdownPhase.terminated, 0), '已结束');
    });
  });
}
