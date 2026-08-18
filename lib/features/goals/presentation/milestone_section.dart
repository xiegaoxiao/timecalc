import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/chart_empty_state.dart';
import '../../../shared/widgets/collapsible_section.dart';
import '../../../shared/widgets/progressive_rows.dart';
import '../data/milestone_repository_provider.dart';
import 'milestone_actions.dart';
import 'milestone_card.dart';

/// 里程碑管理组件（FR-2）：目标下的阶段性节点列表。
///
/// 每个里程碑显示日期与标题，支持添加、编辑、标记完成、删除（FR-2.1）；
/// 日期晚于目标截止日的保存被阻断（FR-2.2，见 MilestoneFormDialog）。
/// 完整里程碑列表在此展示（FR-2.3）。
///
/// 列表可折叠（2026-08-18）：区块头整行可点展开/收起，收起时仅保留头行
/// 与「N 个」摘要（列表与空态一并隐藏）；「添加里程碑」常驻，折叠状态下
/// 添加成功后自动展开。折叠状态为本组件局部状态（受控模式），只重建本
/// 区块，不波及页面其他区块。
///
/// 预览截断（2026-08-18）：传入 [previewLimit] 与 [onViewAll] 时，里程碑
/// 超出预览条数只展示前 N 条 + 末尾「查看全部」行（跳目标全部里程碑页）；
/// 未传时行为完全不变（与任务区预览对称）。
class MilestoneSection extends ConsumerStatefulWidget {
  const MilestoneSection({
    super.key,
    required this.goalId,
    required this.deadlineDate,
    this.previewLimit,
    this.onViewAll,
  });

  final int goalId;

  /// 目标截止日（`yyyy-MM-dd`），传给表单做 FR-2.2 校验。
  final String deadlineDate;

  /// 预览行数上限（非空且里程碑超出时只展示前 N 条 + 「查看全部」行）。
  final int? previewLimit;

  /// 点击「查看全部 N 个里程碑」行的回调（如跳转目标全部里程碑页）。
  final VoidCallback? onViewAll;

  @override
  ConsumerState<MilestoneSection> createState() => _MilestoneSectionState();
}

class _MilestoneSectionState extends ConsumerState<MilestoneSection> {
  /// 列表折叠状态（默认展开，保持既有默认可见行为）。
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final milestonesAsync = ref.watch(milestoneListProvider(widget.goalId));

    return CollapsibleSection(
      icon: Icons.outlined_flag,
      title: '里程碑',
      // 受控模式：添加成功后需主动展开，状态由本组件持有。
      expanded: _expanded,
      onChanged: (v) => setState(() => _expanded = v),
      summary: milestonesAsync.valueOrNull == null
          ? null
          : '${milestonesAsync.valueOrNull!.length} 个',
      trailing: TextButton.icon(
        onPressed: () => _addMilestone(context, ref),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('添加里程碑'),
      ),
      body: milestonesAsync.when(
        // 静态占位（非 spinner）：首载窗口与页面过渡动画叠加会造成
        // 闪烁/掉帧（Windows 实测），数据到达即被真实列表替换。
        loading: () => const Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [Text('正在加载里程碑…')],
            ),
          ),
        ),
        error: (error, _) => AppErrorView(error: error),
        data: (milestones) {
          if (milestones.isEmpty) {
            // 空态内容横向居中：本列 start 对齐，需给全宽内部才能居中。
            return const SizedBox(
              width: double.infinity,
              child: ChartEmptyState(
                icon: Icons.flag_outlined,
                title: '还没有里程碑，点击「添加里程碑」设定阶段性节点',
              ),
            );
          }
          // 预览截断（2026-08-18）：超出 previewLimit 时只建前 N 条 +
          // 末尾一条「查看全部」行（与任务区预览对称）。仅当 onViewAll
          // 也传入才生效。
          final limit = widget.previewLimit;
          final previewed = limit != null &&
              widget.onViewAll != null &&
              milestones.length > limit;
          final itemCount = previewed ? limit + 1 : milestones.length;
          return ProgressiveRows(
            // 懒加载（2026-08-17）：里程碑列表按视口驱动渐进构建。
            // 详情页中本区块经 SliverToBoxAdapter 嵌入，进入缓存区即整体
            // 布局；里程碑多（长目标周期上百节点）时旧 Column 一次性全建，
            // 现在滚动到哪建到哪。
            itemCount: itemCount,
            itemBuilder: (context, i) {
              if (previewed && i == limit) {
                return _ViewAllTile(
                  totalCount: milestones.length,
                  onTap: widget.onViewAll!,
                );
              }
              final milestone = milestones[i];
              return MilestoneCard(
                milestone: milestone,
                onEdit: () =>
                    _editMilestone(context, ref, milestone),
                onToggleDone: () =>
                    _toggleDone(context, ref, milestone),
                onDelete: () =>
                    _deleteMilestone(context, ref, milestone),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addMilestone(BuildContext context, WidgetRef ref) async {
    // 保存成功后表单内部已 invalidate milestoneListProvider，无需再刷新。
    final saved = await showMilestoneForm(
      context,
      goalId: widget.goalId,
      deadlineDate: widget.deadlineDate,
    );
    // 折叠状态下添加成功后自动展开，让新里程碑立即落位可见。
    if (saved == true && mounted && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  Future<void> _editMilestone(
    BuildContext context,
    WidgetRef ref,
    Milestone milestone,
  ) async {
    await showMilestoneForm(
      context,
      goalId: widget.goalId,
      deadlineDate: widget.deadlineDate,
      milestone: milestone,
    );
  }

  Future<void> _toggleDone(
    BuildContext context,
    WidgetRef ref,
    Milestone milestone,
  ) async {
    await toggleMilestoneDone(
      context,
      ref,
      goalId: widget.goalId,
      milestone: milestone,
    );
  }

  Future<void> _deleteMilestone(
    BuildContext context,
    WidgetRef ref,
    Milestone milestone,
  ) async {
    await confirmDeleteMilestone(
      context,
      ref,
      goalId: widget.goalId,
      milestone: milestone,
    );
  }
}

/// 「查看全部 N 个里程碑」预览入口行（2026-08-18，与任务区查看全部行
/// 同形态：图标 + 数量 + chevron）。
class _ViewAllTile extends StatelessWidget {
  const _ViewAllTile({required this.totalCount, required this.onTap});

  final int totalCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: const Icon(Icons.visibility_outlined, size: 20),
      title: Text('查看全部 $totalCount 个里程碑'),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
