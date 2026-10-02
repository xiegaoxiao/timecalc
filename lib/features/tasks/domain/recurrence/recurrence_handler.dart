import 'rule_param.dart';

/// 重复规则处理器接口（可扩展规则引擎的核心）。
///
/// 每种计划节奏（每天 / 每周指定星期 / 每隔 N 天 / 间隔序列…）实现本接口
/// 并注册进 [RecurrenceRuleRegistry]。规则始终以 ruleType + ruleJson
/// 存于数据库，新增类型无需 schema 变更。
abstract class RecurrenceRuleHandler {
  /// 规则类型标识（存于 RecurrenceTemplates.ruleType），如 daily / sequence。
  String get type;

  /// 中文名（规则类型选择按钮文案），如「每天」「间隔序列」。
  String get label;

  /// 参数 schema：配置对话框按此动态渲染表单。
  List<RuleParam> get params;

  /// 默认规则 JSON（新模板的初始参数）。
  Map<String, dynamic> defaultJson();

  /// 校验规则 JSON；合法返回 null，否则返回中文错误信息。
  String? validate(Map<String, dynamic> json);

  /// 生成 [startDate] 起、落在 [from]~[to]（含，yyyy-MM-dd）内的发生日。
  ///
  /// 结果为按日期升序的去重日期列表。由具体规则决定是否包含起始日当天
  /// （如间隔序列的第 1 次复习即起始日当天）。
  List<String> occurrences({
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  });
}
