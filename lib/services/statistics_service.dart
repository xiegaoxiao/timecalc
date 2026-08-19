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

  /// 按完成日期（本地 yyyy-MM-dd）把已完成任务分桶（FR-7.2 热力图点击详情）。
  ///
  /// 与 [completedCountsByLocalDate] 同口径（status=done 且 completedAt
  /// 非空），但返回每个日期下的任务列表，供热力图格子点击时 O(1) 取当天
  /// 任务，避免逐格对全量任务做线性扫描。无完成记录的日期不出现在映射中。
  Map<String, List<Task>> completedTasksByLocalDate(List<Task> tasks) {
    final byDate = <String, List<Task>>{};
    for (final task in tasks) {
      if (task.status != TaskStatus.done) continue;
      final completedAt = task.completedAt;
      if (completedAt == null) continue;
      final key = _formatDate(completedAt.toLocal());
      byDate.putIfAbsent(key, () => <Task>[]).add(task);
    }
    return byDate;
  }

  /// 按完成月份（本地年-月）统计完成任务数量（年视图月格）。
  ///
  /// 口径与 [completedCountsByLocalDate] 一致（status=done 且 completedAt
  /// 非空，按本地日期归月），返回以 `yyyy-MM` 为键的数量映射，无完成
  /// 记录的月份不出现在映射中。
  Map<String, int> completedCountsByMonth(List<Task> tasks) {
    final counts = <String, int>{};
    for (final task in tasks) {
      if (task.status != TaskStatus.done) continue;
      final completedAt = task.completedAt;
      if (completedAt == null) continue;
      final local = completedAt.toLocal();
      final key =
          '${local.year}-${local.month.toString().padLeft(2, '0')}';
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
      // 容错解析：手工改库/旧版残留的非规范 plannedDate 不再让甘特图崩溃
      // （DateTime.parse 对 "2026-8-6" 抛 FormatException，对 "2026-13-99"
      // 静默溢出归一化），解析失败直接跳过该任务。
      final planned = _tryParseLocalDate(task.plannedDate);
      if (planned == null) continue;
      final weekIndex = _weekIndexOf(planned, weekStarts);
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
  ///
  /// O(1)：周窗是均匀的 7 天网格，直接用「距首周起点的日历天数 ~/ 7」
  /// 定位，替代旧版逐周线性扫描（N 个任务 × 26 周）。天差用 UTC 归一化
  /// 计算，避免本地 DST 让 `difference().inDays` 出现 23/25 小时偏差——
  /// 与 [addLocalDays] 的纯日历口径一致。
  static int? _weekIndexOf(DateTime date, List<DateTime> weekStarts) {
    if (weekStarts.isEmpty) return null;
    final first = weekStarts.first;
    final startUtc = DateTime.utc(first.year, first.month, first.day);
    final dayUtc = DateTime.utc(date.year, date.month, date.day);
    final index = dayUtc.difference(startUtc).inDays ~/ 7;
    if (index < 0 || index >= weekStarts.length) return null;
    return index;
  }

  /// 容错解析 `yyyy-MM-dd`（本地日历日期）。
  ///
  /// 脏数据（空串、字段数不足、非数字）返回 null，由调用方跳过；纯日历
  /// 口径与 `date_text.parseLocalDate` 一致（`DateTime` 构造函数对超出范围
  /// 的月/日做归一化，不抛异常）。
  static DateTime? _tryParseLocalDate(String value) {
    final parts = value.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    // 防御（审查 #17）：年份越界时 DateTime(...) 抛 ArgumentError，
    // 补充 1~9999 区间校验，与「解析失败直接跳过」的容错契约一致。
    if (year < 1 || year > 9999) return null;
    return DateTime(year, month, day);
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
  /// 口径（前向燃尽）：从今天起往后看到最晚截止日，用于展示「接下来应该
  /// 怎么燃尽」，避免刚创建计划时左侧出现一大段无意义的平线。
  /// - 窗口为 [today .. max(endDate, today + minForwardDays - 1)]，升序；
  ///   若截止日很近，自动延长到至少 [minForwardDays] 天，避免图表被压扁；
  /// - 某日剩余 = 按最晚截止日 [endDate] 从今天当前剩余线性递减到 0 的
  ///   「计划剩余量」，表示如果每天匀速完成，该日应剩余多少工作量；
  /// - 理想参考线与本序列取值相同（均为计划燃尽线），Chart 层可选择只
  ///   渲染剩余线，或把 ideal 作为同值参考；
  /// - 无预估时长的任务不计入（FR-7.4），[todoTasks] 只计未完成。
  static List<BurndownPoint> burndownSeries({
    required List<Task> todoTasks,
    required DateTime today,
    required DateTime endDate,
    int minForwardDays = 14,
  }) {
    final todayDay = _localDay(today);
    final endDay = _localDay(endDate);

    // 当前未完成时长和（FR-7.4：无时长不计）。
    var currentRemaining = 0;
    for (final task in todoTasks) {
      if (task.status == TaskStatus.done) continue;
      final minutes = task.estimatedMinutes;
      if (minutes != null) currentRemaining += minutes;
    }

    // 前向窗口：从今天到最晚截止日，至少保留 minForwardDays 天的展示区间。
    final rawForwardDays = _dayDiff(endDay, todayDay);
    final forwardDays =
        rawForwardDays < minForwardDays ? minForwardDays : rawForwardDays;
    final days = List.generate(
      forwardDays + 1,
      (i) => addLocalDays(todayDay, i),
    );

    // 计划燃尽线：从今天 currentRemaining 起，按 endDate 线性递减到 0。
    // 若 endDate 已早于 today，表示计划已过期，理想燃尽线全程为 0。
    final idealTotalDays = _dayDiff(endDay, todayDay);
    final double idealPerDay =
        idealTotalDays > 0 ? currentRemaining / idealTotalDays : 0.0;

    final points = <BurndownPoint>[];
    for (final day in days) {
      final elapsed = _dayDiff(day, todayDay);
      final int ideal = idealTotalDays > 0
          ? (currentRemaining - idealPerDay * elapsed)
              .clamp(0, currentRemaining)
              .toInt()
          : 0;
      final int remaining = idealTotalDays > 0 ? ideal : currentRemaining;
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

  static DateTime _localDay(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  /// 以「日历日」为单位计算 [a] - [b] 的天数（UTC 归一化，防 DST 偏差）。
  static int _dayDiff(DateTime a, DateTime b) {
    final aDay = DateTime.utc(a.year, a.month, a.day);
    final bDay = DateTime.utc(b.year, b.month, b.day);
    return aDay.difference(bDay).inDays;
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
