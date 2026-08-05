import 'recurrence_handler.dart';
import 'rule_param.dart';

/// 内置规则处理器集合。
///
/// 新增计划类型 = 新增一个 RecurrenceRuleHandler 实现并 register，
/// 数据层、生成逻辑与配置表单自动适配，无需改动框架代码。

/// 每天重复（无参数）。
class DailyRecurrenceHandler extends RecurrenceRuleHandler {
  @override
  String get type => 'daily';
  @override
  String get label => '每天';
  @override
  List<RuleParam> get params => const [];
  @override
  Map<String, dynamic> defaultJson() => const {};
  @override
  String? validate(Map<String, dynamic> json) => null;

  @override
  List<String> occurrences({
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  }) {
    return _dailyDates(startDate, from, to);
  }
}

/// 每周指定星期重复。
class WeeklyRecurrenceHandler extends RecurrenceRuleHandler {
  @override
  String get type => 'weekly';
  @override
  String get label => '每周指定星期';
  @override
  List<RuleParam> get params => const [
        RuleParam(
          key: 'weekdays',
          label: '每周哪些天',
          type: RuleParamType.intList,
          defaultList: [1, 3, 5], // 周一三五
          min: 1,
          max: 7,
        ),
      ];
  @override
  Map<String, dynamic> defaultJson() => const {'weekdays': [1, 3, 5]};

  @override
  String? validate(Map<String, dynamic> json) {
    final weekdays = _asIntList(json['weekdays']);
    if (weekdays == null || weekdays.isEmpty) return '请至少选择一个星期';
    if (weekdays.any((d) => d < 1 || d > 7)) return '星期必须在 1～7 之间';
    return null;
  }

  @override
  List<String> occurrences({
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  }) {
    final weekdays = (_asIntList(json['weekdays']) ?? const []).toSet();
    final out = <String>[];
    var cursor = _parse(startDate);
    final fromD = _parse(from);
    final toD = _parse(to);
    while (!cursor.isAfter(toD)) {
      if (!cursor.isBefore(fromD) && weekdays.contains(cursor.weekday)) {
        out.add(_format(cursor));
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return out;
  }
}

/// 每隔 N 天重复（固定间隔）。
class IntervalRecurrenceHandler extends RecurrenceRuleHandler {
  @override
  String get type => 'interval';
  @override
  String get label => '每隔 N 天';
  @override
  List<RuleParam> get params => const [
        RuleParam(
          key: 'everyNDays',
          label: '间隔天数',
          type: RuleParamType.intValue,
          defaultValue: 1,
          min: 1,
          max: 365,
        ),
      ];
  @override
  Map<String, dynamic> defaultJson() => const {'everyNDays': 1};

  @override
  String? validate(Map<String, dynamic> json) {
    final n = json['everyNDays'];
    if (n is! int) return '间隔天数必须是整数';
    if (n < 1 || n > 365) return '间隔天数必须在 1～365 之间';
    return null;
  }

  @override
  List<String> occurrences({
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  }) {
    final n = json['everyNDays'];
    if (n is! int) return const [];
    final out = <String>[];
    var cursor = _parse(startDate);
    final fromD = _parse(from);
    final toD = _parse(to);
    while (!cursor.isAfter(toD)) {
      if (!cursor.isBefore(fromD)) out.add(_format(cursor));
      cursor = cursor.add(Duration(days: n));
    }
    return out;
  }
}

/// 间隔序列重复（艾宾浩斯等自定义复习节奏）。
///
/// 第 1 次（复习/使用）发生在起始日当天；此后第 n 次发生在起始日 + 前 n-1
/// 项累计天数。序列按天计算（任务按日计划，同一天不产生多条同内容实例）。
class SequenceRecurrenceHandler extends RecurrenceRuleHandler {
  @override
  String get type => 'sequence';
  @override
  String get label => '间隔序列';
  @override
  List<RuleParam> get params => const [
        RuleParam(
          key: 'offsets',
          label: '间隔天数序列',
          type: RuleParamType.intList,
          // 艾宾浩斯复习节点：第 1、2、4、7、15、30 天复习。
          defaultList: [1, 2, 4, 7, 15, 30],
          min: 1,
          max: 365,
          hint: '逗号分隔的正整数；如艾宾浩斯 1,2,4,7,15,30',
        ),
      ];
  @override
  Map<String, dynamic> defaultJson() => const {'offsets': [1, 2, 4, 7, 15, 30]};

  @override
  String? validate(Map<String, dynamic> json) {
    final offsets = _asIntList(json['offsets']);
    if (offsets == null || offsets.isEmpty) return '请输入至少一个间隔天数';
    if (offsets.any((d) => d < 1 || d > 365)) {
      return '间隔天数必须在 1～365 之间';
    }
    return null;
  }

  @override
  List<String> occurrences({
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  }) {
    final offsets = _asIntList(json['offsets']);
    final start = _parse(startDate);
    final fromD = _parse(from);
    final toD = _parse(to);
    final out = <String>[];

    // 第 1 次 = 起始日当天。
    if (!start.isBefore(fromD) && !start.isAfter(toD)) {
      out.add(_format(start));
    }

    // 参数非法（如非 int 列表）时不产生后续发生日，仅保留起始日。
    if (offsets == null) return out;

    var cumulative = 0;
    for (final offset in offsets) {
      cumulative += offset;
      final date = start.add(Duration(days: cumulative));
      if (date.isBefore(fromD)) continue;
      if (date.isAfter(toD)) break;
      out.add(_format(date));
    }
    return out;
  }
}

/// 从 [from] 起逐日生成到 [to]（含），供 daily 规则复用。
List<String> _dailyDates(String startDate, String from, String to) {
  final out = <String>[];
  var cursor = _parse(startDate);
  final fromD = _parse(from);
  final toD = _parse(to);
  while (!cursor.isAfter(toD)) {
    if (!cursor.isBefore(fromD)) out.add(_format(cursor));
    cursor = cursor.add(const Duration(days: 1));
  }
  return out;
}

/// 把 JSON 参数值安全解析为 int 列表；非 List 或含非 int 元素返回 null
/// （避免 `as int` 抛 TypeError，由调用方决定回退/报错）。
List<int>? _asIntList(Object? value) {
  if (value is! List) return null;
  final out = <int>[];
  for (final element in value) {
    if (element is! int) return null;
    out.add(element);
  }
  return out;
}

DateTime _parse(String yyyyMMdd) {
  final parts = yyyyMMdd.split('-');
  return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

String _format(DateTime date) {
  final mm = date.month.toString().padLeft(2, '0');
  final dd = date.day.toString().padLeft(2, '0');
  return '${date.year}-$mm-$dd';
}
