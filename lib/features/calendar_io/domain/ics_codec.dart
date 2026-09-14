/// iCalendar（RFC 5545）子集编解码。
///
/// 只覆盖「把计划排进日历」所需的部分，刻意不实现完整标准：
/// - 解析：VCALENDAR 内的 VEVENT，取 UID / SUMMARY / DESCRIPTION /
///   LOCATION / STATUS / DTSTART / DTEND / DURATION；VTIMEZONE、VALARM、
///   VTODO 等其他组件一律忽略（不报错）；
/// - 序列化：每个任务/里程碑一个 VEVENT，全天用 `DTSTART;VALUE=DATE`，
///   有时刻用**浮动本地时间**（`DTSTART:20260805T203000`，不带 Z 也不带
///   TZID）——与库内 `plannedDate` + `startTime` 的「本地墙上时间」语义
///   完全一致：日历应用按本机时区显示，跨时区不漂移。
///
/// 纯 Dart，不依赖 Flutter 与数据库，可在 isolate 内运行。
library;

/// 一个日历事件（已归一化为本地日期 + 可选本地时刻）。
class IcsEvent {
  const IcsEvent({
    this.uid,
    required this.summary,
    this.description,
    this.location,
    required this.startDate,
    this.startTime,
    this.endDate,
    this.endTime,
    this.status,
    this.durationMinutes,
    this.rrule,
  });

  final String? uid;

  /// 标题（SUMMARY，已反转义）。
  final String summary;

  /// 描述（DESCRIPTION，已反转义）；无则 null。
  final String? description;

  final String? location;

  /// 开始日期（本地日历日 `yyyy-MM-dd`）。
  final String startDate;

  /// 开始时刻（本地墙上时间 `HH:mm`）；null 表示全天事件。
  final String? startTime;

  /// 结束日期；仅当 ICS 提供了 DTEND 且与开始日期不同时有值。
  final String? endDate;

  /// 结束时刻；null 表示未提供或有值但无法解析。
  final String? endTime;

  /// STATUS 原文（如 `CONFIRMED` / `CANCELLED`）；无则 null。
  final String? status;

  /// 由 DTEND−DTSTART 或 DURATION 推导的时长（分钟）；无法推导为 null。
  final int? durationMinutes;

  /// 原始 `RRULE` 文本（如 `FREQ=WEEKLY;COUNT=17`）；无则 null。
  ///
  /// 本 codec 不展开重复规则（任务/里程碑导出侧逐条实体化事件，展开无意义），
  /// 只把原文透传给调用方：课表导入需要 `FREQ=WEEKLY` 的 `COUNT`/`INTERVAL`
  /// 来还原教学周范围与单双周（见 features/timetable 的导入解析）。
  final String? rrule;

  /// 是否为全天事件（`VALUE=DATE` 或只有 8 位日期值）。
  bool get isAllDay => startTime == null;

  /// 是否已取消（导入时应跳过）。
  bool get isCancelled => status?.toUpperCase() == 'CANCELLED';
}

/// 解析出的日历（单个 VCALENDAR 文件）。
class IcsCalendar {
  const IcsCalendar({this.name, this.events = const []});

  /// 日历名（X-WR-CALNAME / NAME）；无则 null。
  final String? name;

  final List<IcsEvent> events;
}

/// iCalendar 文本 ↔ [IcsCalendar]。
class IcsCodec {
  const IcsCodec();

  /// 默认事件时长（分钟）：有时刻但既无 DTEND 也无 DURATION 时按 1 小时算，
  /// 避免导出的日历条目退化成零长度。
  static const int defaultEventMinutes = 60;

  static const String _prodid = '-//TimeCalc//TimeCalc 时间计算器//CN';

  // ---------------------------------------------------------------- 解析

  /// 解析 iCalendar 文本。找不到 VCALENDAR 组件时抛 [FormatException]。
  ///
  /// 容错策略：单行/单事件有问题不影响其余内容（解析不出 SUMMARY 或
  /// DTSTART 的 VEVENT 直接跳过），避免一个畸形条目导致整份日历不可用。
  IcsCalendar parse(String source) {
    final lines = _unfold(source);
    var sawCalendar = false;
    String? name;
    final events = <IcsEvent>[];

    // 当前正在收集的组件名（只关心 VEVENT）。
    String? component;
    var props = <String, _Property>{};

    void flushEvent() {
      final event = _buildEvent(props);
      if (event != null) events.add(event);
      props = <String, _Property>{};
    }

    for (final line in lines) {
      if (line.isEmpty) continue;
      final trimmed = line.trim();
      if (trimmed.toUpperCase() == 'BEGIN:VCALENDAR') {
        sawCalendar = true;
        continue;
      }
      if (trimmed.toUpperCase() == 'END:VCALENDAR') continue;
      if (trimmed.toUpperCase() == 'BEGIN:VEVENT') {
        component = 'VEVENT';
        props = <String, _Property>{};
        continue;
      }
      if (trimmed.toUpperCase() == 'END:VEVENT') {
        if (component == 'VEVENT') flushEvent();
        component = null;
        continue;
      }
      if (trimmed.toUpperCase().startsWith('BEGIN:')) {
        // 其他组件（VTIMEZONE/VALARM/VTODO…）：整段忽略。
        component = trimmed.substring(6).toUpperCase();
        continue;
      }
      if (trimmed.toUpperCase().startsWith('END:')) {
        component = null;
        continue;
      }

      final prop = _parseLine(line);
      if (prop == null) continue;
      if (component == null) {
        if (prop.name == 'X-WR-CALNAME' || prop.name == 'NAME') {
          name = prop.value.trim().isEmpty ? null : prop.value.trim();
        }
        continue;
      }
      if (component != 'VEVENT') continue;
      // 同名属性只取第一次（DTSTART 等不应重复；重复时以首个为准）。
      props.putIfAbsent(prop.name, () => prop);
    }

    if (!sawCalendar) {
      throw const FormatException('不是有效的 iCalendar 文件（缺少 BEGIN:VCALENDAR）');
    }
    return IcsCalendar(name: name, events: events);
  }

  /// 把物理行还原为逻辑行：RFC 5545 规定长行在 75 字节处折行，续行以
  /// 一个空格或制表符开头。
  static List<String> _unfold(String source) {
    final rawLines = source.split(RegExp(r'\r\n|\n|\r'));
    final result = <String>[];
    for (final line in rawLines) {
      if (line.isEmpty) continue;
      if ((line.startsWith(' ') || line.startsWith('\t')) &&
          result.isNotEmpty) {
        result[result.length - 1] = result.last + line.substring(1);
      } else {
        result.add(line);
      }
    }
    return result;
  }

  /// 解析一行属性：`NAME;PARAM=VALUE;PARAM2="a;b":VALUE`。
  static _Property? _parseLine(String line) {
    // 冒号分隔名与值：名称段内不含未转义的冒号（参数值可能带引号且含冒号）。
    var inQuotes = false;
    var splitAt = -1;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ':' && !inQuotes) {
        splitAt = i;
        break;
      }
    }
    if (splitAt <= 0) return null;
    final namePart = line.substring(0, splitAt);
    final value = line.substring(splitAt + 1);

    final segments = _splitTopLevel(namePart, ';');
    final name = segments.first.trim().toUpperCase();
    if (name.isEmpty) return null;
    final params = <String, String>{};
    for (final segment in segments.skip(1)) {
      final eq = segment.indexOf('=');
      if (eq <= 0) continue;
      final key = segment.substring(0, eq).trim().toUpperCase();
      var paramValue = segment.substring(eq + 1).trim();
      if (paramValue.length >= 2 &&
          paramValue.startsWith('"') &&
          paramValue.endsWith('"')) {
        paramValue = paramValue.substring(1, paramValue.length - 1);
      }
      params[key] = paramValue;
    }
    return _Property(name, params, value);
  }

  /// 按分隔符切分，但忽略双引号内的分隔符（参数值可含分号）。
  static List<String> _splitTopLevel(String input, String separator) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        buffer.write(ch);
      } else if (ch == separator && !inQuotes) {
        parts.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    parts.add(buffer.toString());
    return parts;
  }

  /// 由 VEVENT 属性构造 [IcsEvent]；缺少 SUMMARY 或 DTSTART 时返回 null。
  static IcsEvent? _buildEvent(Map<String, _Property> props) {
    final summaryProp = props['SUMMARY'];
    final summary = summaryProp == null
        ? ''
        : _unescapeText(summaryProp.value).trim();
    if (summary.isEmpty) return null;

    final startProp = props['DTSTART'];
    if (startProp == null) return null;
    final start = _parseDateValue(startProp);
    if (start == null) return null;

    final endProp = props['DTEND'];
    final end = endProp == null ? null : _parseDateValue(endProp);

    // 时长优先取 DURATION，其次由 DTEND − DTSTART 推导。
    int? durationMinutes = _parseDuration(props['DURATION']?.value);
    if (durationMinutes == null && end != null && end.dateTime != null) {
      final startDt = start.dateTime;
      if (startDt != null) {
        final minutes = end.dateTime!.difference(startDt).inMinutes;
        if (minutes > 0) durationMinutes = minutes;
      }
    }

    final statusProp = props['STATUS'];
    final descriptionProp = props['DESCRIPTION'];
    final locationProp = props['LOCATION'];
    final rruleProp = props['RRULE'];

    return IcsEvent(
      uid: props['UID']?.value.trim(),
      summary: summary,
      description: descriptionProp == null
          ? null
          : _nullIfBlank(_unescapeText(descriptionProp.value)),
      location: locationProp == null
          ? null
          : _nullIfBlank(_unescapeText(locationProp.value)),
      startDate: start.date,
      startTime: start.time,
      endDate: end?.date,
      endTime: end?.time,
      status: statusProp?.value.trim().toUpperCase(),
      durationMinutes: durationMinutes,
      rrule: rruleProp == null ? null : _nullIfBlank(rruleProp.value),
    );
  }

  static String? _nullIfBlank(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 解析 `DTSTART`/`DTEND` 的值：`YYYYMMDD`（全天）或
  /// `YYYYMMDDTHHMMSS`（浮动本地）/ 带 `Z`（UTC，转本地）。
  ///
  /// `TZID=` 参数被忽略——本应用不内置时区数据库，把带 TZID 的时刻按
  /// 「该墙上时间即为本地时间」处理（与导出侧的浮动本地时间对称）。
  static _DateValue? _parseDateValue(_Property prop) {
    final raw = prop.value.trim().toUpperCase();
    final isDateOnly = prop.params['VALUE'] == 'DATE' || raw.length == 8;

    if (isDateOnly) {
      final date = _parseBasicDate(raw);
      return date == null ? null : _DateValue(date, null);
    }

    // YYYYMMDDTHHMMSS[Z]（秒可省略）。
    final match = RegExp(
      r'^(\d{8})T(\d{2})(\d{2})(\d{2})?(Z)?$',
    ).firstMatch(raw);
    if (match == null) {
      final date = _parseBasicDate(raw);
      return date == null ? null : _DateValue(date, null);
    }
    final date = _parseBasicDate(match.group(1)!);
    if (date == null) return null;
    final hour = int.parse(match.group(2)!);
    final minute = int.parse(match.group(3)!);
    if (hour > 23 || minute > 59) return null;
    final isUtc = match.group(5) == 'Z';

    var dateText = date;
    var timeText =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    if (isUtc) {
      // UTC 值转本机时区后取日期与钟点（跨日时日期也随之移动）。
      final parts = date.split('-');
      final local = DateTime.utc(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
        hour,
        minute,
      ).toLocal();
      dateText =
          '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      timeText =
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return _DateValue(dateText, timeText);
  }

  /// `YYYYMMDD` → `yyyy-MM-dd`；非法日期返回 null。
  static String? _parseBasicDate(String value) {
    if (!RegExp(r'^\d{8}$').hasMatch(value)) return null;
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(4, 6));
    final day = int.parse(value.substring(6, 8));
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    // DateTime 溢出归一化（2 月 30 日 → 3 月 2 日）回读校验拦截非法日期。
    final probe = DateTime(year, month, day);
    if (probe.year != year || probe.month != month || probe.day != day) {
      return null;
    }
    return '${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}';
  }

  /// 解析 DURATION（如 `PT90M`、`PT1H30M`、`P1D`、`-PT15M`）；失败返回 null。
  static int? _parseDuration(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
    ).firstMatch(value.trim().toUpperCase());
    if (match == null) return null;
    final weeks = int.tryParse(match.group(2) ?? '') ?? 0;
    final days = int.tryParse(match.group(3) ?? '') ?? 0;
    final hours = int.tryParse(match.group(4) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(5) ?? '') ?? 0;
    final total = weeks * 7 * 24 * 60 + days * 24 * 60 + hours * 60 + minutes;
    // 负时长（`-PT15M`）与不足 1 分钟的时长对「预估时长」没有意义，按无效处理。
    if (match.group(1) == '-' || total <= 0) return null;
    return total;
  }

  /// 反转义 TEXT 值：`\\n`/`\\N` → 换行，`\\,` → `,`，`\\;` → `;`，
  /// `\\\\` → `\`。
  static String _unescapeText(String value) {
    final buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch != r'\' || i + 1 >= value.length) {
        buffer.write(ch);
        continue;
      }
      final next = value[i + 1];
      switch (next) {
        case 'n':
        case 'N':
          buffer.write('\n');
          i++;
        case ',':
          buffer.write(',');
          i++;
        case ';':
          buffer.write(';');
          i++;
        case r'\':
          buffer.write(r'\');
          i++;
        default:
          buffer.write(ch);
      }
    }
    return buffer.toString();
  }

  /// 转义 TEXT 值（序列化用）：反斜杠、分号、逗号、换行。
  static String _escapeText(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,')
        .replaceAll('\r\n', r'\n')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\n');
  }

  // ---------------------------------------------------------------- 序列化

  /// 序列化日历为 iCalendar 文本（CRLF 换行、75 字节折行）。
  String serialize(IcsCalendar calendar, {DateTime? stamp}) {
    final now = (stamp ?? DateTime.now()).toUtc();
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:$_prodid',
      'CALSCALE:GREGORIAN',
      if (calendar.name != null && calendar.name!.trim().isNotEmpty)
        'X-WR-CALNAME:${_escapeText(calendar.name!.trim())}',
    ];

    for (final event in calendar.events) {
      lines.addAll(_eventLines(event, now));
    }
    lines.add('END:VCALENDAR');
    final folded = lines.map(_foldLine).join('\r\n');
    // RFC 5545：内容行以 CRLF 结尾（文件末尾同样补一个，兼容严格解析器）。
    return '$folded\r\n';
  }

  static List<String> _eventLines(IcsEvent event, DateTime stamp) {
    final lines = <String>[
      'BEGIN:VEVENT',
      if (event.uid != null && event.uid!.isNotEmpty) 'UID:${event.uid}',
      'DTSTAMP:${_formatUtcStamp(stamp)}',
      _formatDateProperty('DTSTART', event.startDate, event.startTime),
    ];

    // 全天事件不写 DTEND（RFC 中 DTEND 为排他上界，整天事件的排他上界
    // 语义容易与「当天截止」混淆；缺省即一天，各日历应用均按单日处理）。
    if (event.startTime != null) {
      final end = _resolveEnd(event);
      if (end != null) {
        lines.add(_formatDateProperty('DTEND', end.$1, end.$2));
      }
    }

    lines
      ..add('SUMMARY:${_escapeText(event.summary)}')
      ..add('STATUS:${event.status ?? 'CONFIRMED'}');
    if (event.description != null && event.description!.trim().isNotEmpty) {
      lines.add('DESCRIPTION:${_escapeText(event.description!)}');
    }
    if (event.location != null && event.location!.trim().isNotEmpty) {
      lines.add('LOCATION:${_escapeText(event.location!)}');
    }
    lines.add('END:VEVENT');
    return lines;
  }

  /// 由 startTime + 显式 endTime/durationMinutes 推导 DTEND。
  ///
  /// 优先用 [IcsEvent.endTime]（同一天时），否则按
  /// [IcsEvent.durationMinutes]（缺省 [defaultEventMinutes]）推算，
  /// 跨天时日期一并进位。
  static (String, String?)? _resolveEnd(IcsEvent event) {
    final startTime = event.startTime;
    if (startTime == null) return null;
    if (event.endTime != null && event.endDate == null) {
      return (event.startDate, event.endTime);
    }
    final startMinutes = _minutesOf(startTime);
    if (startMinutes == null) return null;
    final duration = event.durationMinutes ?? defaultEventMinutes;
    final total = startMinutes + duration;
    final date = event.startDate;
    if (total < 24 * 60) {
      return (date, _formatMinutes(total));
    }
    // 跨天：结束日期进位（纯日历加法，避免 Duration 在夏令时日的偏移）。
    final parts = date.split('-');
    final next = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]) + total ~/ (24 * 60),
    );
    return (
      '${next.year.toString().padLeft(4, '0')}-'
          '${next.month.toString().padLeft(2, '0')}-'
          '${next.day.toString().padLeft(2, '0')}',
      _formatMinutes(total % (24 * 60)),
    );
  }

  static int? _minutesOf(String hhmm) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(hhmm);
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static String _formatMinutes(int minutes) {
    final hh = (minutes ~/ 60).toString().padLeft(2, '0');
    final mm = (minutes % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// `DTSTART;VALUE=DATE:20260805` 或 `DTSTART:20260805T203000`。
  ///
  /// RFC 5545 的 DATE-TIME 必须是 `YYYYMMDDTHHMMSS`（秒不可省略），
  /// 库里只存到分钟，补 `00` 秒。
  static String _formatDateProperty(String name, String date, String? time) {
    final basic = date.replaceAll('-', '');
    if (time == null) return '$name;VALUE=DATE:$basic';
    final basicTime = '${time.replaceAll(':', '')}00';
    return '$name:${basic}T$basicTime';
  }

  /// UTC 时间戳 `yyyyMMddTHHmmssZ`。
  static String _formatUtcStamp(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final mo = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    final h = utc.hour.toString().padLeft(2, '0');
    final mi = utc.minute.toString().padLeft(2, '0');
    final s = utc.second.toString().padLeft(2, '0');
    return '$y$mo${d}T$h$mi${s}Z';
  }

  /// RFC 5545 折行：每行不超过 75 **字节**（UTF-8），续行以单个空格开头。
  ///
  /// 中文标题一个字 3 字节，必须按字节而非字符计数，否则生成的行会超出
  /// 限制，部分日历应用解析失败。
  static String _foldLine(String line) {
    if (_utf8Length(line) <= 75) return line;
    final buffer = StringBuffer();
    var byteCount = 0;
    var first = true;
    for (final rune in line.runes) {
      final chunk = String.fromCharCode(rune);
      final chunkBytes = _utf8Length(chunk);
      // 续行首字节留给行首空格。
      final limit = first ? 75 : 74;
      if (byteCount + chunkBytes > limit) {
        buffer.write('\r\n ');
        byteCount = 0;
        first = false;
      }
      buffer.write(chunk);
      byteCount += chunkBytes;
    }
    return buffer.toString();
  }

  /// 字符串的 UTF-8 字节数（不引入 dart:convert 的编码开销）。
  static int _utf8Length(String value) {
    var bytes = 0;
    for (final rune in value.runes) {
      if (rune <= 0x7F) {
        bytes += 1;
      } else if (rune <= 0x7FF) {
        bytes += 2;
      } else if (rune <= 0xFFFF) {
        bytes += 3;
      } else {
        bytes += 4;
      }
    }
    return bytes;
  }
}

/// 一行属性：名称 + 参数 + 原始值。
class _Property {
  const _Property(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;
}

/// 解析出的日期/时刻值。
class _DateValue {
  const _DateValue(this.date, this.time);

  final String date;
  final String? time;

  DateTime? get dateTime {
    final time = this.time;
    if (time == null) return null;
    final parts = date.split('-');
    final timeParts = time.split(':');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
      int.parse(timeParts[0]),
      int.parse(timeParts[1]),
    );
  }
}
