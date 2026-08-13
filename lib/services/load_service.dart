import '../core/database/database.dart';
import '../core/database/tables.dart';
import '../core/utils/date_text.dart';

/// 每日任务负载聚合结果（FR-3.4 日历展示）。
///
/// 统计规则：
/// - 总任务数与完成数按任务数计；
/// - 负载仅计「未完成任务预估时长之和」（FR-5.2），无预估时长的任务
///   不计入时长（FR-7.4）；
/// - 超出分钟数仅对计划偏好的可用星期生效；不可用日不产生「超出」徽标。
class DayAggregate {
  const DayAggregate({
    required this.totalCount,
    required this.doneCount,
    required this.loadMinutes,
    required this.overMinutes,
  });

  final int totalCount;
  final int doneCount;
  final int loadMinutes;
  final int overMinutes;

  /// 空（无任务）日保持中性：不视为过载或完成率 0%。
  bool get isEmpty => totalCount == 0;

  static const DayAggregate empty = DayAggregate(
    totalCount: 0,
    doneCount: 0,
    loadMinutes: 0,
    overMinutes: 0,
  );
}

/// 负载计算规则（FR-5.2 / FR-5.3 / FR-3.5 / FR-5.4）。
///
/// 纯 Dart service，不依赖数据库与 UI。
class LoadService {
  const LoadService();

  /// 某日未完成任务预估时长之和（FR-5.2）。
  ///
  /// [estimatedMinutes] 为空的任务不计入时长，只计入任务数。
  int dayLoad(List<Task> tasks) {
    return _sumTodoMinutes(tasks);
  }

  /// 超出可用时长的分钟数：`max(0, load - available)`（FR-3.5）。
  int overMinutes({required int load, required int available}) {
    return load > available ? load - available : 0;
  }

  /// 目标剩余工作量：全部未完成任务预估时长之和（FR-5.3）。
  int remainingMinutes(List<Task> tasks) => _sumTodoMinutes(tasks);

  /// 从 [today] 起到截止日（含）的剩余可用天数（FR-5.3）。
  ///
  /// [availableWeekdays] 为 ISO 星期集合；截止日已过返回 0。
  ///
  /// O(1)：按整周计算（`totalDays ~/ 7` 周 × 可用星期数），仅对余下不足
  /// 一周（≤6 天）逐日判断。旧版逐日循环在多年期目标下（如 4 年计划
  /// ≈ 1460 次迭代/卡）在 build 中反复执行，属不必要的 UI 隔离区开销。
  int remainingAvailableDays({
    required String deadlineDate,
    required DateTime today,
    required Set<int> availableWeekdays,
  }) {
    final deadline = parseLocalDate(deadlineDate);
    final start = DateTime(today.year, today.month, today.day);
    if (deadline.isBefore(start)) return 0;

    final weekdays = availableWeekdays.isEmpty
        ? const {1, 2, 3, 4, 5, 6, 7}
        : availableWeekdays;
    // UTC 归一化天数差：本地 difference().inDays 在夏令时切换日可能差一天
    // （M6/L3，与 statistics_service._dayDiff / countdown_service 同口径）。
    final totalDays = _dayDiff(deadline, start) + 1; // 含首尾
    var count = (totalDays ~/ 7) * weekdays.length;
    final remainder = totalDays % 7;
    var wd = start.weekday;
    for (var i = 0; i < remainder; i++) {
      if (weekdays.contains(wd)) count++;
      wd = wd == 7 ? 1 : wd + 1;
    }
    return count;
  }

  /// 建议日均时长 = 剩余时长 / 剩余可用天数（FR-5.3）。
  ///
  /// 可用天数为 0 时返回 0（无可用时间，由调用方决定提示）。
  int suggestedDailyMinutes({
    required int remainingMinutes,
    required int remainingDays,
  }) {
    if (remainingDays <= 0) return 0;
    return (remainingMinutes / remainingDays).ceil();
  }

  /// 计划风险：建议日均时长超过每日可用时长（FR-5.4）。
  bool hasPlanRisk({
    required int suggestedDailyMinutes,
    required int dailyAvailableMinutes,
  }) {
    return suggestedDailyMinutes > dailyAvailableMinutes;
  }

  /// 按日期聚合任务（FR-3.4 日历）。
  ///
  /// 返回以 `yyyy-MM-dd` 为键的聚合；[DayAggregate.empty] 统一表示无任务日。
  /// 超出分钟数仅对可用星期生效（不可用日置灰，不产生「超出」徽标）。
  Map<String, DayAggregate> calendarAggregate({
    required List<Task> tasks,
    required int availableMinutes,
    required Set<int> availableWeekdays,
  }) {
    final weekdays = availableWeekdays.isEmpty
        ? const {1, 2, 3, 4, 5, 6, 7}
        : availableWeekdays;

    final byDate = <String, List<Task>>{};
    for (final task in tasks) {
      byDate.putIfAbsent(task.plannedDate, () => []).add(task);
    }

    return {
      for (final entry in byDate.entries)
        entry.key: _aggregate(
          entry.value,
          availableMinutes: availableMinutes,
          weekdayAvailable: weekdays.contains(
            parseLocalDate(entry.key).weekday,
          ),
        ),
    };
  }

  DayAggregate _aggregate(
    List<Task> tasks, {
    required int availableMinutes,
    required bool weekdayAvailable,
  }) {
    var done = 0;
    var load = 0;
    for (final task in tasks) {
      if (task.status == TaskStatus.done) {
        done++;
      } else if (task.estimatedMinutes != null) {
        load += task.estimatedMinutes!;
      }
    }
    final over =
        weekdayAvailable ? overMinutes(load: load, available: availableMinutes) : 0;
    return DayAggregate(
      totalCount: tasks.length,
      doneCount: done,
      loadMinutes: load,
      overMinutes: over,
    );
  }

  int _sumTodoMinutes(List<Task> tasks) {
    var sum = 0;
    for (final task in tasks) {
      if (task.status != TaskStatus.done && task.estimatedMinutes != null) {
        sum += task.estimatedMinutes!;
      }
    }
    return sum;
  }

  /// 以「日历日」为单位计算 [a] - [b] 的天数（UTC 归一化，防 DST 偏差）。
  static int _dayDiff(DateTime a, DateTime b) {
    final aDay = DateTime.utc(a.year, a.month, a.day);
    final bDay = DateTime.utc(b.year, b.month, b.day);
    return aDay.difference(bDay).inDays;
  }
}
