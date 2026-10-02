import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../goals/presentation/goal_form_dialog.dart';
import '../../goals/presentation/goal_list_page.dart';
import 'calendar_view.dart';

/// 计划页（M2）：日历 / 目标 分段视图。
///
/// 默认展示「目标」分段（保持 M1 计划页行为），可在「日历」分段查看
/// 月历负载与选日任务（FR-3.4）。
class PlanPage extends ConsumerStatefulWidget {
  const PlanPage({super.key});

  @override
  ConsumerState<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends ConsumerState<PlanPage> {
  static const _calendarIndex = 0;
  static const _goalsIndex = 1;

  int _segment = _goalsIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('计划')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: _calendarIndex,
                  label: Text('日历'),
                  icon: Icon(Icons.calendar_month_outlined),
                ),
                ButtonSegment(
                  value: _goalsIndex,
                  label: Text('目标'),
                  icon: Icon(Icons.flag_outlined),
                ),
              ],
              selected: {_segment},
              onSelectionChanged: (selection) =>
                  setState(() => _segment = selection.first),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _segment,
              children: const [
                CalendarView(),
                _GoalSegment(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 目标分段：目标列表主体 + 创建目标 FAB（与独立 GoalListPage 行为一致）。
class _GoalSegment extends ConsumerWidget {
  const _GoalSegment();

  Future<void> _createGoal(BuildContext context) async {
    final createdId = await GoalFormDialog.show(context);
    if (createdId != null && context.mounted) {
      context.push('/goals/$createdId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        Positioned.fill(
          child: GoalListBody(onCreateGoal: () => _createGoal(context)),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: () => _createGoal(context),
            tooltip: '创建目标',
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}
