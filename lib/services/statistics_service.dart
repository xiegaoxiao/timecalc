import '../core/database/database.dart';
import '../core/database/tables.dart';
import '../core/utils/date_text.dart';

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

/// 目标在甘特图某窗口各周的时长数据（计划 vs 完成）。
class GoalGanttRow {
  const GoalGanttRow({required this.planned, required this.completed});

  /// 每周计划时长（分钟）：未完成任务按计划日期归周。
  final List<int> planned;

  /// 每周完成时长（分钟）：已完成任务按完成日期归周。
  final List<int> completed;

  /// 该目标在窗口内是否有任何数据（计划或完成）。
  bool get hasData {
    return planned.any((m) => m > 0) || completed.any((m) => m > 0);
  }
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

  /// 热力图强度分桶（LeetCode 官方五档，FR-7.2）。
  ///
  /// 0 项 → 0；1-3 项 → 1；4-6 项 → 2；7-9 项 → 3；10+ 项 → 4。
  static int heatLevel(int count) {
    if (count <= 0) return 0;
    if (count <= 3) return 1;
    if (count <= 6) return 2;
    if (count <= 9) return 3;
    return 4;
  }

  /// 甘特图窗口：过去 [pastWeeks] 个完整周 + 当前周 + 未来 [futureWeeks] 周
  /// （默认共 26 周），让用户能同时看到历史完成与未来计划。
  ///
  /// 周从周一开始（与热力图一致）。返回的列表按时间升序，当前周位于
  /// `pastWeeks` 下标处。
  static List<DateTime> ganttWeekStarts(
    DateTime today, {
    int pastWeeks = 12,
    int futureWeeks = 13,
  }) {
    final day = DateTime(today.year, today.month, today.day);
    // 纯日历加法（date_text）：Duration(days:) 在夏令时切换日偏移一小时，
    // 周起点/窗口端点可能落到相邻日期，导致归周错位。
    final thisWeekStart = addLocalDays(day, -(day.weekday - 1));
    return List.generate(pastWeeks + 1 + futureWeeks, (i) {
      return addLocalDays(thisWeekStart, -(pastWeeks - i) * 7);
    });
  }

  /// 每个目标在 [weekStarts] 各周内的「计划时长」与「完成时长」（甘特图）。
  ///
  /// - 计划时长：未完成任务按计划日期（plannedDate）归入所在周；
  /// - 完成时长：已完成任务按完成日期（completedAt）归入所在周；
  /// - 无预估时长的任务不计入（FR-7.4），窗口外的任务忽略。
  Map<int, GoalGanttRow> goalGanttData({
    required List<Task> todoTasks,
    required List<Task> completedTasks,
    required List<DateTime> weekStarts,
  }) {
    final byGoal = <int, GoalGanttRow>{};

    GoalGanttRow rowFor(int goalId) => byGoal.putIfAbsent(
          goalId,
          () => GoalGanttRow(
            planned: List.filled(weekStarts.length, 0),
            completed: List.filled(weekStarts.length, 0),
          ),
        );

    for (final task in todoTasks) {
      final minutes = task.estimatedMinutes;
      if (minutes == null) continue;
      final weekIndex = _weekIndexOf(DateTime.parse(task.plannedDate), weekStarts);
      if (weekIndex == null) continue;
      rowFor(task.goalId).planned[weekIndex] += minutes;
    }

    for (final task in completedTasks) {
      if (task.status != TaskStatus.done) continue;
      final minutes = task.estimatedMinutes;
      final completedAt = task.completedAt;
      if (minutes == null || completedAt == null) continue;
      final weekIndex = _weekIndexOf(completedAt.toLocal(), weekStarts);
      if (weekIndex == null) continue;
      rowFor(task.goalId).completed[weekIndex] += minutes;
    }

    return byGoal;
  }

  /// [date]（本地日历日期）落在 [weekStarts] 中哪一周（下标）；不在任何
  /// 一周内返回 null。
  static int? _weekIndexOf(DateTime date, List<DateTime> weekStarts) {
    final day = DateTime(date.year, date.month, date.day);
    for (var i = 0; i < weekStarts.length; i++) {
      final start = weekStarts[i];
      // 纯日历加法：防 DST 切换日「加 7 天偏移一小时」导致边界错位。
      final end = addLocalDays(start, 7);
      if (!day.isBefore(start) && day.isBefore(end)) return i;
    }
    return null;
  }

  /// 甘特图时长分桶（LeetCode 绿系五档，按周完成分钟数）。
  ///
  /// 0 分钟 → 0；1-59 → 1；60-119 → 2；120-299 → 3；300+ → 4。
  static int minutesLevel(int minutes) {
    if (minutes <= 0) return 0;
    if (minutes < 60) return 1;
    if (minutes < 120) return 2;
    if (minutes < 300) return 3;
    return 4;
  }

  /// 最近 [weeks] 周（默认 26）的「周起始日」列表。
  ///
  /// 周从周一开始（与日历视图一致）。返回的列表按时间升序排列，
  /// 最后一项是包含 [today] 那一周的周一。
  static List<DateTime> recentWeekStarts(DateTime today, {int weeks = 26}) {
    final day = DateTime(today.year, today.month, today.day);
    // 纯日历加法（date_text），同 ganttWeekStarts：防 DST 切换日偏移。
    final thisWeekStart = addLocalDays(day, -(day.weekday - 1));
    return List.generate(weeks, (i) {
      return addLocalDays(thisWeekStart, -(weeks - 1 - i) * 7);
    });
  }

  /// 燃尽趋势序列：每日「剩余预估时长」与「理想参考线」（FR-7.3）。
  ///
  /// 口径（回顾式燃尽，与甘特图/热力图一致从今天往回看）：
  /// - 窗口为 [today-（windowDays-1）.. today] 共 [windowDays] 天，升序；
  /// - 某日剩余 = 当前全部未完成任务时长和 + 已完成任务中「完成日期严格
  ///   晚于该日」的时长和——表示该日时点仍欠着多少工作量；随日期推进
  ///   单调递减，**today 点等于当前剩余**（与 FR-7.1 剩余工作量口径一致）；
  /// - 理想参考线 = 从窗口起点的实际剩余起，按 [endDate]（最晚截止日）
  ///   线性递减到 0，截取窗口内部分；endDate 不晚于窗口起点时参考线为 0；
  /// - 无预估时长的任务不计入（FR-7.4），[todoTasks] 只计未完成、
  ///   [completedTasks] 只计已完成（调用方传入已过滤列表）。
  static List<BurndownPoint> burndownSeries({
    required List<Task> todoTasks,
    required List<Task> completedTasks,
    required DateTime today,
    required DateTime endDate,
    int windowDays = 30,
  }) {
    final todayDay = _localDay(today);
    final start = _localDay(todayDay.subtract(Duration(days: windowDays - 1)));
    final days = List.generate(
      windowDays,
      (i) => start.add(Duration(days: i)),
    );

    // 已完成任务按「完成日期」桶化（只取窗口起或之后完成的；窗口前完成
    // 的早已消化，不进入窗口剩余）。
    final completedMinutesByDay = <String, int>{};
    for (final task in completedTasks) {
      final minutes = task.estimatedMinutes;
      final completedAt = task.completedAt;
      if (minutes == null || completedAt == null) continue;
      final day = _localDay(completedAt.toLocal());
      if (day.isBefore(start)) continue;
      final key = _formatDate(day);
      completedMinutesByDay[key] = (completedMinutesByDay[key] ?? 0) + minutes;
    }

    // 当前未完成时长和（FR-7.4：无时长不计）。
    var currentRemaining = 0;
    for (final task in todoTasks) {
      if (task.status == TaskStatus.done) continue;
      final minutes = task.estimatedMinutes;
      if (minutes != null) currentRemaining += minutes;
    }

    // 窗口起点欠账 = 当前剩余 + 窗口内完成的总时长（这些在起点时点尚未完成）。
    final int baseRemaining =
        currentRemaining + completedMinutesByDay.values.fold<int>(0, (sum, v) => sum + v);
    // 起点时点实际剩余：扣除完成日恰为窗口起点的（起点即已完成）。
    final int idealStart =
        baseRemaining - (completedMinutesByDay[_formatDate(start)] ?? 0);

    // 理想参考线：从 idealStart 线性递减到 endDate 归 0。
    final endDay = _localDay(endDate);
    final idealTotalDays = endDay.difference(start).inDays;
    final double idealPerDay = idealTotalDays > 0 ? idealStart / idealTotalDays : 0.0;

    final points = <BurndownPoint>[];
    var consumed = 0; // 完成日 ≤ 当前日的累计时长（不再欠账）
    for (final day in days) {
      final key = _formatDate(day);
      consumed += completedMinutesByDay[key] ?? 0;
      final int remaining = baseRemaining - consumed;

      final elapsed = day.difference(start).inDays;
      final int ideal = idealPerDay > 0
          ? (idealStart - idealPerDay * elapsed).clamp(0, idealStart).toInt()
          : 0;
      points.add(
        BurndownPoint(
          date: day,
          remaining: remaining,
          ideal: ideal,
        ),
      );
    }
    return points;
  }

  /// 燃尽窗口内「已完成时长」合计（供卡片结论句「过去 N 天消化了 X」）。
  ///
  /// 口径与 [burndownSeries] 完全一致：只计 `completedAt ≥ 窗口起点` 的
  /// 已完成任务（窗口前完成的早已消化，不属本窗口），无预估时长不计入
  /// （FR-7.4）。纯计算，便于与结论句分开单测。
  static int burndownWindowDoneMinutes({
    required List<Task> completedTasks,
    required DateTime today,
    int windowDays = 30,
  }) {
    final todayDay = _localDay(today);
    final start = _localDay(todayDay.subtract(Duration(days: windowDays - 1)));
    var done = 0;
    for (final task in completedTasks) {
      final minutes = task.estimatedMinutes;
      final completedAt = task.completedAt;
      if (minutes == null || completedAt == null) continue;
      final day = _localDay(completedAt.toLocal());
      if (day.isBefore(start)) continue;
      done += minutes;
    }
    return done;
  }

  static DateTime _localDay(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  static String _formatDate(DateTime local) {
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd';
  }
}

/// 燃尽趋势单日数据点（FR-7.3）。
class BurndownPoint {
  const BurndownPoint({
    required this.date,
    required this.remaining,
    required this.ideal,
  });

  /// 该日（本地日历日期）。
  final DateTime date;

  /// 该日时点仍欠着的预估时长（分钟）。
  final int remaining;

  /// 理想参考线在该日的值（分钟）。
  final int ideal;
}
