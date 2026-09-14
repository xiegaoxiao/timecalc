/// 作息表：节次 ↔ 钟点（FR-10 课表）。
///
/// 课程表用「第几节」而非绝对钟点定位（tables.dart Courses 注释），
/// 因此渲染与导入都需要一张「第 N 节几点到几点」的对照表。表值取自
/// 华南师范大学研究生课程安排表的作息说明，按「上午 4 节 / 下午 4 节 /
/// 晚上 4 节」三段排布。
///
/// 纯 Dart、无 Flutter 与数据库依赖，可在 isolate 内运行。
library;

/// 单个节次的时间段（本地墙上时间 `HH:mm`）。
class ClassPeriod {
  const ClassPeriod({
    required this.index,
    required this.start,
    required this.end,
  });

  /// 节次序号（1 起，与 Courses.startPeriod 同口径）。
  final int index;

  /// 起始钟点 `HH:mm`。
  final String start;

  /// 结束钟点 `HH:mm`。
  final String end;

  /// 单节时长（分钟）。
  int get minutes => _minutesOf(end) - _minutesOf(start);

  /// `14:00-14:40` 形式的展示文本。
  String get label => '$start-$end';

  static int _minutesOf(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}

/// 全部节次与「钟点 → 节次」的换算。
///
/// 第十二节不在校历给出的作息说明里，但课表实际存在「晚上 9-12 节」的
/// 课程（如算法设计与分析实验），故按第十一节顺延 50 分钟补出第十二节，
/// 使 12 节的课程在网格里有完整行位（见 [hasPeriod] 与 [all] 的一致性）。
abstract final class ClassPeriods {
  static const List<ClassPeriod> all = [
    ClassPeriod(index: 1, start: '08:30', end: '09:10'),
    ClassPeriod(index: 2, start: '09:20', end: '10:00'),
    ClassPeriod(index: 3, start: '10:20', end: '11:00'),
    ClassPeriod(index: 4, start: '11:10', end: '11:50'),
    ClassPeriod(index: 5, start: '14:00', end: '14:40'),
    ClassPeriod(index: 6, start: '14:50', end: '15:30'),
    ClassPeriod(index: 7, start: '15:40', end: '16:20'),
    ClassPeriod(index: 8, start: '16:30', end: '17:10'),
    ClassPeriod(index: 9, start: '19:00', end: '19:40'),
    ClassPeriod(index: 10, start: '19:50', end: '20:30'),
    ClassPeriod(index: 11, start: '20:40', end: '21:20'),
    ClassPeriod(index: 12, start: '21:30', end: '22:10'),
  ];

  /// 节次总数（网格行数）。
  static int get count => all.length;

  /// [index] 是否为合法节次。
  static bool hasPeriod(int index) => index >= 1 && index <= all.length;

  /// 取第 [index] 节的作息；越界返回 null（不抛异常，外部数据用）。
  static ClassPeriod? byIndex(int index) =>
      hasPeriod(index) ? all[index - 1] : null;

  /// 节次区间的展示文本：`第 5-8 节`（起止相同则 `第 3 节`）。
  static String rangeLabel(int startPeriod, int endPeriod) {
    if (startPeriod == endPeriod) return '第 $startPeriod 节';
    return '第 $startPeriod-$endPeriod 节';
  }

  /// 节次区间的钟点文本：`14:00-17:10`；任一节次越界返回 null。
  static String? timeRangeLabel(int startPeriod, int endPeriod) {
    final start = byIndex(startPeriod);
    final end = byIndex(endPeriod);
    if (start == null || end == null) return null;
    return '${start.start}-${end.end}';
  }

  /// 与 [hhmm] 起始钟点最贴近的节次（导入 ICS 时的近似定位）。
  ///
  /// 外部日历只给钟点、不给节次，而课表模型以节次为锚：取「起始钟点
  /// 不晚于 [hhmm] 的最后一节」，早于第一节统一落到第一节。误差不超过
  /// 一节课（50 分钟），且导入预览会展示换算结果供用户核对。
  static int nearestStartPeriod(String hhmm) {
    final target = ClassPeriod._minutesOf(hhmm);
    var result = 1;
    for (final period in all) {
      if (ClassPeriod._minutesOf(period.start) <= target) {
        result = period.index;
      }
    }
    return result;
  }

  /// 与 [hhmm] 结束钟点最贴近的节次（不早于 [startPeriod]）。
  ///
  /// 取「结束钟点不早于 [hhmm] 的第一节」：`11:50` → 第 4 节（第四节
  /// 正是 11:50 下课），`16:20` → 第 7 节。晚于最后一节统一落到最后一节。
  static int nearestEndPeriod(String hhmm, {required int startPeriod}) {
    final target = ClassPeriod._minutesOf(hhmm);
    for (final period in all) {
      if (ClassPeriod._minutesOf(period.end) >= target) {
        return period.index < startPeriod ? startPeriod : period.index;
      }
    }
    return all.length < startPeriod ? startPeriod : all.length;
  }
}
