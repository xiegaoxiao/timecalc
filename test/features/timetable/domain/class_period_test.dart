import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/timetable/domain/class_period.dart';

/// 作息表（节次 ↔ 钟点）单元测试。
///
/// 课表的「第几节」是入库的锚点，钟点只是展示与导入换算用，因此这里锁死
/// 三件事：节次编号连续、作息表与校历一致（含晚上 9-12 节）、钟点换算的
/// 边界（一天最早/最晚、下课钟点落在节次边界上）。
void main() {
  group('作息表（FR-10）', () {
    test('节次编号从 1 连续到 12，且每节都有合法起止钟点', () {
      expect(ClassPeriods.count, 12);
      expect(ClassPeriods.all.map((p) => p.index).toList(), [
        for (var i = 1; i <= 12; i++) i,
      ]);
      final timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
      int minutesOf(String hhmm) {
        final parts = hhmm.split(':');
        return int.parse(parts[0]) * 60 + int.parse(parts[1]);
      }

      for (final period in ClassPeriods.all) {
        expect(timePattern.hasMatch(period.start), isTrue, reason: period.start);
        expect(timePattern.hasMatch(period.end), isTrue, reason: period.end);
        // 单节时长为正（下课钟点晚于上课钟点）。
        expect(
          minutesOf(period.end),
          greaterThan(minutesOf(period.start)),
          reason: '${period.start}-${period.end}',
        );
      }
    });

    test('上午/下午/晚上三段的钟点与校历一致', () {
      expect(ClassPeriods.byIndex(1)!.start, '08:30');
      expect(ClassPeriods.byIndex(4)!.end, '11:50');
      expect(ClassPeriods.byIndex(5)!.start, '14:00');
      expect(ClassPeriods.byIndex(8)!.end, '17:10');
      // 晚上 9-12 节：9 节 19:00 起，12 节顺延至 22:10。
      expect(ClassPeriods.byIndex(9)!.start, '19:00');
      expect(ClassPeriods.byIndex(12)!.end, '22:10');
    });

    test('byIndex 越界返回 null 而不抛异常（外部数据用）', () {
      expect(ClassPeriods.byIndex(0), isNull);
      expect(ClassPeriods.byIndex(-1), isNull);
      expect(ClassPeriods.byIndex(13), isNull);
      expect(ClassPeriods.hasPeriod(0), isFalse);
      expect(ClassPeriods.hasPeriod(12), isTrue);
    });

    test('区间文本：单节与多节两种形态', () {
      expect(ClassPeriods.rangeLabel(3, 3), '第 3 节');
      expect(ClassPeriods.rangeLabel(5, 8), '第 5-8 节');
      expect(ClassPeriods.timeRangeLabel(5, 8), '14:00-17:10');
      expect(ClassPeriods.timeRangeLabel(1, 2), '08:30-10:00');
    });

    test('timeRangeLabel 任一端越界返回 null', () {
      expect(ClassPeriods.timeRangeLabel(0, 2), isNull);
      expect(ClassPeriods.timeRangeLabel(1, 13), isNull);
    });

    test('起始钟点就近换算节次：课表常见钟点落到正确节次', () {
      // 上午 1-2 节（8:30 上课）、3-4 节（10:20 上课）。
      expect(ClassPeriods.nearestStartPeriod('08:30'), 1);
      expect(ClassPeriods.nearestStartPeriod('09:20'), 2);
      expect(ClassPeriods.nearestStartPeriod('10:20'), 3);
      expect(ClassPeriods.nearestStartPeriod('11:10'), 4);
      // 下午 5-8 节（14:00 上课）。
      expect(ClassPeriods.nearestStartPeriod('14:00'), 5);
      expect(ClassPeriods.nearestStartPeriod('16:30'), 8);
      // 晚上 9-12 节（19:00 上课）。
      expect(ClassPeriods.nearestStartPeriod('19:00'), 9);
    });

    test('起始钟点换算兜底：早于第一节落到 1，晚于最后一节落到 12', () {
      expect(ClassPeriods.nearestStartPeriod('07:00'), 1);
      expect(ClassPeriods.nearestStartPeriod('23:30'), 12);
      // 课间（如 17:50，晚课前的空档）取「不晚于它的最后一节」。
      expect(ClassPeriods.nearestStartPeriod('17:50'), 8);
    });

    test('结束钟点就近换算节次：取「不早于它的第一节」', () {
      // 下课钟点正好落在节次边界上。
      expect(ClassPeriods.nearestEndPeriod('11:50', startPeriod: 3), 4);
      expect(ClassPeriods.nearestEndPeriod('16:20', startPeriod: 5), 7);
      expect(ClassPeriods.nearestEndPeriod('10:00', startPeriod: 1), 2);
      // 落在两节之间（10:10，第 2 节已下课、第 3 节未下课）取第 3 节。
      expect(ClassPeriods.nearestEndPeriod('10:10', startPeriod: 1), 3);
    });

    test('结束钟点换算不会早于起始节次', () {
      // 结束钟点比起始更早（脏数据）时夹到起始节，避免出现负长度区间。
      expect(ClassPeriods.nearestEndPeriod('08:30', startPeriod: 5), 5);
    });
  });
}
