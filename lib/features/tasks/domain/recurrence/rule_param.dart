/// 规则参数类型（驱动配置对话框动态渲染）。
enum RuleParamType {
  /// 单个整数（如每隔 N 天、起始时间）。
  intValue,

  /// 整数列表（如每周指定星期、间隔序列）。
  intList,
}

/// 规则参数描述：配置对话框按此渲染对应输入控件。
///
/// 新增规则类型时在 handler 中声明参数 schema，对话框自动适配，
/// 无需改动 UI 框架代码。
class RuleParam {
  const RuleParam({
    required this.key,
    required this.label,
    required this.type,
    this.defaultValue,
    this.defaultList,
    this.min,
    this.max,
    this.hint,
  });

  /// 规则 JSON 中的字段名（如 weekdays、everyNDays、offsets）。
  final String key;

  /// 配置对话框中的中文标签。
  final String label;
  final RuleParamType type;

  /// [intValue] 的默认值。
  final int? defaultValue;

  /// [intList] 的默认值（如艾宾浩斯序列 1,2,4,7,15,30）。
  final List<int>? defaultList;
  final int? min;
  final int? max;
  final String? hint;
}
