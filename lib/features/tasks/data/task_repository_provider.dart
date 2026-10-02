import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../data/task_repository.dart';

/// 任务数据访问 Provider。
final taskRepositoryProvider = Provider<TaskRepository>((ref) {
  return TaskRepository(ref.watch(databaseProvider));
});

/// 目标下任务列表异步状态。
/// 订阅数据库变更，创建、完成、改期及级联删除后各页面自动同步。
/// 无监听者时释放订阅，避免每个浏览过的月份都持续查询。
final taskListProvider = StreamProvider.autoDispose.family<List<Task>, int>((
  ref,
  goalId,
) {
  return ref.watch(taskRepositoryProvider).watchByGoal(goalId);
});

/// 指定计划日期（yyyy-MM-dd）的全部任务（跨目标，今日页用）。
final tasksByDateProvider = StreamProvider.autoDispose
    .family<List<Task>, String>((ref, date) {
      return ref.watch(taskRepositoryProvider).watchByDate(date);
    });

/// 指定月份（yyyy-MM）的全部任务（日历月视图用）。
final tasksByMonthProvider = StreamProvider.autoDispose
    .family<List<Task>, String>((ref, month) {
      final parts = month.split('-');
      final firstDay = DateTime(int.parse(parts[0]), int.parse(parts[1]), 1);
      final lastDay = DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
      return ref
          .watch(taskRepositoryProvider)
          .watchByDateRange(
            DateFormat('yyyy-MM-dd').format(firstDay),
            DateFormat('yyyy-MM-dd').format(lastDay),
          );
    });

/// 计划日期早于指定日期（yyyy-MM-dd）且未完成的任务（FR-3.7）。
final unfinishedBeforeProvider = StreamProvider.autoDispose
    .family<List<Task>, String>((ref, date) {
      return ref.watch(taskRepositoryProvider).watchUnfinishedBefore(date);
    });
