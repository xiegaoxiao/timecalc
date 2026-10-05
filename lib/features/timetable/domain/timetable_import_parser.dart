/// 课表导入解析（FR-10）：外部课表文件 → 待导入的课程草稿列表。
///
/// 支持两种输入，与「完整计划导入」同款策略——**按内容判别格式**，
/// 不看扩展名：
/// - **iCalendar（.ics）**：每个 `VEVENT` 一门课。课表 ICS 通常用
///   `RRULE:FREQ=WEEKLY` 表达「每周重复」，用 `DTSTART/DTEND` 给钟点；
///   节次与教学周优先从 `DESCRIPTION` 的结构化字段读（见下方约定），
///   缺失时才用钟点就近换算节次、用 `RRULE` 的 `COUNT/INTERVAL` 推周次；
/// - **课表 JSON**：字段直给节次与周次，无损往返（导出/再导入首选）。
///
/// `DESCRIPTION` 约定（用 `｜` 或换行分隔的 `键：值`）：
/// `教师：梁军、汪红松｜周次：2-8周｜类别：学科基础课｜节次：5-8节`
/// 未识别的片段原样并入备注（`注：官方标注 17:50 开始` 这类提示不丢）。
///
/// 纯 Dart，不依赖数据库与 UI，可在 isolate 内运行。
library;

import 'dart:convert';

import '../../../core/database/tables.dart';
import '../../../core/utils/date_text.dart';
import '../../calendar_io/domain/ics_codec.dart';
import '../../tasks/domain/task_import_parser.dart' show ImportIssue;
import 'class_period.dart';
import 'course_week.dart';

/// 一门待导入的课程（已校验：节次/周次范围合法、标题非空）。
///
/// 与 drift 行 `Course` 的区别：草稿不含 id 与时间戳（落库时才生成），
/// 颜色可空（导入侧按顺序分配配色，避免外部文件不带色时课程全灰）。
class CourseDraft {
  const CourseDraft({
    required this.title,
    required this.weekday,
    required this.startPeriod,
    required this.endPeriod,
    required this.startWeek,
    required this.endWeek,
    this.teacher,
    this.location,
    this.weekParity = WeekParity.all,
    this.category,
    this.note,
    this.color,
  });

  final String title;
  final String? teacher;
  final String? location;

  /// 星期几（ISO，1=周一 … 7=周日）。
  final int weekday;

  /// 节次区间（含两端，1 起）。
  final int startPeriod;
  final int endPeriod;

  /// 教学周区间（含两端，1 起）。
  final int startWeek;
  final int endWeek;

  /// 单双周，取值见 [WeekParity]。
  final String weekParity;

  final String? category;
  final String? note;

  /// 卡片配色 `#RRGGBB`；null 表示由导入侧分配。
  final String? color;

  /// 单次课的节数（网格跨行数）。
  int get periodCount => endPeriod - startPeriod + 1;
}

/// 课表导入解析结果。
///
/// 与 `PlanImportResult` 同契约：有 [issues] 时**不带**课程列表，任何一条
/// 结构性错误都不会写入部分数据（NFR-2）。
class TimetableImportResult {
  const TimetableImportResult({
    this.courses = const [],
    this.semesterStart,
    this.calendarName,
    this.issues = const [],
    this.skippedEvents = 0,
  });

  final List<CourseDraft> courses;

  /// 推导出的教学周基准（第 1 周周一，`yyyy-MM-dd`）；无法推导为 null。
  final String? semesterStart;

  /// 日历名 / 课表名（导入预览展示用）。
  final String? calendarName;

  final List<ImportIssue> issues;

  /// 跳过的事件数（已取消、无钟点、非重复事件的单次日程）。
  final int skippedEvents;

  /// 是否可导入：无错误且至少一门课。
  bool get isValid => issues.isEmpty && courses.isNotEmpty;
}

/// 课表文件 → [TimetableImportResult]。
class TimetableImportParser {
  const TimetableImportParser({this.codec = const IcsCodec()});

  final IcsCodec codec;

  /// 课程标题与备注长度上限（与 Courses.title 的 200 一致）。
  static const int maxTitleLength = 200;

  /// 教学周上限：正常学期 ≤ 30 周，超出视为脏数据（防网格周选择器无界）。
  static const int maxWeek = 30;

  /// 按内容判别格式：[source] 以 `BEGIN:VCALENDAR` 开头按 ICS，否则按 JSON。
  TimetableImportResult parse(String source, {String? fallbackName}) {
    final trimmed = source.trimLeft();
    if (trimmed.toUpperCase().startsWith('BEGIN:VCALENDAR')) {
      return _parseIcs(source, fallbackName: fallbackName);
    }
    return _parseJson(source, fallbackName: fallbackName);
  }

  // ------------------------------------------------------------ iCalendar

  TimetableImportResult _parseIcs(String source, {String? fallbackName}) {
    final IcsCalendar calendar;
    try {
      calendar = codec.parse(source);
    } on FormatException catch (e) {
      return TimetableImportResult(issues: [ImportIssue(e.message)]);
    }

    if (calendar.events.isEmpty) {
      return const TimetableImportResult(
        issues: [ImportIssue('这个日历里没有事件（VEVENT）')],
      );
    }

    final issues = <ImportIssue>[];
    final courses = <CourseDraft>[];
    // 教学周基准候选：每门课都由「首次上课日期 − (起始周−1)×7」反推一次，
    // 取出现次数最多者（各门课应一致；混入其它学期的事件时不至于跑偏）。
    final semesterCandidates = <String, int>{};
    var skipped = 0;

    for (var i = 0; i < calendar.events.length; i++) {
      final event = calendar.events[i];
      final location = '第 ${i + 1} 个事件';
      if (event.isCancelled) {
        skipped++;
        continue;
      }

      final title = event.summary.trim();
      if (title.isEmpty) {
        issues.add(ImportIssue('事件缺少标题（SUMMARY）', location: location));
        continue;
      }
      if (title.length > maxTitleLength) {
        issues.add(
          ImportIssue('课程名不能超过 $maxTitleLength 字', location: location),
        );
        continue;
      }

      final startDate = _tryParseDate(event.startDate);
      if (startDate == null) {
        issues.add(ImportIssue('上课日期无法识别（DTSTART）', location: location));
        continue;
      }

      // 课表事件必须有时刻：只有日期无法定位节次（全天日程不是课程）。
      final startTime = event.startTime;
      if (startTime == null) {
        skipped++;
        continue;
      }

      final meta = _parseDescription(event.description);
      final rrule = _Rrule.tryParse(event.rrule);

      // 节次：优先 DESCRIPTION 的显式标注（如「节次：5-8节」），否则用钟点
      // 就近换算。时间是外部日历经络，钟点未必与本校作息严格对齐（如
      // 「周三晚上 9-12 节」官方标注 17:50 开始），换算只是兜底。
      final startPeriod =
          meta.periods?.$1 ?? ClassPeriods.nearestStartPeriod(startTime);
      final endPeriod = meta.periods?.$2 ??
          (event.endTime == null
              ? startPeriod
              : ClassPeriods.nearestEndPeriod(
                  event.endTime!,
                  startPeriod: startPeriod,
                ));

      final (startWeek, endWeek) = _resolveWeeks(
        meta: meta,
        rrule: rrule,
      );
      if (startWeek == null || endWeek == null) {
        // 单次日程（无 RRULE、无周次标注）不是按周重复的课程。
        skipped++;
        continue;
      }

      final parity = _resolveParity(meta, rrule, startWeek);

      courses.add(
        CourseDraft(
          title: title,
          teacher: meta.teacher,
          location: event.location,
          weekday: startDate.weekday,
          startPeriod: startPeriod,
          endPeriod: endPeriod,
          startWeek: startWeek,
          endWeek: endWeek,
          weekParity: parity,
          category: meta.category,
          note: meta.note,
        ),
      );

      final candidate = week1MondayOf(startDate, startWeek);
      semesterCandidates.update(
        candidate,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    if (issues.isNotEmpty) return TimetableImportResult(issues: issues);
    if (courses.isEmpty) {
      return TimetableImportResult(
        issues: [
          ImportIssue(
            skipped > 0
              ? '没有可导入的课程：$skipped 个事件都是单次日程或缺少上课时刻'
              : '没有可导入的课程',
          ),
        ],
      );
    }

    return TimetableImportResult(
      courses: courses,
      semesterStart: _dominantKey(semesterCandidates),
      calendarName: calendar.name ?? fallbackName,
      skippedEvents: skipped,
    );
  }

  /// 教学周区间：优先 `周次：A-B 周`，其次由 `RRULE` 的 `COUNT` 推 1..COUNT。
  static (int?, int?) _resolveWeeks({
    required _DescriptionMeta meta,
    required _Rrule? rrule,
  }) {
    final explicit = meta.weeks;
    if (explicit != null) return explicit;
    final count = rrule?.count;
    if (count != null && count >= 1) {
      final capped = count > maxWeek ? maxWeek : count;
      return (1, capped);
    }
    return (null, null);
  }

  /// 单双周：`INTERVAL=2` 时由起始周的奇偶决定，否则看描述里的显式标注。
  static String _resolveParity(
    _DescriptionMeta meta,
    _Rrule? rrule,
    int startWeek,
  ) {
    if (meta.parity != null) return meta.parity!;
    final interval = rrule?.interval;
    if (interval != null && interval > 1) {
      // 每 N 周一次：以起始周为基准分奇偶（N=2 即单双周；更大的 N 无法用
      // 单双周表达，退化为起始周所在奇偶的那一半，至少不重复显示）。
      return startWeek.isOdd ? WeekParity.odd : WeekParity.even;
    }
    return WeekParity.all;
  }

  /// 由「首次上课日期 + 起始教学周」反推第 1 周周一（`yyyy-MM-dd`）。
  ///
  /// 首次上课日落在第 [startWeek] 周，故第 1 周周一 = 该周周一倒推
  /// `(startWeek − 1)` 周（不是正推——正推会得到课程的第 N 周，整学期
  /// 基准随之偏后）。例：首次上课 2026-09-15（周二）标注「2-18 周」，
  /// 所在周周一 09-14 倒推 1 周 = 09-07 = 第 1 周周一。
  static String week1MondayOf(DateTime firstClassDate, int startWeek) {
    final courseMonday = mondayOf(firstClassDate);
    final weeksBefore = (startWeek < 1 ? 1 : startWeek) - 1;
    return _formatDate(addLocalDays(courseMonday, -weeksBefore * 7));
  }

  /// 解析 `DESCRIPTION` 里的 `键：值` 约定，未识别的片段并入备注。
  static _DescriptionMeta _parseDescription(String? description) {
    if (description == null || description.trim().isEmpty) {
      return const _DescriptionMeta();
    }
    String? teacher;
    String? category;
    (int, int)? weeks;
    (int, int)? periods;
    String? parity;
    final extra = <String>[];

    for (final raw in description.split(RegExp(r'[｜|\n\r]'))) {
      final segment = raw.trim();
      if (segment.isEmpty) continue;
      final splitAt = _keyValueSplit(segment);
      if (splitAt <= 0) {
        extra.add(segment);
        continue;
      }
      final key = segment.substring(0, splitAt).trim();
      final value = segment.substring(splitAt + 1).trim();
      if (value.isEmpty) {
        extra.add(segment);
        continue;
      }
      switch (key) {
        case '教师':
        case '老师':
        case '任课教师':
          teacher ??= value;
        case '类别':
        case '课程类别':
          category ??= value;
        case '周次':
          weeks ??= _parseWeekRange(value);
          parity ??= _parityFromText(value);
        case '节次':
          periods ??= _parsePeriodRange(value);
        case '单双周':
          parity ??= _parityFromText(value);
        case '注':
        case '备注':
        case '说明':
          extra.add(value);
        default:
          extra.add(segment);
      }
    }

    return _DescriptionMeta(
      teacher: teacher,
      category: category,
      weeks: weeks,
      periods: periods,
      parity: parity,
      note: extra.isEmpty ? null : extra.join('\n'),
    );
  }

  /// 找 `：` 或 `:` 的分隔位置；都不存在返回 -1。
  static int _keyValueSplit(String segment) {
    final full = segment.indexOf('：');
    final half = segment.indexOf(':');
    if (full < 0) return half;
    if (half < 0) return full;
    return full < half ? full : half;
  }

  /// `11-18周` / `第2-18周` / `2~8` → (11, 18)。
  static (int, int)? _parseWeekRange(String value) {
    final match = RegExp(
      r'(\d{1,2})\s*[-~－—]\s*(\d{1,2})',
    ).firstMatch(value);
    if (match != null) {
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (!_validRange(start, end)) return null;
      return (start, end);
    }
    final single = RegExp(r'(\d{1,2})').firstMatch(value);
    if (single != null) {
      final week = int.parse(single.group(1)!);
      if (week < 1 || week > maxWeek) return null;
      return (week, week);
    }
    return null;
  }

  /// `5-8节` / `第9-12节` / `3-4` → (5, 8)。
  static (int, int)? _parsePeriodRange(String value) {
    final match = RegExp(
      r'(\d{1,2})\s*[-~－—]\s*(\d{1,2})',
    ).firstMatch(value);
    if (match != null) {
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (!ClassPeriods.hasPeriod(start) ||
          !ClassPeriods.hasPeriod(end) ||
          start > end) {
        return null;
      }
      return (start, end);
    }
    final single = RegExp(r'(\d{1,2})').firstMatch(value);
    if (single != null) {
      final period = int.parse(single.group(1)!);
      if (!ClassPeriods.hasPeriod(period)) return null;
      return (period, period);
    }
    return null;
  }

  /// 文本里的单双周标注：`单周`/`双周`（含 `11-18周（单周）` 这类后缀）。
  static String? _parityFromText(String value) {
    if (value.contains('单周')) return WeekParity.odd;
    if (value.contains('双周')) return WeekParity.even;
    if (value.contains('每周')) return WeekParity.all;
    return null;
  }

  static bool _validRange(int start, int end) =>
      start >= 1 && end <= maxWeek && start <= end;

  // ---------------------------------------------------------------- JSON

  TimetableImportResult _parseJson(String source, {String? fallbackName}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      return TimetableImportResult(
        issues: [ImportIssue('不是有效的 JSON 或 iCalendar：${e.message}')],
      );
    }

    final Map<String, Object?> root;
    if (decoded is Map<String, Object?>) {
      root = decoded;
    } else {
      return const TimetableImportResult(
        issues: [ImportIssue('课表 JSON 顶层应为对象（{...}）')],
      );
    }

    final rawCourses = root['courses'];
    if (rawCourses is! List) {
      return const TimetableImportResult(
        issues: [ImportIssue('课表 JSON 缺少 courses 数组')],
      );
    }

    final rawTimetable = root['timetable'];
    final timetable = rawTimetable is Map<String, Object?>
        ? rawTimetable
        : const <String, Object?>{};
    final semesterStart = _stringOf(
      timetable['semester_start'] ?? timetable['semesterStart'],
    );
    final name = _stringOf(timetable['name']) ?? fallbackName;

    final issues = <ImportIssue>[];
    final courses = <CourseDraft>[];
    for (var i = 0; i < rawCourses.length; i++) {
      final location = '第 ${i + 1} 门课';
      final item = rawCourses[i];
      if (item is! Map<String, Object?>) {
        issues.add(ImportIssue('应为课程对象', location: location));
        continue;
      }
      final draft = _courseFromJson(item, location, issues);
      if (draft != null) courses.add(draft);
    }

    if (issues.isNotEmpty) return TimetableImportResult(issues: issues);
    if (courses.isEmpty) {
      return const TimetableImportResult(
        issues: [ImportIssue('课表 JSON 里没有可导入的课程')],
      );
    }
    return TimetableImportResult(
      courses: courses,
      // 显式给出的学期基准优先，其次由首门课的日期反推（JSON 无日期时为空）。
      semesterStart: semesterStart,
      calendarName: name,
    );
  }

  static CourseDraft? _courseFromJson(
    Map<String, Object?> json,
    String location,
    List<ImportIssue> issues,
  ) {
    final title = _stringOf(json['title'] ?? json['name']);
    if (title == null || title.isEmpty) {
      issues.add(ImportIssue('缺少课程名（title）', location: location));
      return null;
    }
    if (title.length > maxTitleLength) {
      issues.add(
        ImportIssue('课程名不能超过 $maxTitleLength 字', location: location),
      );
      return null;
    }

    final weekday = _weekdayOf(json['weekday']);
    if (weekday == null) {
      issues.add(
        ImportIssue('星期几不合法（weekday 应为 1~7）', location: location),
      );
      return null;
    }

    final startPeriod = _intOf(json['start_period'] ?? json['startPeriod']);
    final endPeriod = _intOf(json['end_period'] ?? json['endPeriod']);
    if (!ClassPeriods.hasPeriod(startPeriod ?? 0) ||
        !ClassPeriods.hasPeriod(endPeriod ?? 0) ||
        startPeriod! > endPeriod!) {
      issues.add(
        ImportIssue(
          '节次不合法（应为 1~${ClassPeriods.count}，且起始不晚于结束）',
          location: location,
        ),
      );
      return null;
    }

    final startWeek = _intOf(json['start_week'] ?? json['startWeek']);
    final endWeek = _intOf(json['end_week'] ?? json['endWeek']);
    if (!_validRange(startWeek ?? 0, endWeek ?? 0)) {
      issues.add(
        ImportIssue('教学周不合法（应为 1~$maxWeek，且起始不晚于结束）',
            location: location),
      );
      return null;
    }

    final parity = _parityOf(json['week_parity'] ?? json['weekParity']);
    if (parity == null) {
      issues.add(
        ImportIssue('单双周取值不合法（应为 all/odd/even）', location: location),
      );
      return null;
    }

    return CourseDraft(
      title: title,
      teacher: _stringOf(json['teacher']),
      location: _stringOf(json['location']),
      weekday: weekday,
      startPeriod: startPeriod,
      endPeriod: endPeriod,
      startWeek: startWeek!,
      endWeek: endWeek!,
      weekParity: parity,
      category: _stringOf(json['category']),
      note: _stringOf(json['note']),
      color: _normalizeColor(_stringOf(json['color'])),
    );
  }

  /// 星期几：接受 1~7 整数。
  static int? _weekdayOf(Object? raw) {
    if (raw is num) {
      final value = raw.toInt();
      return value >= 1 && value <= 7 ? value : null;
    }
    return null;
  }

  /// 单双周：接受常量值或 `weekly`；缺失默认「每周」（[WeekParity.all]）。
  static String? _parityOf(Object? raw) {
    if (raw == null) return WeekParity.all;
    if (raw is! String) return null;
    final text = raw.trim().toLowerCase();
    switch (text) {
      case WeekParity.all:
      case 'weekly':
        return WeekParity.all;
      case WeekParity.odd:
        return WeekParity.odd;
      case WeekParity.even:
        return WeekParity.even;
      default:
        return null;
    }
  }

  static int? _intOf(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  static String? _stringOf(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 校验 `#RRGGBB` 配色；非法返回 null（由导入侧改用调色板分配）。
  static String? _normalizeColor(String? raw) {
    if (raw == null) return null;
    final text = raw.startsWith('#') ? raw : '#$raw';
    return RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text) ? text : null;
  }

  static DateTime? _tryParseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    final probe = DateTime(year, month, day);
    // DateTime 会把 2 月 30 日归一化为 3 月 2 日，回读校验拦下非法日期。
    if (probe.year != year || probe.month != month || probe.day != day) {
      return null;
    }
    return probe;
  }

  static String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// 取出现次数最多的键（同票取字典序最小，保证结果稳定可测）。
  static String? _dominantKey(Map<String, int> counts) {
    String? best;
    var bestCount = 0;
    final keys = counts.keys.toList()..sort();
    for (final key in keys) {
      final count = counts[key]!;
      if (count > bestCount) {
        best = key;
        bestCount = count;
      }
    }
    return best;
  }
}

/// `DESCRIPTION` 解析出的结构化字段。
class _DescriptionMeta {
  const _DescriptionMeta({
    this.teacher,
    this.category,
    this.weeks,
    this.periods,
    this.parity,
    this.note,
  });

  final String? teacher;
  final String? category;
  final (int, int)? weeks;
  final (int, int)? periods;
  final String? parity;
  final String? note;
}

/// 解析后的 `RRULE`（只取课表关心的三个参数）。
class _Rrule {
  const _Rrule({this.freq, this.count, this.interval});

  /// 频率（大写，如 `WEEKLY`）；无 `RRULE` 时为 null。
  final String? freq;

  /// 重复次数（`COUNT`）；无则 null。
  final int? count;

  /// 间隔周数（`INTERVAL`，缺省 1）。
  final int? interval;

  /// 解析 `FREQ=WEEKLY;COUNT=17;INTERVAL=2`；非 WEEKLY 规则返回 null
  /// （课表只按周重复，其它频率不作为课程导入）。
  static _Rrule? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    String? freq;
    int? count;
    int? interval;
    for (final segment in raw.split(';')) {
      final eq = segment.indexOf('=');
      if (eq <= 0) continue;
      final key = segment.substring(0, eq).trim().toUpperCase();
      final value = segment.substring(eq + 1).trim();
      switch (key) {
        case 'FREQ':
          freq = value.toUpperCase();
        case 'COUNT':
          count = int.tryParse(value);
        case 'INTERVAL':
          interval = int.tryParse(value);
      }
    }
    if (freq != 'WEEKLY') return null;
    return _Rrule(freq: freq, count: count, interval: interval);
  }
}
