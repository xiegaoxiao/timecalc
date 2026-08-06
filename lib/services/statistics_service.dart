import '../core/database/database.dart';
import '../core/database/tables.dart';

/// 某日完成统计（FR-7.1）。
class DayCompletionStats {
  const DayCompletionStats({
    required this.totalCount,
    required this.doneCount,
    required this.doneMinutes,
  });

  final int totalCount;
  final int doneCount;
  final int doneMinutes;

  static const DayCompletionStats empty = DayCompletionStats(
    totalCount: 0,
    doneCount: 0,
    doneMinutes: 0,
  );
}

/// 进度统计规则（FR-7.1 / FR-7.2 / FR-7.4）。
///
/// 纯 Dart service，不依赖数据库与 UI。
///
/// 热力图口径（M3 决策）：按「完成日期」统计完成任务数量——任务完成时
/// 记录 completedAt（UTC），换算为本地日历日期后归入当天，反映每天真正
/// 完成的工作量；延期完成的任务显示在实际完成的那天。
class StatisticsService {
  const StatisticsService();

  /// 按完成日期（本地 yyyy-MM-dd）统计完成任务数量（FR-7.2 热力图数据）。
  ///
  /// 仅统计已完成（status=done）且记录完成时间的任务；completedAt 为 null
  /// 或已归档任务不计。返回以 `yyyy-MM-dd` 为键的数量映射，无完成记录
  /// 的日期不出现在映射中。
  Map<String, int> completedCountsByLocalDate(List<Task> tasks) {
    final counts = <String, int>{};
    for (final task in tasks) {
      if (task.status != TaskStatus.done) continue;
      final completedAt = task.completedAt;
      if (completedAt == null) continue;
      final local = completedAt.toLocal();
      final key = _formatDate(local);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  /// 单日完成概览（FR-7.1）：完成数 / 总数 / 已完成任务预估时长之和。
  ///
  /// 无预估时长的任务只计入任务数，不计入时长（FR-7.4）。
  DayCompletionStats completionStats(List<Task> dayTasks) {
    var done = 0;
    var doneMinutes = 0;
    for (final task in dayTasks) {
      if (task.status == TaskStatus.done) {
        done++;
        final minutes = task.estimatedMinutes;
        if (minutes != null) doneMinutes += minutes;
      }
    }
    return DayCompletionStats(
      totalCount: dayTasks.length,
      doneCount: done,
      doneMinutes: doneMinutes,
    );
  }

  /// 目标剩余工作量：全部未完成任务预估时长之和（FR-5.3 / FR-7.1）。
  ///
  /// 无预估时长的任务不计入时长，只计入任务数（FR-7.4）。
  int remainingMinutes(List<Task> tasks) {
    var sum = 0;
    for (final task in tasks) {
      if (task.status != TaskStatus.done && task.estimatedMinutes != null) {
        sum += task.estimatedMinutes!;
      }
    }
    return sum;
  }

  /// 热力图强度分桶（GitHub 风格五档）。
  ///
  /// 0 项 → 0；1-2 项 → 1；3-5 项 → 2；6-8 项 → 3；9+ 项 → 4。
  static int heatLevel(int count) {
    if (count <= 0) return 0;
    if (count <= 2) return 1;
    if (count <= 5) return 2;
    if (count <= 8) return 3;
    return 4;
  }

  /// 最近 [weeks] 周（默认 26）的「周起始日」列表。
  ///
  /// 周从周一开始（与日历视图一致）。返回的列表按时间升序排列，
  /// 最后一项是包含 [today] 那一周的周一。
  static List<DateTime> recentWeekStarts(DateTime today, {int weeks = 26}) {
    final day = DateTime(today.year, today.month, today.day);
    final thisWeekStart = day.subtract(Duration(days: day.weekday - 1));
    return List.generate(weeks, (i) {
      return thisWeekStart.subtract(Duration(days: (weeks - 1 - i) * 7));
    });
  }

  static String _formatDate(DateTime local) {
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd';
  }
}
