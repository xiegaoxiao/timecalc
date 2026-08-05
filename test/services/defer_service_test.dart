import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/services/defer_service.dart';

/// DeferService 单元测试（FR-3.3 快捷默认延期至下一可用日）。
void main() {
  const service = DeferService();

  group('nextAvailableDate（严格晚于 today）', () {
    test('每天可用时顺延一天', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 8, 5), // 周三
        availableWeekdays: {1, 2, 3, 4, 5, 6, 7},
      );
      expect(next, '2026-08-06');
    });

    test('today 当天可用时仍返回下一天（不会推回今天）', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 8, 5), // 周三
        availableWeekdays: {3},
      );
      expect(next, '2026-08-12'); // 顺延到下一个周三
    });

    test('周五且仅工作日可用时跳到下周一', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 8, 7), // 周五
        availableWeekdays: {1, 2, 3, 4, 5},
      );
      expect(next, '2026-08-10'); // 周一
    });

    test('周六且仅工作日可用时跳到下周一', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 8, 8), // 周六
        availableWeekdays: {1, 2, 3, 4, 5},
      );
      expect(next, '2026-08-10');
    });

    test('周末不可用时跨月正确（7月31日周五 -> 8月3日周一）', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 7, 31), // 周五
        availableWeekdays: {1, 2, 3, 4, 5},
      );
      expect(next, '2026-08-03');
    });

    test('跨年正确（元旦周五 -> 次日为周六，跳到下周一）', () {
      final next = service.nextAvailableDate(
        today: DateTime(2027, 1, 1), // 周五
        availableWeekdays: {1, 2, 3, 4, 5},
      );
      expect(next, '2027-01-04');
    });

    test('空集合回退为全部可用', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 8, 5),
        availableWeekdays: {},
      );
      expect(next, '2026-08-06');
    });

    test('仅周日可用时顺延到周日', () {
      final next = service.nextAvailableDate(
        today: DateTime(2026, 8, 5), // 周三
        availableWeekdays: {7},
      );
      expect(next, '2026-08-09');
    });
  });
}
