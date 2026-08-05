import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../services/countdown_service.dart';
import '../../goals/data/goal_repository_provider.dart';
import '../../goals/presentation/goal_form_dialog.dart';

/// 今天页：目标倒计时卡片（FR-1.2/FR-1.3）。
///
/// 首页先回答「今天做什么」：展示进行中的目标与截止倒计时。
/// 今日任务闭环（FR-3）在 M2 交付。
class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(goalListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('今天')),
      body: goalsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (goals) {
          final active = goals
              .where((g) =>
                  g.status != 'completed' &&
                  g.status != 'abandoned' &&
                  g.status != 'archived')
              .toList();
          if (active.isEmpty) {
            return _EmptyView(hasAnyGoal: goals.isNotEmpty);
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: active.length,
            itemBuilder: (context, index) => _CountdownCard(goal: active[index]),
          );
        },
      ),
    );
  }
}

class _CountdownCard extends ConsumerWidget {
  const _CountdownCard({required this.goal});

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

    final scheme = Theme.of(context).colorScheme;
    final (phaseColor, phaseIcon) = switch (phase) {
      CountdownPhase.upcoming => (scheme.primary, Icons.schedule),
      CountdownPhase.today => (scheme.error, Icons.today),
      CountdownPhase.overdue => (scheme.error, Icons.error_outline),
      CountdownPhase.terminated => (scheme.outline, Icons.flag_outlined),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(
          goal.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('截止 ${DateFormat('yyyy-MM-dd').format(_parseDate(goal.deadlineDate))}'),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(phaseIcon, size: 14, color: phaseColor),
                const SizedBox(width: 4),
                Text(
                  CountdownService.label(phase, days),
                  style: TextStyle(color: phaseColor),
                ),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        // push 压入导航栈，详情页 AppBar 自动出现返回箭头。
        onTap: () => context.push('/goals/${goal.id}'),
      ),
    );
  }

  static DateTime _parseDate(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.hasAnyGoal});

  final bool hasAnyGoal;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.today_outlined, size: 64),
          const SizedBox(height: 12),
          const Text('今天没有进行中的目标'),
          const SizedBox(height: 4),
          Text(hasAnyGoal ? '所有目标已结束或归档' : '创建一个目标，开始倒计时'),
          const SizedBox(height: 16),
          if (!hasAnyGoal)
            FilledButton.icon(
              onPressed: () => GoalFormDialog.show(context),
              icon: const Icon(Icons.add),
              label: const Text('创建目标'),
            ),
        ],
      ),
    );
  }
}
