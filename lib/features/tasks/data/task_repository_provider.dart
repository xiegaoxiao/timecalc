import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
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
