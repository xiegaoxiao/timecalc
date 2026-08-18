import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../../../shared/widgets/progressive_rows.dart';
import '../data/milestone_repository_provider.dart';
import '../data/goal_repository_provider.dart';
import 'milestone_actions.dart';
import 'milestone_card.dart';

/// 目标全部里程碑页（2026-08-18）：详情页里程碑区预览截断后的全量入口。
///
/// 平铺展示目标下全部里程碑（repository 按 sortOrder 排序，阶段序列天然
/// 有序，无需分组），顶部一行总览统计；勾选完成/编辑/删除与详情页一致
/// （MilestoneCard 行内提供）。AppBar 提供「添加里程碑」入口，本页是
/// 里程碑的完整管理页。
class GoalMilestonesPage extends ConsumerWidget {
  const GoalMilestonesPage({super.key, required this.goalId});

  final int goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalAsync = ref.watch(goalDetailProvider(goalId));
    final milestonesAsync = ref.watch(milestoneListProvider(goalId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('全部里程碑'),
        actions: [
          TextButton.icon(
            onPressed: () => showMilestoneForm(
              context,
              goalId: goalId,
              deadlineDate: _deadlineDate(goalAsync),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加里程碑'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: milestonesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(error: error),
        data: (milestones) {
          final goal = goalAsync.valueOrNull;
          if (goal == null) {
            return const Center(child: Text('目标不存在'));
          }
          if (milestones.isEmpty) {
            return const Center(
              child: ChartEmptyState(
                icon: Icons.flag_outlined,
                title: '还没有里程碑，点击「添加里程碑」设定阶段性节点',
              ),
            );
          }
          final doneCount = milestones
              .where((m) => m.status == MilestoneStatus.done)
              .length;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: _Summary(
                    goal: goal,
                    milestones: milestones,
                    doneCount: doneCount,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: ProgressiveRows(
                    // 懒加载（与详情页里程碑区同款）：视口驱动渐进构建，
                    // 上百里程碑不一次性全建。
                    itemCount: milestones.length,
                    itemBuilder: (context, i) {
                      final milestone = milestones[i];
                      return MilestoneCard(
                        milestone: milestone,
                        onEdit: () => showMilestoneForm(
                          context,
                          goalId: goalId,
                          deadlineDate: goal.deadlineDate,
                          milestone: milestone,
                        ),
                        onToggleDone: () => toggleMilestoneDone(
                          context,
                          ref,
                          goalId: goalId,
                          milestone: milestone,
                        ),
                        onDelete: () => confirmDeleteMilestone(
                          context,
                          ref,
                          goalId: goalId,
                          milestone: milestone,
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }

  /// AppBar 添加按钮需要目标截止日做 FR-2.2 校验；目标未就绪时回退空串
  /// （弹窗内日期校验仅与截止日比较，空串时不会误拦，目标加载完成后
  /// 下次打开按钮即带真实截止日）。
  static String _deadlineDate(AsyncValue<Goal?> goalAsync) {
    final goal = goalAsync.valueOrNull;
    return goal?.deadlineDate ?? '';
  }
}

/// 页面顶部概况：目标名 + 里程碑总数/完成数。
class _Summary extends StatelessWidget {
  const _Summary({
    required this.goal,
    required this.milestones,
    required this.doneCount,
  });

  final Goal goal;
  final List<Milestone> milestones;
  final int doneCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          goal.title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '共 ${milestones.length} 个里程碑 · $doneCount 个已完成',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
