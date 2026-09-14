/// 教学周换算与单双周（FR-10 课表）。
///
/// 课程存的是「教学周编号」而非绝对日期，渲染时把
/// （教学周编号 + 星期几）还原成真实日期需要一个锚点：学期第 1 周周一
/// （`Settings.semesterStartDate`，见 tables.dart）。本文件收敛这套换算，
/// 全部为纯函数，便于单测覆盖跨月/跨年/闰年边界。
///
/// 纯 Dart、无 Flutter 与数据库依赖，可在 isolate 内运行。
library;

import '../../../core/database/tables.dart';
import '../../../core/utils/date_text.dart';

/// 星期几的中文短标签（索引 0 = 周一 … 6 = 周日，与 ISO 星期 1~7 对齐）。
const List<String> kWeekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// `周一` 形式的中文全称；[isoWeekday] 越界返回 null。
String? weekdayLabel(int isoWeekday) {
  if (isoWeekday < 1 || isoWeekday > 7) return null;
  return '周${kWeekdayLabels[isoWeekday - 1]}';
}

/// 所在周的周一（纯日历加法：`Duration(days:)` 在夏令时切换日会偏移
/// 一小时，周起点可能落到相邻日期，与 date_text 的约定一致）。
DateTime mondayOf(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  return addLocalDays(day, -(day.weekday - 1));
}

/// 第 [week] 教学周的周一；[week] 小于 1 时按第 1 周处理。
///
/// [semesterStart] 是第 1 周周一（若传入的不是周一，先归一到所在周的
/// 周一，容忍用户在日期选择器里选到周三这类偏差）。
DateTime mondayOfWeek(DateTime semesterStart, int week) {
  final anchor = mondayOf(semesterStart);
  final offset = (week < 1 ? 1 : week) - 1;
  return addLocalDays(anchor, offset * 7);
}

/// 教学周总区间：从第 1 周周一到第 [totalWeeks] 周周日。
DateTime lastDayOfWeek(DateTime semesterStart, int week) =>
    addLocalDays(mondayOfWeek(semesterStart, week), 6);

/// [date] 落在学期第几教学周；早于第 1 周返回 null（假期/上学期日期）。
///
/// 「周」以周一为界，故用「相差天数 ÷ 7」向上取整的等价写法：同一周内的
/// 任意一天（周一~周日）都得到同一个周号。
int? teachingWeekOf(DateTime semesterStart, DateTime date) {
  final anchor = mondayOf(semesterStart);
  final day = DateTime(date.year, date.month, date.day);
  final diffDays = day.difference(anchor).inDays;
  if (diffDays < 0) return null;
  return diffDays ~/ 7 + 1;
}

/// [date] 是否为学期第 1 周之前（尚未开学）。
bool isBeforeSemester(DateTime semesterStart, DateTime date) =>
    teachingWeekOf(semesterStart, date) == null;

/// 单双周是否匹配第 [week] 教学周。
///
/// [parity] 取 [WeekParity] 常量；未知取值按「每周」（`all`）处理——脏数据
/// 不该让课程整周消失（宁可多显示，也不要静默丢课）。
bool weekParityMatches(String parity, int week) {
  switch (parity) {
    case WeekParity.odd:
      return week.isOdd;
    case WeekParity.even:
      return week.isEven;
    case WeekParity.all:
    default:
      return true;
  }
}

/// [parity] 的中文标签：`每周` / `单周` / `双周`。
String weekParityLabel(String parity) {
  switch (parity) {
    case WeekParity.odd:
      return '单周';
    case WeekParity.even:
      return '双周';
    default:
      return '每周';
  }
}

/// 教学周范围文本：`2-18 周`（起止相同则 `第 3 周`），单双周另缀。
String weekRangeLabel(int startWeek, int endWeek, String parity) {
  final range = startWeek == endWeek
      ? '第 $startWeek 周'
      : '$startWeek-$endWeek 周';
  final label = weekParityLabel(parity);
  return label == '每周' ? range : '$range（$label）';
}

/// 课程在学期内的最后一周（用于「本周之后还有课吗」等提示）。
int latestWeekOf(Iterable<int> endWeeks) =>
    endWeeks.isEmpty ? 0 : endWeeks.reduce((a, b) => a > b ? a : b);
