/// 本地日历日期文本工具（yyyy-MM-dd）。
///
/// PRD §9：计划日期（deadlineDate/plannedDate/startDate/endDate）按本地
/// 日历日期以 `yyyy-MM-dd` 文本单独存储，避免跨时区导致日期漂移。本工具
/// 收敛全库散落的 `_parseDate`/`_formatDate` 实现，并保证纯日历加法不
/// 受时区/夏令时切换影响（`DateTime.add(Duration(days:))` 在 DST 日会
/// 偏移一小时，导致文本日期错位）。
library;

/// 严格 `yyyy-MM-dd` 格式（年 4 位，月/日 2 位，数值范围另行校验）。
final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// 解析 `yyyy-MM-dd` 为本地日期（day 固定为当天，不携带时刻）。
///
/// 不校验入参格式：若 [yyyyMMdd] 不是合法的 `yyyy-MM-dd`（段数不足、含
/// 非数字、或年月日越界），会抛 [RangeError]/[FormatException]。请优先
/// 使用容错版 [tryParseLocalDate]，仅当调用方已确保格式时才用本函数。
DateTime parseLocalDate(String yyyyMMdd) {
  final parsed = tryParseLocalDate(yyyyMMdd);
  if (parsed == null) {
    throw FormatException('不是合法的本地日期文本: $yyyyMMdd');
  }
  return parsed;
}

/// 容错解析 `yyyy-MM-dd`：格式或范围非法时返回 `null`（不抛异常）。
///
/// 用于防御外部脏数据（手工改库、备份/导入恢复的非规范日期），解析失败
/// 由调用方决定回退；同时校验真实天数，避免 `2026-02-31` 被 [DateTime]
/// 静默归一化为 3 月 3 日。
DateTime? tryParseLocalDate(String yyyyMMdd) {
  if (!_datePattern.hasMatch(yyyyMMdd)) return null;
  final parts = yyyyMMdd.split('-');
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  if (year < 1 || year > 9999) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  final maxDay = DateTime(year, month + 1, 0).day;
  if (day > maxDay) return null;
  return DateTime(year, month, day);
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
