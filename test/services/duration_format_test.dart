import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/services/duration_format.dart';

/// DurationFormat 单元测试（分钟 → 「N 小时 M 分」）。
void main() {
  group('minutes', () {
    test('不足 1 小时显示分钟', () {
      expect(DurationFormat.minutes(0), '0 分');
      expect(DurationFormat.minutes(30), '30 分');
      expect(DurationFormat.minutes(59), '59 分');
    });

    test('整小时不显示分钟', () {
      expect(DurationFormat.minutes(60), '1 小时');
      expect(DurationFormat.minutes(120), '2 小时');
      expect(DurationFormat.minutes(1440), '24 小时');
    });

    test('小时与分钟组合', () {
      expect(DurationFormat.minutes(90), '1 小时 30 分');
      expect(DurationFormat.minutes(150), '2 小时 30 分');
      expect(DurationFormat.minutes(605), '10 小时 5 分');
    });
  });
}
