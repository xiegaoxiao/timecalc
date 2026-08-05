import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../data/goal_repository.dart';

/// 目标数据访问 Provider（SOP §2：数据事实保存在 Drift，Riverpod 只提供依赖）。
final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  return GoalRepository(ref.watch(databaseProvider));
});

/// 目标列表异步状态（AsyncValue：加载/空/失败/数据）。
final goalListProvider = FutureProvider<List<Goal>>((ref) {
  return ref.watch(goalRepositoryProvider).watchAll();
});
