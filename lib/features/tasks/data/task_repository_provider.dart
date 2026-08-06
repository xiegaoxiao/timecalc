import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/clock_provider.dart';
import '../data/task_repository.dart';

/// 任务数据访问 Provider。
final taskRepositoryProvider = Provider<TaskRepository>((ref) {
  return TaskRepository(ref.watch(databaseProvider));
});

/// 目标下任务列表异步状态。
final taskListProvider =
    FutureProvider.family<List<Task>, int>((ref, goalId) {
  return ref.watch(taskRepositoryProvider).byGoal(goalId);
});

/// 指定计划日期（yyyy-MM-dd）的全部任务（跨目标，今日页用）。
final tasksByDateProvider =
    FutureProvider.family<List<Task>, String>((ref, date) {
  return ref.watch(taskRepositoryProvider).byDate(date);
});

/// 指定月份（yyyy-MM）的全部任务（日历月视图用）。
final tasksByMonthProvider =
    FutureProvider.family<List<Task>, String>((ref, month) {
  final parts = month.split('-');
  final firstDay = DateTime(int.parse(parts[0]), int.parse(parts[1]), 1);
  final lastDay = DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
  return ref.watch(taskRepositoryProvider).byDateRange(
        DateFormat('yyyy-MM-dd').format(firstDay),
        DateFormat('yyyy-MM-dd').format(lastDay),
      );
});

/// 计划日期早于指定日期（yyyy-MM-dd）且未完成的任务（FR-3.7）。
final unfinishedBeforeProvider =
    FutureProvider.family<List<Task>, String>((ref, date) {
  return ref.watch(taskRepositoryProvider).unfinishedBefore(date);
});

/// 目标下已归档任务（历史记录，JSON 导入替换时保留）。
final archivedTaskListProvider =
    FutureProvider.family<List<Task>, int>((ref, goalId) {
  return ref.watch(taskRepositoryProvider).archivedByGoal(goalId);
});

/// 全部归档任务（跨目标，设置页数据管理区用，按归档时间倒序）。
final allArchivedTasksProvider = FutureProvider<List<Task>>((ref) {
  return ref.watch(taskRepositoryProvider).allArchived();
});

/// 最近 26 周内完成的任务（FR-7.2 热力图数据源，按完成日期统计）。
///
/// 查询时间窗为 UTC，实际归日换算在 StatisticsService 中按本地日期完成。
/// 时间取自 [clockProvider]（测试可注入固定时钟）。
final completedTasksProvider = FutureProvider<List<Task>>((ref) {
  final now = ref.watch(clockProvider)();
  final fromUtc = now.toUtc().subtract(const Duration(days: 26 * 7 + 1));
  return ref.watch(taskRepositoryProvider).completedBetween(fromUtc, now.toUtc());
});

/// 全部未完成任务（FR-7.1 目标剩余工作量汇总）。
final allTodoTasksProvider = FutureProvider<List<Task>>((ref) {
  return ref.watch(taskRepositoryProvider).allTodoTasks();
});
