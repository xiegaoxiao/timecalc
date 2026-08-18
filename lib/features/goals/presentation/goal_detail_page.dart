import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/app_refresh.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/theme/accent_palette.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/duration_format.dart';
import '../../../services/load_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/collapsible_section.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../../shared/widgets/section_header.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/task_list_section.dart';
import '../../tasks/presentation/task_section_actions.dart';
import '../data/goal_repository_provider.dart';
import '../data/subject_repository_provider.dart';
import 'goal_form_dialog.dart';
import 'milestone_section.dart';
import 'subject_manager.dart';

/// 目标详情页：目标概览 → 里程碑 → 科目列表 → 未分类任务（PRD §7 层级）。
///
/// 里程碑区（FR-2）展示目标下的阶段性节点；点击科目进入该科目的任务列表页；
/// 未归属科目的任务在本页「未分类」区管理。
class GoalDetailPage extends ConsumerWidget {
  const GoalDetailPage({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalAsync = ref.watch(goalDetailProvider(int.parse(goalId)));
    return Scaffold(
      appBar: AppBar(title: const Text('目标详情')),
      body: goalAsync.when(
        // 首载用骨架屏（非 spinner）：点击卡片进入的过渡窗口内「立即有
        // 内容」占位，数据到达后自然过渡；spinner 动画与页面过渡动画
        // 叠加在 Windows 上会造成闪烁/掉帧观感（P3.5 卡顿排查）。
        loading: () => PageSkeletons.goalDetailPage(),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(goalDetailProvider(int.parse(goalId))),
        ),
        data: (goal) {
          if (goal == null) {
            return const Center(child: Text('目标不存在'));
          }
          return GoalDetailBody(goal: goal);
        },
      ),
    );
  }
}

class GoalDetailBody extends ConsumerStatefulWidget {
  const GoalDetailBody({super.key, required this.goal});

  final Goal goal;

  /// 未分类任务区预览行数（2026-08-18）：任务超出该条数时详情页只展示
  /// 前 N 条 + 「查看全部」行，避免几百个任务时整页长滚。
  static const int unassignedPreviewLimit = 8;

  /// 里程碑区预览行数（2026-08-18）：与任务区预览对称，里程碑超出该
  /// 条数时详情页只展示前 N 条 + 「查看全部」行。
  static const int milestonesPreviewLimit = 8;

  @override
  ConsumerState<GoalDetailBody> createState() => _GoalDetailBodyState();
}

class _GoalDetailBodyState extends ConsumerState<GoalDetailBody> {
  /// 未分类任务区折叠状态（2026-08-18）：任务多时收起该区即可避免整页
  /// 长滚。局部状态只重建本页 slivers，里程碑/科目区各自管理折叠。
  bool _unassignedExpanded = true;

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(subjectListProvider(widget.goal.id));
    final tasksAsync = ref.watch(taskListProvider(widget.goal.id));

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: _GoalHeader(goal: widget.goal),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        // 里程碑区（FR-2）：目标概览 → 里程碑 → 任务（PRD §7 层级）。
        // 预览截断（2026-08-18）：超出 8 条时只展示前 8 条 + 「查看
        // 全部」行跳目标全部里程碑页，与任务区预览对称。
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: MilestoneSection(
              goalId: widget.goal.id,
              deadlineDate: widget.goal.deadlineDate,
              previewLimit: GoalDetailBody.milestonesPreviewLimit,
              onViewAll: () =>
                  context.push('/goals/${widget.goal.id}/milestones'),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        // 负载区（FR-5.3）：剩余任务时长、剩余可用天数、建议日均与计划风险。
        ...tasksAsync.when(
          loading: () => const [_TasksLoadingPlaceholder()],
          error: (error, _) => [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(child: AppErrorView(error: error)),
            ),
          ],
          data: (tasks) => [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: _LoadSection(goal: widget.goal, tasks: tasks),
              ),
            ),
          ],
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SubjectManager(goalId: widget.goal.id),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        // 未归属科目的任务在详情页直接管理（无科目页可进）。
        ...subjectsAsync.when(
          loading: () => const <Widget>[],
          error: (error, _) => [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(child: AppErrorView(error: error)),
            ),
          ],
          data: (subjects) => tasksAsync.when(
            loading: () => const [_TasksLoadingPlaceholder()],
            error: (error, _) => [
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(child: AppErrorView(error: error)),
              ),
            ],
            data: (tasks) {
              final unassigned =
                  tasks.where((t) => t.subjectId == null).toList();
              return [
                // 任务区可折叠（2026-08-18）：区块头整行可点展开/收起，
                // 折叠时 sliver 列表不挂载，页面更短；「N 个」摘要显示
                // 任务规模。添加/导入等操作组常驻头部行，折叠时入口
                // 不消失。头部为独立 sliver，列表展开与否由本页状态控制。
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(
                    child: CollapsibleSection(
                      icon: Icons.checklist,
                      title: '未分类任务',
                      summary: '${unassigned.length} 个',
                      expanded: _unassignedExpanded,
                      onChanged: (v) =>
                          setState(() => _unassignedExpanded = v),
                      // 无 body：列表本身是 sliver，由外部按状态渲染。
                      trailing: TaskSectionActions(
                        goalId: widget.goal.id,
                        subjects: subjects,
                        // JSON 导入为「替换」语义：替换整个目标的任务计划，
                        // 因此传入目标全部未归档任务供对话框展示将被替换的清单。
                        currentTasks: tasks,
                      ),
                    ),
                  ),
                ),
                if (_unassignedExpanded)
                  TaskListSection(
                    goalId: widget.goal.id,
                    subjects: subjects,
                    tasks: unassigned,
                    description: '不归属特定科目的安排，如科目复习/复盘、考研报名等',
                    emptyText: '还没有此类任务。可点「添加任务」或「批量添加」创建',
                    // 预览截断（2026-08-18）：详情页只展示前 8 条任务，
                    // 超出时末尾追加「查看全部」行跳目标全部任务页——任务
                    // 几百个时详情页不至于太长、也看得到全部内容。
                    previewLimit: GoalDetailBody.unassignedPreviewLimit,
                    onViewAll: () =>
                        context.push('/goals/${widget.goal.id}/tasks'),
                    // 全量跨页刷新（FR-3 验收）：完成/编辑/删除任务影响今日页、
                    // 日历与进度页（completedTasksProvider/allTodoTasksProvider
                    // 若不失效，进度页热力图与剩余工作量停留陈旧，回归教训）。
                    onChanged: () => invalidateAppData(ref),
                  ),
              ];
            },
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
      ],
    );
  }
}

/// 目标负载区（FR-5.3 / FR-5.4）。
///
/// 展示剩余任务时长、剩余可用天数与建议日均时长；建议日均超过每日
/// 可用时长时显示计划风险与建议（延长截止日/减少任务/增加可用时间）。
/// 系统只提出建议，不自动删除任务或修改截止日期（FR-5.5）。
class _LoadSection extends ConsumerWidget {
  const _LoadSection({required this.goal, required this.tasks});

  final Goal goal;
  final List<Task> tasks;

  static const _load = LoadService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    return settingsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) => AppErrorView(error: error),
      data: (settings) {
        final today = ref.watch(clockProvider)();
        final weekdays = SettingsRepository.decodeWeekdays(
          settings.availableWeekdays,
        );
        final remaining = _load.remainingMinutes(tasks);
        final remainingDays = _load.remainingAvailableDays(
          deadlineDate: goal.deadlineDate,
          today: today,
          availableWeekdays: weekdays,
        );
        final suggested = _load.suggestedDailyMinutes(
          remainingMinutes: remaining,
          remainingDays: remainingDays,
        );
        final risk = _load.hasPlanRisk(
          suggestedDailyMinutes: suggested,
          dailyAvailableMinutes: settings.dailyAvailableMinutes,
        );

        final scheme = Theme.of(context).colorScheme;
        // 无任何任务时数字用 `-- 分` 占位：区分「还没建立计划」与「计划
        // 已全部完成（0 分）」两种状态，避免空目标下出现误导性的 0。
        final hasAnyTask = tasks.isNotEmpty;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 区块头统一 SectionHeader（2026-08-16 视觉升级）：风险时
                // 图标换警示 + trailing 红色警示 chip（与今天页「超出」chip
                // 同款；不只依赖颜色，chip 带文字）。
                SectionHeader(
                  icon: risk ? Icons.warning_amber_rounded : Icons.speed,
                  title: '负载',
                  trailing: risk
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.error.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 14,
                                color: scheme.error,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '计划风险',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: scheme.error,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                // 三格指标（仪表盘化，2026-08-16）：冒号文本行改为
                // label + 等宽数字数值，与今天页/进度页同语言。
                Row(
                  children: [
                    Expanded(
                      child: _MetricCell(
                        label: '剩余任务时长',
                        value: hasAnyTask
                            ? DurationFormat.minutes(remaining)
                            : '-- 分',
                      ),
                    ),
                    Expanded(
                      child: _MetricCell(
                        label: '剩余学习日',
                        value: '$remainingDays 天',
                      ),
                    ),
                    Expanded(
                      child: _MetricCell(
                        label: '建议日均时长',
                        value: hasAnyTask
                            ? DurationFormat.minutes(suggested)
                            : '-- 分',
                        // 依据摘要：建议日均对照的每日可用量。
                        caption:
                            '可用 ${DurationFormat.minutes(settings.dailyAvailableMinutes)}/天',
                      ),
                    ),
                  ],
                ),
                // 学习日 = 按计划偏好 weekdays 过滤后的可学习星期（与顶部
                // 倒计时的「日历天数」口径不同，显式标注避免两个数字混淆）。
                if (remainingDays > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '剩余可用天数为按计划偏好排除休息日后的学习日；'
                    '日历总天数见顶部倒计时。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                  ),
                ],
                if (risk) ...[
                  const SizedBox(height: 8),
                  // 风险提示移入浅红容器（与今天页过期区块同语义）。
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '按当前节奏无法在截止日前完成。'
                          '建议延长截止日、减少任务量或增加每日可用时间。',
                          style: TextStyle(color: scheme.error),
                        ),
                        Text(
                          '系统仅提供建议，不会自动修改你的计划。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 负载指标格：小标签 + 等宽数字数值 + 可选摘要小字（2026-08-16 仪表盘化，
/// 与今天页/进度页 `_MetricCell` 同款视觉语言）。
class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.label, required this.value, this.caption});

  final String label;
  final String value;

  /// 数值下方的补充摘要（如「可用 X/天」）。
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(
              caption!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ],
      ),
    );
  }
}

class _GoalHeader extends ConsumerWidget {
  const _GoalHeader({required this.goal});

  final Goal goal;

  static const _countdown = CountdownService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(clockProvider)();
    final (phase, days) = _countdown.evaluate(
      deadlineDate: goal.deadlineDate,
      today: today,
      status: goal.status,
    );

    final phaseIcon = switch (phase) {
      CountdownPhase.upcoming => Icons.schedule,
      CountdownPhase.today => Icons.today,
      CountdownPhase.overdue => Icons.error_outline,
      CountdownPhase.terminated => Icons.flag_outlined,
    };
    // 头部 hero：品牌渐变背景 + 白字（与今天页倒计时卡同款，视觉呼应）。
    // 渐变取当前色系（绿色/蓝色主题各自变化，2026-08-16 解耦）。
    final accent = Theme.of(context).extension<AccentPalette>()!;
    final onHero = Colors.white;
    final onHeroSoft = Colors.white.withValues(alpha: 0.88);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.brandDeep, accent.brandBright],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  goal.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: onHero,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '编辑目标',
                icon: Icon(Icons.edit_outlined, color: onHero),
                onPressed: () => GoalFormDialog.show(context, goal: goal),
              ),
            ],
          ),
          if (goal.description?.isNotEmpty ?? false) ...[
            const SizedBox(height: 8),
            Text(
              goal.description!,
              style: TextStyle(color: onHeroSoft),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(phaseIcon, size: 18, color: onHero),
              const SizedBox(width: 6),
              Text(
                '${CountdownService.label(phase, days)} · 截止 ${formatLocalDate(parseLocalDate(goal.deadlineDate))}',
                style: TextStyle(
                  color: onHero,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 任务加载占位（L2 修复）：任务列表加载中展示轻量占位卡片，避免负载区
/// /任务区整段闪空（白跳）。待首次数据到达即被真实内容替换。
///
/// 用静态文案代替 CircularProgressIndicator：spinner 旋转动画与页面过渡
/// 动画叠加时造成闪烁/掉帧（Windows 实测），占位卡无需动画观感即可。
class _TasksLoadingPlaceholder extends StatelessWidget {
  const _TasksLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text('正在加载任务…', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
