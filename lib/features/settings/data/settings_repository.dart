import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';

/// 计划偏好数据访问层（PRD §9 Settings，M2 子集）。
///
/// 单行表（id 固定为 1）。默认行由 [get] 惰性 seed（insertOrIgnore），
/// 保证迁移库与全新安装行为一致；日常读取默认行已存在，不触发写库。
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  static const int _singletonId = 1;

  /// 读取计划偏好；首次调用时写入默认行（每天 120 分钟、每周 7 天，PRD §5.1）。
  Future<Setting> get() async {
    final existing = await _byId();
    if (existing != null) return existing;

    final now = DateTime.now().toUtc();
    await _db.into(_db.settings).insert(
      SettingsCompanion.insert(
        id: Value(_singletonId),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return (await _byId())!;
  }

  /// 更新每日可用时长（分钟，1～1440 由校验层保证）。
  Future<void> updateDailyAvailableMinutes(int minutes) {
    return _update(SettingsCompanion(
      dailyAvailableMinutes: Value(minutes),
    ));
  }

  /// 更新每周可用日。按 ISO 星期（1=周一…7=周日）升序编码为逗号分隔文本。
  Future<void> updateAvailableWeekdays(Set<int> weekdays) {
    final sorted = weekdays.toList()..sort();
    return _update(SettingsCompanion(
      availableWeekdays: Value(sorted.join(',')),
    ));
  }

  Future<void> _update(SettingsCompanion companion) {
    return _db.transaction(() async {
      // 更新前确保默认行存在（极端场景：从未调用过 get 直接更新）。
      await get();
      await (_db.update(_db.settings)..where((s) => s.id.equals(_singletonId)))
          .write(companion.copyWith(updatedAt: Value(DateTime.now().toUtc())));
    });
  }

  Future<Setting?> _byId() {
    return (_db.select(_db.settings)..where((s) => s.id.equals(_singletonId)))
        .getSingleOrNull();
  }

  /// 解析每周可用日文本（逗号分隔 ISO 星期）。
  static Set<int> decodeWeekdays(String encoded) {
    if (encoded.trim().isEmpty) return {};
    return encoded
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
  }

  /// 计划偏好默认值（PRD §5.1）。
  static int get defaultDailyAvailableMinutes =>
      SettingsDefaults.dailyAvailableMinutes;
}
