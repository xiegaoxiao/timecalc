import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/tasks/domain/duration_validator.dart';

/// 预估时长校验单元测试（FR-3 验收：1/1440/非法值）。
void main() {
  group('DurationValidator（FR-3 验收）', () {
    test('合法值：1 分钟', () {
      expect(DurationValidator.validate('1'), isNull);
    });

    test('合法值：1440 分钟（24 小时）', () {
      expect(DurationValidator.validate('1440'), isNull);
    });

    test('合法值：中间值 90', () {
      expect(DurationValidator.validate('90'), isNull);
    });

    test('非法值：0', () {
      expect(DurationValidator.validate('0'), isNotNull);
    });

    test('非法值：1441', () {
      expect(DurationValidator.validate('1441'), isNotNull);
    });

    test('非法值：负数', () {
      expect(DurationValidator.validate('-30'), isNotNull);
    });

    test('非法值：非整数', () {
      expect(DurationValidator.validate('abc'), isNotNull);
      expect(DurationValidator.validate('1.5'), isNotNull);
    });

    test('非法值：空与空白', () {
      expect(DurationValidator.validate(null), isNotNull);
      expect(DurationValidator.validate('  '), isNotNull);
    });
  });
}
