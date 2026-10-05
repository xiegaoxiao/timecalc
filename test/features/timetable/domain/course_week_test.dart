import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/features/timetable/domain/course_week.dart';

/// 教学周换算与单双周单元测试（FR-10）。
///
/// 学期基准 = 第 1 周周一。用例取自真实学期：2026-2027 学年第 1 学期
/// 第 1 周周一为 2026-09-07（该学期的课程安排表以此为基准），第 2 周周一
/// 即 2026-09-14。
void main() {
  /// 2026-09-07 是周一（第 1 周第一天）。
  final week1Monday = DateTime(2026, 9, 7);

  group('周内归一化', () {
    test('mondayOf 取所在周周一（周一自身保持不变）', () {
      expect(mondayOf(week1Monday), DateTime(2026, 9, 7));
      expect(mondayOf(DateTime(2026, 9, 9)), DateTime(2026, 9, 7)); // 周三
      expect(mondayOf(DateTime(2026, 9, 13)), DateTime(2026, 9, 7)); // 周日
      expect(mondayOf(DateTime(2026, 9, 14)), DateTime(2026, 9, 14)); // 下周一
    });

    test('mondayOfWeek 按教学周偏移；第 1 周为基准', () {
      expect(mondayOfWeek(week1Monday, 1), DateTime(2026, 9, 7));
      expect(mondayOfWeek(week1Monday, 2), DateTime(2026, 9, 14));
      expect(mondayOfWeek(week1Monday, 11), DateTime(2026, 11, 16));
      expect(mondayOfWeek(week1Monday, 18), DateTime(2027, 1, 4));
    });

    test('mondayOfWeek 对非周一传入值先归一，非法周号按第 1 周处理', () {
      // 用户在日期选择器里选到周三：仍按所在周的周一算，避免整学期偏移。
      expect(mondayOfWeek(DateTime(2026, 9, 9), 1), DateTime(2026, 9, 7));
      expect(mondayOfWeek(week1Monday, 0), DateTime(2026, 9, 7));
      expect(mondayOfWeek(week1Monday, -3), DateTime(2026, 9, 7));
    });
  });

  group('教学周号', () {
    test('同一周内任意一天得到同一周号（周一开头）', () {
      for (var day = 7; day <= 13; day++) {
        expect(teachingWeekOf(week1Monday, DateTime(2026, 9, day)), 1);
      }
      for (var day = 14; day <= 20; day++) {
        expect(teachingWeekOf(week1Monday, DateTime(2026, 9, day)), 2);
      }
    });

    test('跨月与跨年边界正确', () {
      // 第 18 周：2027-01-04 ~ 01-10。
      expect(teachingWeekOf(week1Monday, DateTime(2027, 1, 4)), 18);
      expect(teachingWeekOf(week1Monday, DateTime(2027, 1, 10)), 18);
      expect(teachingWeekOf(week1Monday, DateTime(2027, 1, 11)), 19);
    });

    test('早于第 1 周的日期返回 null（未开学）', () {
      expect(teachingWeekOf(week1Monday, DateTime(2026, 9, 6)), isNull);
      expect(teachingWeekOf(week1Monday, DateTime(2026, 8, 31)), isNull);
    });

    test('传入的基准不是周一时同样按所在周归一', () {
      // 基准给成周三 2026-09-09：其所在周周一为 09-07，周号仍从 09-07 起算。
      final oddAnchor = DateTime(2026, 9, 9);
      expect(teachingWeekOf(oddAnchor, DateTime(2026, 9, 13)), 1);
      expect(teachingWeekOf(oddAnchor, DateTime(2026, 9, 14)), 2);
    });

    test('忽略时刻，只看日历日', () {
      expect(
        teachingWeekOf(week1Monday, DateTime(2026, 9, 14, 23, 59)),
        2,
      );
    });
  });

  group('单双周', () {
    test('每周匹配所有周', () {
      expect(weekParityMatches(WeekParity.all, 1), isTrue);
      expect(weekParityMatches(WeekParity.all, 12), isTrue);
    });

    test('单周只匹配奇数教学周、双周只匹配偶数教学周', () {
      expect(weekParityMatches(WeekParity.odd, 1), isTrue);
      expect(weekParityMatches(WeekParity.odd, 2), isFalse);
      expect(weekParityMatches(WeekParity.even, 2), isTrue);
      expect(weekParityMatches(WeekParity.even, 3), isFalse);
    });

    test('未知取值按「每周」处理（脏数据不让课程整周消失）', () {
      expect(weekParityMatches('bogus', 3), isTrue);
      expect(weekParityMatches('', 4), isTrue);
    });

    test('中文标签与范围文本', () {
      expect(weekParityLabel(WeekParity.all), '每周');
      expect(weekParityLabel(WeekParity.odd), '单周');
      expect(weekParityLabel(WeekParity.even), '双周');
      expect(weekRangeLabel(2, 18, WeekParity.all), '2-18 周');
      expect(weekRangeLabel(3, 3, WeekParity.all), '第 3 周');
      expect(weekRangeLabel(2, 18, WeekParity.odd), '2-18 周（单周）');
    });
  });

  group('星期标签', () {
    test('ISO 星期 1~7 对应周一到周日', () {
      expect(weekdayLabel(1), '周一');
      expect(weekdayLabel(4), '周四');
      expect(weekdayLabel(7), '周日');
      expect(kWeekdayLabels, ['一', '二', '三', '四', '五', '六', '日']);
    });

    test('越界返回 null', () {
      expect(weekdayLabel(0), isNull);
      expect(weekdayLabel(8), isNull);
    });
  });

  group('学期内最后一周', () {
    test('取最大值；空集合为 0', () {
      expect(latestWeekOf([2, 18, 8]), 18);
      expect(latestWeekOf([5]), 5);
      expect(latestWeekOf(const <int>[]), 0);
    });
  });
}
