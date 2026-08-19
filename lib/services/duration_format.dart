/// 时长展示格式化（分钟 → 中文「N 小时 M 分」）。
///
/// 纯 Dart，供任务条目、负载概览、日历格与负载区统一使用：
/// - 30  → '30 分'
/// - 60  → '1 小时'
/// - 90  → '1 小时 30 分'
/// - 120 → '2 小时'
class DurationFormat {
  const DurationFormat();

  /// 将分钟数转为人类可读时长文本。
  static String minutes(int minutes) {
    // 防御（审查 #16）：负数分钟（手工改库/导入反常值）不输出意义不明文案。
    if (minutes < 0) return '0 分';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '$rest 分';
    if (rest == 0) return '$hours 小时';
    return '$hours 小时 $rest 分';
  }
}
