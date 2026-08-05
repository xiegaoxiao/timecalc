/// 预估时长校验（FR-3 验收：仅接受 1～1440 分钟整数）。
///
/// 纯 Dart 校验规则，UI 与测试共用。
abstract final class DurationValidator {
  static const int minMinutes = 1;
  static const int maxMinutes = 1440;

  /// 返回 null 表示合法；否则返回错误提示文案。
  static String? validate(String? input) {
    if (input == null || input.trim().isEmpty) {
      return '请输入预估时长';
    }
    final value = int.tryParse(input.trim());
    if (value == null) {
      return '请输入 1～1440 之间的整数';
    }
    if (value < minMinutes || value > maxMinutes) {
      return '请输入 1～1440 之间的整数';
    }
    return null;
  }
}
