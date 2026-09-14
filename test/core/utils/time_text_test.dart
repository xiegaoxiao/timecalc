import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/utils/time_text.dart';

/// 本地墙上时刻工具（schema v16 小时级排程）单元测试。
void main() {
  group('isValidTimeOfDay', () {
    test('接受严格 HH:mm', () {
      expect(isValidTimeOfDay('00:00'), isTrue);
      expect(isValidTimeOfDay('09:05'), isTrue);
      expect(isValidTimeOfDay('23:59'), isTrue);
    });

    test('拒绝越界/非规范写法', () {
      expect(isValidTimeOfDay('24:00'), isFalse);
      expect(isValidTimeOfDay('23:60'), isFalse);
      expect(isValidTimeOfDay('9:05'), isFalse); // 宽松写法只有规范化函数接受
      expect(isValidTimeOfDay('0905'), isFalse);
      expect(isValidTimeOfDay(''), isFalse);
      expect(isValidTimeOfDay('ab:cd'), isFalse);
    });
  });

  group('tryNormalizeTimeOfDay', () {
    test('严格写法原样返回', () {
      expect(tryNormalizeTimeOfDay('09:05'), '09:05');
    });

    test('宽松写法补零', () {
      expect(tryNormalizeTimeOfDay('9:05'), '09:05');
      expect(tryNormalizeTimeOfDay(' 8:30 '), '08:30');
      expect(tryNormalizeTimeOfDay('0:00'), '00:00');
    });

    test('非法与空值返回 null', () {
      expect(tryNormalizeTimeOfDay('24:00'), isNull);
      expect(tryNormalizeTimeOfDay('12:60'), isNull);
      expect(tryNormalizeTimeOfDay('12'), isNull);
      expect(tryNormalizeTimeOfDay(''), isNull);
      expect(tryNormalizeTimeOfDay('   '), isNull);
      expect(tryNormalizeTimeOfDay(null), isNull);
    });
  });

  test('normalizeTimeOfDay 非法时抛 FormatException', () {
    expect(() => normalizeTimeOfDay('25:00'), throwsFormatException);
    expect(normalizeTimeOfDay('7:00'), '07:00');
  });

  test('formatLocalTime 取钟点并补零', () {
    expect(formatLocalTime(DateTime(2026, 8, 5, 7, 4)), '07:04');
    expect(formatLocalTime(DateTime(2026, 8, 5, 23, 59)), '23:59');
    expect(formatLocalTime(DateTime(2026, 8, 5)), '00:00');
  });

  test('timeOfDayMinutes 与 minutesToTimeOfDay 互为逆运算', () {
    expect(timeOfDayMinutes('00:00'), 0);
    expect(timeOfDayMinutes('20:30'), 1230);
    expect(timeOfDayMinutes('23:59'), 1439);
    expect(minutesToTimeOfDay(0), '00:00');
    expect(minutesToTimeOfDay(1230), '20:30');
    expect(minutesToTimeOfDay(1439), '23:59');
  });

  test('minutesToTimeOfDay 按一天回绕', () {
    expect(minutesToTimeOfDay(1440), '00:00');
    expect(minutesToTimeOfDay(1500), '01:00');
    expect(minutesToTimeOfDay(-60), '23:00');
  });

  test('tryTimeOfDayMinutes 容错返回 null', () {
    expect(tryTimeOfDayMinutes('9:05'), 545);
    expect(tryTimeOfDayMinutes('24:00'), isNull);
    expect(tryTimeOfDayMinutes(null), isNull);
  });

  test('timeOfDaySortKey：无时刻排最前，有时刻按分钟', () {
    expect(timeOfDaySortKey(null), -1);
    expect(timeOfDaySortKey('07:00'), 420);
    expect(timeOfDaySortKey('20:00'), 1200);
    // 排序语义：无时刻（全天）→ 最早 → 上午 → 晚上。
    final sorted = [null, '20:00', '07:00']
      ..sort((a, b) => timeOfDaySortKey(a).compareTo(timeOfDaySortKey(b)));
    expect(sorted, [null, '07:00', '20:00']);
  });

  group('combineLocalDateTime', () {
    test('有时刻取该钟点（墙上时间）', () {
      final combined = combineLocalDateTime(DateTime(2026, 8, 5), '20:30');
      expect(combined, DateTime(2026, 8, 5, 20, 30));
    });

    test('无时刻或非法时刻退化为当日 00:00', () {
      expect(
        combineLocalDateTime(DateTime(2026, 8, 5), null),
        DateTime(2026, 8, 5),
      );
      expect(
        combineLocalDateTime(DateTime(2026, 8, 5, 13, 45), ''),
        DateTime(2026, 8, 5),
      );
    });

    test('带时刻的日期入参只取年月日', () {
      expect(
        combineLocalDateTime(DateTime(2026, 8, 5, 23, 59), '06:15'),
        DateTime(2026, 8, 5, 6, 15),
      );
    });
  });
}
