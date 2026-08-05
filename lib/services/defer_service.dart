import 'package:intl/intl.dart';

/// 延期规则（FR-3.3）。
///
/// 纯 Dart service，不依赖数据库与 UI：
/// - 快捷操作默认延期至「下一可用日」；
/// - 可用日由计划偏好的每周可用星期决定；
/// - 返回严格晚于 [today] 的第一个可用日期。
class DeferService {
  const DeferService();

  /// 计算 [today] 之后的第一个可用日期（本地日历日期，yyyy-MM-dd）。
  ///
  /// [availableWeekdays] 为 ISO 星期集合（1=周一 … 7=周日）。
  /// 空集合视为全部可用（回退行为）。若 [today] 当天可用，仍返回下一天
  /// （延期语义：任务不会被推迟回今天）。
  String nextAvailableDate({
    required DateTime today,
    required Set<int> availableWeekdays,
  }) {
    final weekdays = availableWeekdays.isEmpty
        ? const {1, 2, 3, 4, 5, 6, 7}
        : availableWeekdays;

    var candidate = DateTime(today.year, today.month, today.day)
        .add(const Duration(days: 1));
    while (!weekdays.contains(_isoWeekday(candidate))) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return DateFormat('yyyy-MM-dd').format(candidate);
  }

  /// ISO 星期：DateTime.weekday（1=周一 … 7=周日）即为 ISO 值。
  static int _isoWeekday(DateTime date) => date.weekday;
}
