import 'builtin_recurrence_handlers.dart';
import 'recurrence_handler.dart';

/// 重复规则处理器注册表。
///
/// 规则类型到 handler 的映射。新增计划类型时实现 RecurrenceRuleHandler
/// 并调用 [register]，数据层、生成逻辑与配置表单自动适配。
class RecurrenceRuleRegistry {
  RecurrenceRuleRegistry() {
    register(DailyRecurrenceHandler());
    register(WeeklyRecurrenceHandler());
    register(IntervalRecurrenceHandler());
    register(SequenceRecurrenceHandler());
  }

  final Map<String, RecurrenceRuleHandler> _handlers = {};

  void register(RecurrenceRuleHandler handler) {
    _handlers[handler.type] = handler;
  }

  RecurrenceRuleHandler? handlerFor(String type) => _handlers[type];

  /// 全部已注册规则（顺序即配置对话框展示顺序）。
  List<RecurrenceRuleHandler> get all => _handlers.values.toList();

  /// 校验规则；未知类型或参数非法时返回中文错误，合法返回 null。
  String? validate({required String type, required Map<String, dynamic> json}) {
    final handler = _handlers[type];
    if (handler == null) return '未知的规则类型：$type';
    return handler.validate(json);
  }

  /// 生成发生日；未知类型返回空列表。
  List<String> occurrences({
    required String type,
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  }) {
    final handler = _handlers[type];
    if (handler == null) return const [];
    return handler.occurrences(
      json: json,
      startDate: startDate,
      from: from,
      to: to,
    );
  }
}
