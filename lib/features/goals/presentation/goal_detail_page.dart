import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/countdown_service.dart';
import '../../../services/duration_format.dart';
import '../../../services/load_service.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../../tasks/presentation/task_list_section.dart';
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
        loading: () => const Center(child: CircularProgressIndicator()),
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

class GoalDetailBody extends ConsumerWidget {
  const GoalDetailBody({super.key, required this.goal});

  final Goal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(subjectListProvider(goal.id));
    final tasksAsync = ref.watch(taskListProvider(goal.id));

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(child: _GoalHeader(goal: goal)),
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        // 里程碑区（FR-2）：目标概览 → 里程碑 → 任务（PRD §7 层级）。
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: MilestoneSection(
              goalId: goal.id,
              deadlineDate: goal.deadlineDate,
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
                child: _LoadSection(goal: goal, tasks: tasks),
              ),
            ),
          ],
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(child: SubjectManager(goalId: goal.id)),
        ),
        const SliverToBoxAdapter(child: Divider(height: 32)),
        // 未归属科目的任务在详情页直接管理（无科目页可进）。
        // TaskListSection 自身是 SliverMainAxisGroup（含懒加载 SliverList，
        // 展开状态内部维护），直接作为一条 sliver 嵌入。
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
                TaskListSection(
                  goalId: goal.id,
                  subjects: subjects,
                  tasks: unassigned,
                  // JSON 导入为「替换」语义：替换整个目标的任务计划，
                  // 因此传入目标全部未归档任务供对话框展示将被替换的清单。
                  currentTasks: tasks,
                  title: '未分类任务',
                  description: '不归属特定科目的安排，如科目复习/复盘、考研报名等',
                  emptyText: '还没有此类任务。可点「添加任务」或「批量添加」创建',
                  onChanged: () => ref.invalidate(taskListProvider(goal.id)),
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
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      risk ? Icons.warning_amber_rounded : Icons.speed,
                      color: risk ? scheme.error : scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '负载',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('剩余任务时长：${DurationFormat.minutes(remaining)}'),
                Text('剩余可用天数：$remainingDays 天'),
                Text(
                  '建议日均时长：${DurationFormat.minutes(suggested)} · 可用 ${DurationFormat.minutes(settings.dailyAvailableMinutes)}/天',
                ),
                if (risk) ...[
                  const SizedBox(height: 8),
                  Text(
                    '计划风险：按当前节奏无法在截止日前完成。'
                    '建议延长截止日、减少任务量或增加每日可用时间。',
                    style: TextStyle(color: scheme.error),
                  ),
                  Text(
                    '系统仅提供建议，不会自动修改你的计划。',
                    style: Theme.of(context).textTheme.bodySmall,
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
    final onHero = Colors.white;
    final onHeroSoft = Colors.white.withValues(alpha: 0.88);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [kTimeCalcBrandDeep, kTimeCalcBrandBright],
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
                '${CountdownService.label(phase, days)} · 截止 ${DateFormat('yyyy-MM-dd').format(parseLocalDate(goal.deadlineDate))}',
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
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text('正在加载任务…',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
