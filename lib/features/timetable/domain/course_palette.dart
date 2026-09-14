/// 课程配色板（FR-10 课表）。
///
/// 课程卡片的颜色只作为**强调色**使用（左侧 3px 竖条 + 淡色底纹），文字仍走
/// 主题前景色，因此配色板只需要「彼此可区分」而不必逐个校验对比度——这也是
/// 色值以 `#RRGGBB` 文本入库（同 Subjects.color）而不是存主题色的原因：
/// 配色随课程走，不随浅色/深色主题漂移。
///
/// 纯 Dart（不依赖 Flutter），导入与新建共用同一份取值，保证「同一份课表
/// 导入两次得到同样的配色」。
library;

abstract final class CoursePalette {
  /// 可选配色（8 色，色相彼此拉开，浅底/深底都能辨认竖条）。
  static const List<String> hexes = [
    '#3F6C51', // 品牌深绿
    '#2F6F9F', // 蓝
    '#B0523F', // 陶红
    '#7A4E9E', // 紫
    '#2E7D7A', // 青
    '#9A7B24', // 金
    '#8A5A2B', // 棕
    '#5A6B84', // 石板蓝
  ];

  /// 默认配色（新建表单未选色、备份恢复缺色时的兜底）。
  static const String defaultHex = '#3F6C51';

  /// 按序取色（[index] 任意整数，负数也能安全回绕）。
  static String at(int index) {
    final normalized = index % hexes.length;
    return hexes[normalized < 0 ? normalized + hexes.length : normalized];
  }

  /// 是否为合法 `#RRGGBB` 文本。
  static bool isValid(String hex) =>
      RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex);
}
