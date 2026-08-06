import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/clock_provider.dart';
import 'milestone_repository.dart';

/// 里程碑数据访问 Provider（SOP §2：数据事实保存在 Drift，Riverpod 只提供依赖）。
final milestoneRepositoryProvider = Provider<MilestoneRepository>((ref) {
  return MilestoneRepository(ref.watch(databaseProvider));
});

/// 目标下的里程碑列表（family：按 goalId）。
final milestoneListProvider = FutureProvider.family<List<Milestone>, int>(
  (ref, goalId) => ref.watch(milestoneRepositoryProvider).byGoal(goalId),
);

/// 目标下日期最近的未完成里程碑（FR-2.3 首页展示）。
///
/// 依赖固定时钟（clockProvider），与倒计时口径一致。
final nextUpcomingMilestoneProvider = FutureProvider.family<Milestone?, int>(
  (ref, goalId) {
    final today = ref.watch(clockProvider)();
    return ref.watch(milestoneRepositoryProvider).nextUpcoming(
          goalId,
          today: today,
        );
  },
);
