import 'dart:async';

import 'auto_backup_service.dart';

/// 自动备份调度器（FR-9.4，M8）。
///
/// 桌面应用进程只在窗口/托盘存活时运行，因此采用「应用运行期间」语义：
/// - [start]：立即检查一次（启动补跑，距上次不足 1 天会自动跳过）；
/// - 之后每小时复查一次（[Timer.periodic]）；
/// - 失败通过 [onFailure] 回调通知（生产环境接
///   DesktopController.scaffoldMessengerKey 弹 SnackBar），
///   同一自然日内同类失败只提示一次，防止刷屏。
///
/// [dispose] 取消定时器（进程退出 / 测试结束时调用）。
class AutoBackupScheduler {
  AutoBackupScheduler({
    required this.service,
    required this.onFailure,
  });

  static const Duration _checkInterval = Duration(hours: 1);

  final AutoBackupRunner service;
  final Future<void> Function(String message) onFailure;
  Timer? _timer;
  String? _lastFailureDay;

  /// 是否已启动（测试断言用）。
  bool get isRunning => _timer != null;

  /// 启动调度：立即检查一次 + 每小时复查。
  void start() {
    if (_timer != null) return; // 幂等
    unawaited(_check());
    _timer = Timer.periodic(_checkInterval, (_) => unawaited(_check()));
  }

  /// 公开单次检查（测试用；正常流程只经 start 触发）。
  Future<void> checkNow() => _check();

  Future<void> _check() async {
    try {
      final result = await service.run();
      if (!result.hasError) {
        _lastFailureDay = null;
        return;
      }
      final message = '自动备份失败：${result.errors.join('；')}';
      final today = _dayKey(DateTime.now());
      if (today == _lastFailureDay) return; // 当日已提示过同类失败。
      _lastFailureDay = today;
      await onFailure(message);
    } catch (_) {
      // 调度本身的意外异常不上抛（不打断应用）；失败已由 run 内部归类。
    }
  }

  static String _dayKey(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month}-${local.day}';
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
