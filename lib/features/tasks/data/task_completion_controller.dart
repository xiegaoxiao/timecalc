import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../goals/data/goal_repository_provider.dart';
import 'task_repository_provider.dart';

/// 任务完成「5 秒撤回」批次控制器（Telegram 删除式交互，仅今天页启用）。
///
/// 勾选任务不再立即写库，而是先进入本控制器的待完成批次：
/// - 5 秒内再勾选其他任务 → 并入同一批次，并重置计时（滚动窗口）；
/// - 用户点「撤回」→ 整批任务保持未完成（本就不曾写库，直接清空）；
/// - 5 秒无撤回 → [finalize] 把整批一次性写入完成并刷新数据。
///
/// 这样「过期任务」勾选后仍留在区块并保持勾选态，5 秒后才消失——
/// 与 Telegram 删除消息 5 秒内可撤回、到时自动生效的交互一致。
class TaskCompletionController extends Notifier<Set<int>> {
  /// 撤回窗口时长（勾选 → 自动完成）。
  static const Duration undoWindow = Duration(seconds: 5);

  Timer? _finalizeTimer;

  @override
  Set<int> build() {
    ref.onDispose(_cancelTimer);
    return const {};
  }

  /// 是否处于待完成（未定稿）状态。
  bool isPending(int taskId) => state.contains(taskId);

  /// 勾选任务：加入待完成批次并重置 5 秒计时。
  void check(int taskId) {
    if (state.contains(taskId)) return;
    state = {...state, taskId};
    _restartTimer();
  }

  /// 单独撤回某任务（勾选后再次取消勾选）：移出批次，不写库。
  void remove(int taskId) {
    if (!state.contains(taskId)) return;
    final next = {...state}..remove(taskId);
    state = next;
    if (next.isEmpty) _cancelTimer();
  }

  /// 整批撤回：清空批次（任务从未写库，保持未完成即可）。
  void undo() {
    _cancelTimer();
    state = const {};
  }

  /// 5 秒计时到：整批写入完成并刷新。
  Future<void> finalize() async {
    _cancelTimer();
    final ids = state.toList();
    if (ids.isEmpty) return;
    state = const {};
    final repo = ref.read(taskRepositoryProvider);
    try {
      await repo.setDoneMany(ids, true);
    } catch (_) {
      // 后台定时器没有页面 context 可弹窗：写库失败时任务保持未完成，
      // 刷新后 UI 恢复未勾选（事务保证无半写入，数据安全优先）。
    }
    _refresh();
  }

  void _restartTimer() {
    _cancelTimer();
    _finalizeTimer = Timer(undoWindow, finalize);
  }

  void _cancelTimer() {
    _finalizeTimer?.cancel();
    _finalizeTimer = null;
  }

  /// 定稿后的跨页数据刷新：与今天页此前用的 [invalidateAppData] 同口径
  /// （任务/日历/未完成横幅/目标列表/完成热力图/剩余工作量），保证今天页
  /// 勾选完成后目标列表的完成统计（goalCompletionProvider 依赖 goalListProvider）
  /// 与进度页图表同步更新。
  void _refresh() {
    ref.invalidate(taskListProvider);
    ref.invalidate(tasksByDateProvider);
    ref.invalidate(tasksByMonthProvider);
    ref.invalidate(unfinishedBeforeProvider);
    ref.invalidate(goalListProvider);
    ref.invalidate(completedTasksProvider);
    ref.invalidate(allTodoTasksProvider);
  }
}

/// 待完成批次（taskId 集合）Provider。
final taskCompletionControllerProvider =
    NotifierProvider<TaskCompletionController, Set<int>>(
  TaskCompletionController.new,
);
