import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';

/// SettingsRepository 内存数据库测试（PRD §5.1 / §9 Settings）。
void main() {
  late AppDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('首次 get 惰性 seed 默认行：每天 120 分钟、每周 7 天（PRD §5.1）', () async {
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, SettingsDefaults.dailyAvailableMinutes);
    expect(
      SettingsRepository.decodeWeekdays(settings.availableWeekdays),
      SettingsDefaults.availableWeekdays,
    );
  });

  test('重复 get 只返回单行，不重复 seed', () async {
    await repo.get();
    await repo.get();
    final rows = await db.select(db.settings).get();
    expect(rows.length, 1);
  });

  test('更新每日可用时长并持久化', () async {
    await repo.updateDailyAvailableMinutes(90);
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, 90);
  });

  test('更新每周可用日按 ISO 星期升序编码并持久化', () async {
    await repo.updateAvailableWeekdays({7, 1, 5});
    final settings = await repo.get();
    expect(settings.availableWeekdays, '1,5,7');
    expect(SettingsRepository.decodeWeekdays(settings.availableWeekdays), {1, 5, 7});
  });

  test('更新可用日后再更新时长，两者互不覆盖', () async {
    await repo.updateAvailableWeekdays({1, 2, 3, 4, 5});
    await repo.updateDailyAvailableMinutes(150);
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, 150);
    expect(SettingsRepository.decodeWeekdays(settings.availableWeekdays), {1, 2, 3, 4, 5});
  });

  test('decodeWeekdays 对非法输入返回空集合', () {
    expect(SettingsRepository.decodeWeekdays(''), isEmpty);
    expect(SettingsRepository.decodeWeekdays('abc'), isEmpty);
  });

  test('并发首次 get 不抛约束异常（insertOrIgnore，回归）', () async {
    final results = await Future.wait([repo.get(), repo.get(), repo.get()]);
    expect(results, hasLength(3));
    expect(results.every((s) => s.dailyAvailableMinutes == 120), isTrue);
    // 仍只有单行。
    final rows = await db.select(db.settings).get();
    expect(rows.length, 1);
  });

  test('默认关闭行为为 exit（FR-8.1 默认直接退出）', () async {
    final settings = await repo.get();
    expect(settings.closeBehavior, CloseBehavior.exit);
  });

  test('更新关闭行为为最小化到托盘并持久化', () async {
    await repo.updateCloseBehavior(CloseBehavior.minimizeToTray);
    final settings = await repo.get();
    expect(settings.closeBehavior, CloseBehavior.minimizeToTray);
  });

  test('更新关闭行为不影响计划偏好', () async {
    await repo.updateDailyAvailableMinutes(90);
    await repo.updateCloseBehavior(CloseBehavior.minimizeToTray);
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, 90);
    expect(settings.closeBehavior, CloseBehavior.minimizeToTray);
  });

  // ---- M8 自动备份配置（FR-9.4，schema v9）----

  test('默认自动备份关闭且无目的地配置', () async {
    final settings = await repo.get();
    expect(settings.autoBackupEnabled, isFalse);
    expect(settings.localBackupFolder, isNull);
    expect(settings.webdavUrl, isNull);
    expect(settings.webdavUsername, isNull);
    expect(settings.webdavPasswordSaved, isFalse);
    expect(settings.lastAutoBackupAt, isNull);
  });

  test('更新自动备份开关并持久化', () async {
    await repo.updateAutoBackupEnabled(true);
    final settings = await repo.get();
    expect(settings.autoBackupEnabled, isTrue);
  });

  test('更新本地备份目录（含清空）', () async {
    await repo.updateLocalBackupFolder(r'C:\Backups');
    expect((await repo.get()).localBackupFolder, r'C:\Backups');
    await repo.updateLocalBackupFolder(null);
    expect((await repo.get()).localBackupFolder, isNull);
  });

  test('更新 WebDAV 配置与密码标记', () async {
    await repo.updateWebDavConfig(url: 'https://dav.example.com/dav', username: 'alice');
    await repo.updateWebDavPasswordSaved(true);
    final settings = await repo.get();
    expect(settings.webdavUrl, 'https://dav.example.com/dav');
    expect(settings.webdavUsername, 'alice');
    expect(settings.webdavPasswordSaved, isTrue);
  });

  test('更新上次自动备份时间（UTC）', () async {
    final time = DateTime.utc(2026, 8, 6, 12);
    await repo.updateLastAutoBackupAt(time);
    // drift 读回为本地时区同一时刻（DateTime == 区分 isUtc，用 toUtc 比较）。
    expect((await repo.get()).lastAutoBackupAt?.toUtc(), time);
    await repo.updateLastAutoBackupAt(null);
    expect((await repo.get()).lastAutoBackupAt, isNull);
  });

  test('自动备份配置与计划偏好互不覆盖', () async {
    await repo.updateDailyAvailableMinutes(90);
    await repo.updateAutoBackupEnabled(true);
    await repo.updateLocalBackupFolder(r'C:\Backups');
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, 90);
    expect(settings.autoBackupEnabled, isTrue);
    expect(settings.localBackupFolder, r'C:\Backups');
  });

  test('默认 WebDAV 同步关闭且无同步状态（M9，schema v11）', () async {
    final settings = await repo.get();
    expect(settings.webdavSyncEnabled, isFalse);
    expect(settings.lastPushedSeq, isNull);
    expect(settings.lastSyncedAt, isNull);
  });

  test('更新同步开关并持久化', () async {
    await repo.updateSyncEnabled(true);
    expect((await repo.get()).webdavSyncEnabled, isTrue);
    await repo.updateSyncEnabled(false);
    expect((await repo.get()).webdavSyncEnabled, isFalse);
  });

  test('更新同步状态（seq + 时间），不覆盖同步开关', () async {
    await repo.updateSyncEnabled(true);
    final time = DateTime.utc(2026, 8, 7, 3, 30);
    await repo.updateSyncState(seq: 12, at: time);
    final settings = await repo.get();
    expect(settings.webdavSyncEnabled, isTrue);
    expect(settings.lastPushedSeq, 12);
    expect(settings.lastSyncedAt?.toUtc(), time);
  });

  test('同步状态与自动备份/计划偏好互不覆盖', () async {
    await repo.updateDailyAvailableMinutes(90);
    await repo.updateAutoBackupEnabled(true);
    await repo.updateSyncState(seq: 5, at: DateTime.now().toUtc());
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, 90);
    expect(settings.autoBackupEnabled, isTrue);
    expect(settings.lastPushedSeq, 5);
  });

  test('默认主题模式为跟随系统（M10，schema v12）', () async {
    final settings = await repo.get();
    expect(settings.themeMode, 'system');
  });

  test('更新主题模式为浅色/深色并持久化', () async {
    await repo.updateThemeMode('light');
    expect((await repo.get()).themeMode, 'light');
    await repo.updateThemeMode('dark');
    expect((await repo.get()).themeMode, 'dark');
    await repo.updateThemeMode('system');
    expect((await repo.get()).themeMode, 'system');
  });

  test('主题模式与计划偏好/同步状态互不覆盖', () async {
    await repo.updateDailyAvailableMinutes(90);
    await repo.updateThemeMode('dark');
    await repo.updateSyncState(seq: 3, at: DateTime.now().toUtc());
    final settings = await repo.get();
    expect(settings.dailyAvailableMinutes, 90);
    expect(settings.themeMode, 'dark');
    expect(settings.lastPushedSeq, 3);
  });
}
