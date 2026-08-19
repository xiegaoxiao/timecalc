import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/tables.dart';
import '../../../core/providers/clock_provider.dart';
import 'milestone_repository.dart';

/// 里程碑数据访问 Provider（SOP §2：数据事实保存在 Drift，Riverpod 只提供依赖）。
final milestoneRepositoryProvider = Provider<MilestoneRepository>((ref) {
  return MilestoneRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  );
});

/// 目标下的里程碑列表（family：按 goalId）。
final milestoneListProvider = FutureProvider.family<List<Milestone>, int>(
  (ref, goalId) => ref.watch(milestoneRepositoryProvider).byGoal(goalId),
);

/// 目标下日期最近的未完成里程碑（FR-2.3 首页展示）。
///
/// 依赖固定时钟（clockProvider），与倒计时口径一致。
///
/// 直接派生自 [milestoneListProvider]（而非单独查库）：里程碑的任何变更
/// （添加/编辑/勾选完成/删除）都会 invalidate milestoneListProvider，
/// 本 provider 随之重新计算，首页「下一里程碑」卡片无需额外刷新点
/// （修复：勾选完成后首页卡片仍显示已完成的里程碑）。
final nextUpcomingMilestoneProvider = FutureProvider.family<Milestone?, int>(
  (ref, goalId) async {
    final today = ref.watch(clockProvider)();
    final todayText = _dateText(today);
    final milestones = await ref.watch(milestoneListProvider(goalId).future);
    Milestone? nearest;
    for (final milestone in milestones) {
      if (milestone.status != MilestoneStatus.todo) continue;
      if (milestone.date.compareTo(todayText) < 0) continue;
      if (nearest == null || milestone.date.compareTo(nearest.date) < 0) {
        nearest = milestone;
      }
    }
    return nearest;
  },
);

String _dateText(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
