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
}
