import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/backup/data/auto_backup_scheduler.dart';
import 'package:timecalc/features/backup/data/auto_backup_service.dart';

/// AutoBackupScheduler 测试（M8，FR-9.4）。
///
/// 用注入的 [AutoBackupRunner] 假实现驱动调度器，验证：
/// - start 幂等（重复调用不叠加定时器）；
/// - 失败经 onFailure 通知，且同一自然日内只提示一次；
/// - 成功后重置失败去重（后续失败可再次提示）；
/// - dispose 取消定时器。
void main() {
  test('start 幂等 + dispose 停止', () {
    final scheduler = AutoBackupScheduler(
      service: _StubRunner(_success),
      onFailure: (_) async {},
    );
    scheduler.start();
    scheduler.start();
    scheduler.start();
    expect(scheduler.isRunning, isTrue);
    scheduler.dispose();
    expect(scheduler.isRunning, isFalse);
  });

  test('失败经 onFailure 通知，且同一自然日只提示一次', () async {
    final messages = <String>[];
    final scheduler = AutoBackupScheduler(
      service: _StubRunner(
        (_) async => const AutoBackupResult(
          skipped: false,
          succeeded: false,
          errors: ['本地目录：写入失败'],
        ),
      ),
      onFailure: (message) async => messages.add(message),
    );

    await scheduler.checkNow();
    await scheduler.checkNow(); // 同日内重复失败
    expect(messages, hasLength(1));
    expect(messages.single, contains('自动备份失败'));
  });

  test('成功后重置失败去重，后续失败可再次提示', () async {
    final messages = <String>[];
    var fail = true;
    final scheduler = AutoBackupScheduler(
      service: _StubRunner((_) async {
        if (fail) {
          return const AutoBackupResult(
            skipped: false,
            succeeded: false,
            errors: ['本地目录：磁盘写入失败'],
          );
        }
        return _success({});
      }),
      onFailure: (message) async => messages.add(message),
    );

    await scheduler.checkNow();
    expect(messages, hasLength(1));

    fail = false; // 下一次成功
    await scheduler.checkNow();
    expect(messages, hasLength(1)); // 成功不新增

    fail = true; // 再失败（模拟次日语义）
    await scheduler.checkNow();
    expect(messages, hasLength(2));
  });

  test('跳过（非失败）不触发 onFailure', () async {
    final messages = <String>[];
    final scheduler = AutoBackupScheduler(
      service: _StubRunner(
        (_) async => const AutoBackupResult(
          skipped: true,
          succeeded: false,
          skipReason: '未开启',
        ),
      ),
      onFailure: (message) async => messages.add(message),
    );
    await scheduler.checkNow();
    expect(messages, isEmpty);
  });
}

Future<AutoBackupResult> _success(Map<String, dynamic> args) async =>
    const AutoBackupResult(skipped: false, succeeded: true);

/// 可编程返回结果的 AutoBackupRunner 假实现。
class _StubRunner implements AutoBackupRunner {
  _StubRunner(this._handler);

  final Future<AutoBackupResult> Function(Map<String, dynamic> args) _handler;

  @override
  Future<AutoBackupResult> run({bool force = false, DateTime? now}) {
    return _handler({'force': force, 'now': now});
  }
}
