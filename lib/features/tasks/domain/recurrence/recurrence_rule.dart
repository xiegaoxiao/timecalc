import 'dart:convert';

import 'recurrence_registry.dart';

/// 重复规则：ruleType（类型标识）+ ruleJson（参数 JSON 文本）。
///
/// 与数据库 RecurrenceTemplates.ruleType / ruleJson 一一对应；
/// 新增规则类型由 RecurrenceRuleRegistry 的 handler 解释，无需改本模型。
class RecurrenceRule {
  const RecurrenceRule({required this.ruleType, required this.ruleJson});

  final String ruleType;
  final String ruleJson;

  factory RecurrenceRule.fromMap({
    required String ruleType,
    required Map<String, dynamic> json,
  }) {
    return RecurrenceRule(
      ruleType: ruleType,
      ruleJson: jsonEncode(json),
    );
  }

  /// 解析参数 JSON；非法 JSON 返回空 map（由校验层兜底提示）。
  Map<String, dynamic> get jsonMap {
    try {
      final decoded = jsonDecode(ruleJson);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }

  /// 校验（委托 registry 对应 handler）；合法返回 null，否则返回中文错误。
  String? validateWith(RecurrenceRuleRegistry registry) {
    return registry.validate(type: ruleType, json: jsonMap);
  }
}
