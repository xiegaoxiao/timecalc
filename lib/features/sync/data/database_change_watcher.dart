import 'dart:async';

import '../../../core/database/database.dart';

/// 业务表变更监听（M9「变更后推送」的数据源）。
///
/// drift 不暴露公开的全局表更新流（内部 StreamQueryStore 为 @internal），
/// 唯一公开路径是各表的 `managers.<table>.watch()`——每张表一条流，合并后
/// 经 [debounce] 收敛触发回调。订阅即发一次初始行，用 `skip(1)` 跳过，
/// 只对真实写入响应。
///
/// **不监听 settings 表**：同步服务每次推送后写 last_pushed_seq/
/// last_synced_at 会再次触发监听，形成「推送→写 settings→推送」回环。
/// settings 中进入备份的只有计划偏好（dailyAvailableMinutes/可用星期），
/// 由启动拉取/周期同步/手动/退出推送覆盖（≤5 分钟），不回环。其余列
/// 均为运行时配置、本就不进备份。
///
/// 不引入 async/StreamGroup 依赖（S0：无新增直接依赖），手动转发合并。
class DatabaseChangeWatcher {
  DatabaseChangeWatcher(
    AppDatabase db, {
    this.debounce = const Duration(seconds: 3),
    required this.onChanged,
  }) {
    final controller = StreamController<void>.broadcast();
    final managers = db.managers;
    for (final stream in [
      managers.goals.watch(),
      managers.subjects.watch(),
      managers.milestones.watch(),
      managers.tasks.watch(),
      managers.recurrenceTemplates.watch(),
      managers.checklistItems.watch(),
    ]) {
      _subscriptions.add(stream.skip(1).listen((_) => controller.add(null)));
    }
    _subscriptions.add(controller.stream.listen((_) {
      _timer?.cancel();
      _timer = Timer(debounce, onChanged);
    }));
  }

  /// 变更触发后延迟执行的推送回调（窗口内多次写入合并为一次推送）。
  final Duration debounce;
  final void Function() onChanged;

  final List<StreamSubscription<void>> _subscriptions = [];
  Timer? _timer;

  /// 取消全部表订阅与待触发的延迟推送。
  void dispose() {
    _timer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }
}
