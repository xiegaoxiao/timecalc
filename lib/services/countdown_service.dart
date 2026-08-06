import '../core/database/tables.dart';

/// 倒计时计算结果（FR-1.2 / FR-1.3）。
enum CountdownPhase {
  /// 截止日未到：显示「剩余 N 天」。
  upcoming,

  /// 截止日当天：显示「今天截止」。
  today,

  /// 截止日已过且目标未归档：显示「已逾期 N 天」。
  overdue,

  /// 目标已主动完成/放弃：停止倒计时显示。
  terminated,
}

/// 倒计时规则（FR-1.2 / FR-1.3）。
///
/// 纯 Dart service，不依赖数据库与 UI：
/// - 按本地日历日期计算，不按小时取整；
/// - 截止日当天显示「今天截止」；
/// - 已过且未归档显示「已逾期 N 天」；
/// - 已完成/已放弃停止逾期提醒。
class CountdownService {
  const CountdownService();

  /// 计算截止日相对 [today]（本地日期）的倒计时阶段与天数差。
  ///
  /// [deadlineDate] 为本地日历日期文本（yyyy-MM-dd）。
  /// [status] 为 GoalStatus；已完成/已放弃/已归档返回 terminated，且不计逾期
  /// （已归档目标如对历史记录，同样停止倒计时与逾期提醒）。
  (CountdownPhase, int days) evaluate({
    required String deadlineDate,
    required DateTime today,
    required String status,
  }) {
    final deadline = _parseDate(deadlineDate);
    if (status == GoalStatus.completed ||
        status == GoalStatus.abandoned ||
        status == GoalStatus.archived) {
      return (CountdownPhase.terminated, _dayDiff(deadline, today));
    }

    final diff = _dayDiff(deadline, today);
    if (diff > 0) return (CountdownPhase.upcoming, diff);
    if (diff == 0) return (CountdownPhase.today, 0);
    return (CountdownPhase.overdue, -diff);
  }

  /// 倒计时文案。依 UI 使用场景返回中文文案。
  static String label(CountdownPhase phase, int days) {
    switch (phase) {
      case CountdownPhase.upcoming:
        return '剩余 $days 天';
      case CountdownPhase.today:
        return '今天截止';
      case CountdownPhase.overdue:
        return '已逾期 $days 天';
      case CountdownPhase.terminated:
        return '已结束';
    }
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  /// 以「日历日」为单位计算 [a] - [b] 的天数。
  ///
  /// 用 UTC 构造纯日期避免 DST 造成 ±1 小时偏差导致的天数漂移。
  static int _dayDiff(DateTime a, DateTime b) {
    final aDay = DateTime.utc(a.year, a.month, a.day);
    final bDay = DateTime.utc(b.year, b.month, b.day);
    return aDay.difference(bDay).inDays;
  }
}
