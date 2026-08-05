import '../features/tasks/domain/recurrence/recurrence_rule.dart';
import '../features/tasks/domain/recurrence/recurrence_registry.dart';

/// 重复规则服务（可扩展规则引擎的门面）。
///
/// 纯 Dart，不依赖数据库与 UI。规则解释委托给 [RecurrenceRuleRegistry]
/// 中的 handler：新增规则类型只需注册 handler，本服务无需改动。
class RecurrenceService {
  RecurrenceService({RecurrenceRuleRegistry? registry})
      : _registry = registry ?? RecurrenceRuleRegistry();

  final RecurrenceRuleRegistry _registry;

  /// 规则类型选择项（中文名）。
  List<String> get ruleTypeLabels => _registry.all.map((h) => h.label).toList();

  /// 校验规则；合法返回 null，否则返回中文错误信息。
  String? validate(RecurrenceRule rule) => rule.validateWith(_registry);

  /// 校验「类型 + 参数」；合法返回 null，否则返回中文错误信息。
  String? validateRaw(String ruleType, Map<String, dynamic> json) {
    return _registry.validate(type: ruleType, json: json);
  }

  /// 生成 [startDate] 起、[from]~[to]（含，yyyy-MM-dd）内的发生日。
  ///
  /// [from]/[to] 缺省时默认 [from]=startDate、[to]=startDate+30 天
  /// （FR-4.3 未来 30 天窗口）。未知类型返回空列表。
  List<String> occurrences({
    required String ruleType,
    required Map<String, dynamic> json,
    required String startDate,
    String? from,
    String? to,
  }) {
    final effectiveFrom = from ?? startDate;
    final effectiveTo = to ?? _plusDays(startDate, 30);
    return _registry.occurrences(
      type: ruleType,
      json: json,
      startDate: startDate,
      from: effectiveFrom,
      to: effectiveTo,
    );
  }

  static String _plusDays(String yyyyMMdd, int days) {
    final parts = yyyyMMdd.split('-');
    final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]))
        .add(Duration(days: days));
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }
}
