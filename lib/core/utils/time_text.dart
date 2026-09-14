/// 本地墙上时刻文本工具（HH:mm）。
///
/// 小时级排程（schema v16）在计划日期 `yyyy-MM-dd`（见 date_text.dart）
/// 之上追加一个可选钟点：Tasks.startTime / RecurrenceTemplates.startTime。
/// 与日期同理，钟点存「本地墙上时间」而非 UTC 时间戳——用户说的「晚上八点
/// 背单词」指的是他墙上钟的八点，跨时区不该漂移。
///
/// 24 小时制、零填充两位，字典序即时间序，因此可直接参与 SQL 排序与比较。
library;

/// 严格 `HH:mm`（00:00～23:59，两位零填充）。
final RegExp _timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// 宽松 `H:mm` / `HH:mm`（ICS 与手工输入常见单位数小时，如 `9:05`）。
final RegExp _looseTimePattern = RegExp(r'^(\d{1,2}):([0-5]\d)$');

/// 一天的总分钟数（时刻取值上界，用于排序与换算）。
const int minutesPerDay = 24 * 60;

/// 是否为严格 `HH:mm` 文本。
bool isValidTimeOfDay(String text) => _timePattern.hasMatch(text);

/// 规范化 `HH:mm`：接受 `9:05` / `09:05` 两种写法，输出 `09:05`。
///
/// 范围内非法（小时 > 23、分钟 > 59、缺冒号）抛 [FormatException]；
/// 容错场景请用 [tryNormalizeTimeOfDay]。
String normalizeTimeOfDay(String text) {
  final parsed = tryNormalizeTimeOfDay(text);
  if (parsed == null) {
    throw FormatException('不是合法的本地时刻文本: $text');
  }
  return parsed;
}

/// 容错规范化时刻：非法或为 null 时返回 `null`（不抛异常）。
///
/// 用于防御外部脏数据（ICS 文件、手工改库、备份恢复的非规范时刻）。
String? tryNormalizeTimeOfDay(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (_timePattern.hasMatch(trimmed)) return trimmed;
  final loose = _looseTimePattern.firstMatch(trimmed);
  if (loose == null) return null;
  final hour = int.parse(loose.group(1)!);
  if (hour > 23) return null;
  return '${hour.toString().padLeft(2, '0')}:${loose.group(2)}';
}

/// 把 [dateTime] 的钟点格式化为 `HH:mm`（忽略日期部分）。
String formatLocalTime(DateTime dateTime) {
  final hh = dateTime.hour.toString().padLeft(2, '0');
  final mm = dateTime.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// 时刻转「当日已过分钟数」（00:00 = 0，23:59 = 1439）。
///
/// 不校验入参：格式非法抛 [FormatException]，请优先使用
/// [tryTimeOfDayMinutes]。
int timeOfDayMinutes(String hhmm) {
  final parsed = tryTimeOfDayMinutes(hhmm);
  if (parsed == null) {
    throw FormatException('不是合法的本地时刻文本: $hhmm');
  }
  return parsed;
}

/// 容错时刻转分钟数：非法或为 null 时返回 `null`。
int? tryTimeOfDayMinutes(String? hhmm) {
  final normalized = tryNormalizeTimeOfDay(hhmm);
  if (normalized == null) return null;
  final parts = normalized.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

/// 分钟数转 `HH:mm`，按一天取模（1440 → `00:00`，负值向前回绕）。
String minutesToTimeOfDay(int minutes) {
  final wrapped = minutes % minutesPerDay;
  final normalized = wrapped < 0 ? wrapped + minutesPerDay : wrapped;
  final hh = (normalized ~/ 60).toString().padLeft(2, '0');
  final mm = (normalized % 60).toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// 排序键：有时刻取当日分钟数，无时刻取 -1（排在当天最前，与日历「全天」
/// 事项置顶的惯例一致）。用于「同一天内按钟点排」的稳定排序。
int timeOfDaySortKey(String? hhmm) => tryTimeOfDayMinutes(hhmm) ?? -1;

/// 把本地日历日期 [date] 与可选时刻 [time] 合成 [DateTime]。
///
/// [time] 为 null 或非法时取当日 00:00（「只排到天」的语义，调用方不应把
/// 结果当作精确时刻使用）。校验非法时刻属于调用方职责，此处不抛错。
DateTime combineLocalDateTime(DateTime date, String? time) {
  final minutes = tryTimeOfDayMinutes(time);
  if (minutes == null) return DateTime(date.year, date.month, date.day);
  // 直接构造钟点而不是 `add(Duration)`：夏令时切换日加时长会偏移墙上时间
  // （date_text.addLocalDays 同款理由）。
  return DateTime(date.year, date.month, date.day, minutes ~/ 60, minutes % 60);
}
