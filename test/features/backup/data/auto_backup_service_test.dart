import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/backup/data/auto_backup_service.dart';
import 'package:timecalc/features/backup/data/backup_service.dart';
import 'package:timecalc/features/backup/data/backup_target.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';

/// AutoBackupService 测试（M8，FR-9.4；M11 目的地收敛为本地目录；
/// 2026-08 移除全部 WebDAV 后仅剩本地目录）。
///
/// 覆盖：
/// - 未启用 / 未配置目的地 / 距上次不足 24h → 跳过；
/// - 成功：导出 zip 落本地目录 + 推进 last_auto_backup_at；
/// - 失败不推进时间戳（本地目录失败整体失败）；
/// - 保留策略：只删 timecalc-auto-*、保留最新 7 份、不删手动导出。
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late BackupService backup;
  late Directory tempDir;

  Future<void> seedGoal() async {
    await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: '自动备份目标',
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
  }

  AutoBackupService service() => AutoBackupService(
        settingsRepository: settings,
        backupService: backup,
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
    backup = BackupService(db);
    tempDir = Directory.systemTemp.createTempSync('timecalc-auto-test');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('未启用自动备份时跳过', () async {
    final result = await service().run();
    expect(result.skipped, isTrue);
    expect(result.skipReason, contains('未开启'));
  });

  test('已启用但未配置目的地时跳过', () async {
    await settings.updateAutoBackupEnabled(true);
    final result = await service().run();
    expect(result.skipped, isTrue);
    expect(result.skipReason, contains('未配置备份目的地'));
  });

  test('成功备份到本地目录并推进上次备份时间', () async {
    await seedGoal();
    await settings.updateAutoBackupEnabled(true);
    await settings.updateLocalBackupFolder(tempDir.path);

    final result = await service().run(now: DateTime.utc(2026, 8, 6, 1));
    expect(result.skipped, isFalse);
    expect(result.succeeded, isTrue);
    expect(result.uploadedTargets, 1);

    // 文件已落盘且带自动备份前缀。
    final files = Directory(tempDir.path).listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.uri.pathSegments.last, startsWith('timecalc-auto-'));

    // 时间戳推进（drift 读回本地时区，同一时刻）。
    expect(
      (await settings.get()).lastAutoBackupAt?.toUtc(),
      DateTime.utc(2026, 8, 6, 1),
    );
  });

  test('距上次成功不足 24 小时时跳过（每日语义）', () async {
    await seedGoal();
    await settings.updateAutoBackupEnabled(true);
    await settings.updateLocalBackupFolder(tempDir.path);
    await settings.updateLastAutoBackupAt(DateTime.utc(2026, 8, 6, 0));

    final result = await service().run(now: DateTime.utc(2026, 8, 6, 20));
    expect(result.skipped, isTrue);
    expect(result.skipReason, contains('不足 24 小时'));
  });

  test('force 跳过 24 小时判据但未启用仍跳过', () async {
    await seedGoal();
    await settings.updateAutoBackupEnabled(true);
    await settings.updateLocalBackupFolder(tempDir.path);
    await settings.updateLastAutoBackupAt(DateTime.utc(2026, 8, 6, 0));

    final result = await service().run(force: true, now: DateTime.utc(2026, 8, 6, 20));
    expect(result.skipped, isFalse);
    expect(result.succeeded, isTrue);

    // 未启用时 force 也跳过。
    await settings.updateAutoBackupEnabled(false);
    final disabled = await service().run(force: true, now: DateTime.utc(2026, 8, 6, 21));
    expect(disabled.skipped, isTrue);
  });

  test('失败不推进时间戳（本地目录不可写）', () async {
    await seedGoal();
    await settings.updateAutoBackupEnabled(true);
    // 目标路径是文件而非目录 → 写入失败。
    final blocked = File('${tempDir.path}${Platform.pathSeparator}not-a-dir');
    blocked.writeAsStringSync('x');
    await settings.updateLocalBackupFolder(blocked.path);

    final result = await service().run(now: DateTime.utc(2026, 8, 6, 1));
    expect(result.skipped, isFalse);
    expect(result.succeeded, isFalse);
    expect(result.errors, isNotEmpty);
    expect((await settings.get()).lastAutoBackupAt, isNull); // 未推进
  });

  test('本地目录写入失败时整体失败且不推进时间戳（M11 仅本地目的地）', () async {
    await seedGoal();
    await settings.updateAutoBackupEnabled(true);
    // 指向一个不可写路径（不存在的盘符），导出后上传失败。
    await settings.updateLocalBackupFolder(r'X:\不存在的目录');

    final result = await service().run(now: DateTime.utc(2026, 8, 6, 1));

    expect(result.succeeded, isFalse);
    expect(result.errors, hasLength(1));
    expect(result.errors.single, contains('本地目录'));
    expect((await settings.get()).lastAutoBackupAt, isNull); // 不推进
  });

  test('保留策略：只保留最新 7 份自动备份，不删手动导出', () async {
    await seedGoal();
    await settings.updateAutoBackupEnabled(true);
    await settings.updateLocalBackupFolder(tempDir.path);

    // 预置 9 份自动备份 + 1 份手动导出（字典序即时间序）。
    for (var i = 0; i < 9; i++) {
      final name = autoBackupFileName(
        DateTime(2026, 8, 1).add(Duration(days: i)),
      );
      await File('${tempDir.path}${Platform.pathSeparator}$name').writeAsBytes([1]);
    }
    File('${tempDir.path}${Platform.pathSeparator}manual-20260801.timecalc')
        .writeAsBytesSync([1]);

    // 触发一次备份：上传新文件后剪枝到 7 份。
    final result = await service().run(now: DateTime.utc(2026, 8, 6, 1));
    expect(result.succeeded, isTrue);

    final files = Directory(tempDir.path)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    final autos = files.where((f) => f.startsWith(autoBackupPrefix)).toList();
    // 最新 7 份保留（含刚上传的），最早 3 份被清理（8/1、8/2、8/3 上传的）。
    expect(autos, hasLength(7));
    expect(autos, contains('timecalc-auto-20260809-000000.timecalc')); // 最新保留
    expect(autos, isNot(contains('timecalc-auto-20260801-000000.timecalc'))); // 最老被清
    expect(files, contains('manual-20260801.timecalc')); // 手动导出不受影响
  });
}
