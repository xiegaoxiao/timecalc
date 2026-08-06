/// 本地日历日期文本工具（yyyy-MM-dd）。
///
/// PRD §9：计划日期（deadlineDate/plannedDate/startDate/endDate）按本地
/// 日历日期以 `yyyy-MM-dd` 文本单独存储，避免跨时区导致日期漂移。本工具
/// 收敛全库散落的 `_parseDate`/`_formatDate` 实现，并保证纯日历加法不
/// 受时区/夏令时切换影响（`DateTime.add(Duration(days:))` 在 DST 日会
/// 偏移一小时，导致文本日期错位）。
library;

/// 解析 `yyyy-MM-dd` 为本地日期（day 固定为当天，不携带时刻）。
DateTime parseLocalDate(String yyyyMMdd) {
  final parts = yyyyMMdd.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// 把本地日期格式化为 `yyyy-MM-dd`。
String formatLocalDate(DateTime date) {
  final mm = date.month.toString().padLeft(2, '0');
  final dd = date.day.toString().padLeft(2, '0');
  return '${date.year}-$mm-$dd';
}

/// 返回 [date] 的 [days] 天后（同钟点，纯日历加法）。
///
/// 使用 `DateTime(year, month, day + days)` 而不是 `Duration(days:)`：
/// 后者在实行夏令时切换的地区会偏移一小时，跨天加法可能落在相邻日期。
DateTime addLocalDays(DateTime date, int days) {
  final d = DateTime(date.year, date.month, date.day);
  return DateTime(d.year, d.month, d.day + days);
}
