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

/// 单个目标详情异步状态。
///
/// 与 goalListProvider 相互独立缓存；编辑目标保存后必须同时
/// invalidate 本 Provider，详情页才能反映最新数据。
final goalDetailProvider = FutureProvider.family<Goal?, int>((ref, id) {
  return ref.watch(goalRepositoryProvider).byId(id);
});
