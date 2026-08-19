import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';

/// 计划偏好数据访问层（PRD §9 Settings，M2 子集）。
///
/// 单行表（id 固定为 1）。默认行由 [get] 惰性 seed（insertOrIgnore），
/// 保证迁移库与全新安装行为一致；日常读取默认行已存在，不触发写库。
class SettingsRepository {
  SettingsRepository(this._db, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() clock;

  static const int _singletonId = 1;

  /// 读取计划偏好；首次调用时写入默认行（每天 120 分钟、每周 7 天，PRD §5.1）。
  ///
  /// 用 insertOrIgnore 惰性 seed：并发首次调用时只有一个写入成功，
  /// 其余走读取路径，避免 UNIQUE 约束竞态异常。
  Future<Setting> get() async {
    final existing = await _byId();
    if (existing != null) return existing;

    final now = clock().toUtc();
    await _db.into(_db.settings).insert(
      SettingsCompanion.insert(
        id: Value(_singletonId),
        createdAt: now,
        updatedAt: now,
      ),
      mode: InsertMode.insertOrIgnore,
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

  /// 更新关闭按钮行为（FR-8.1：exit / minimize_to_tray）。
  Future<void> updateCloseBehavior(String behavior) {
    return _update(SettingsCompanion(
      closeBehavior: Value(behavior),
    ));
  }

  /// 更新每日自动备份开关（FR-9.4，schema v9）。
  Future<void> updateAutoBackupEnabled(bool enabled) {
    return _update(SettingsCompanion(
      autoBackupEnabled: Value(enabled),
    ));
  }

  /// 更新本地自动备份目录（FR-9.4，schema v9）。
  ///
  /// 传入 null 表示清空（禁用该目的地）。
  Future<void> updateLocalBackupFolder(String? folder) {
    return _update(SettingsCompanion(
      localBackupFolder: Value(folder),
    ));
  }

  /// 更新上次自动备份完成时间（FR-9.4，schema v9）。
  ///
  /// [utc] 传 null 表示「从未成功备份」（例如用户清除密码后重置）。
  Future<void> updateLastAutoBackupAt(DateTime? utc) {
    return _update(SettingsCompanion(
      lastAutoBackupAt: Value(utc),
    ));
  }

  /// 更新主题模式（M10，schema v12）。
  ///
  /// [mode] 取值与 [ThemeMode.name] 一致：`system`/`light`/`dark`。
  Future<void> updateThemeMode(String mode) {
    return _update(SettingsCompanion(
      themeMode: Value(mode),
    ));
  }

  /// 更新主题色系（2026-08-16 色系解耦，schema v14）。
  ///
  /// [accentColor] 取值见 `AccentPalette.id`：`green`/`blue`。
  Future<void> updateAccentColor(String accentColor) {
    return _update(SettingsCompanion(
      accentColor: Value(accentColor),
    ));
  }

  Future<void> _update(SettingsCompanion companion) {
    return _db.transaction(() async {
      // 更新前确保默认行存在（极端场景：从未调用过 get 直接更新）。
      await get();
      await (_db.update(_db.settings)..where((s) => s.id.equals(_singletonId)))
          .write(companion.copyWith(updatedAt: Value(clock().toUtc())));
    });
  }

  Future<Setting?> _byId() {
    return (_db.select(_db.settings)..where((s) => s.id.equals(_singletonId)))
        .getSingleOrNull();
  }

  /// 解析每周可用日文本（逗号分隔 ISO 星期）。
  ///
  /// 过滤 1~7 范围外的脏值（L33）：DB 异常值（0/9 等）不流入负载/延期
  /// 计算，也不回写。
  static Set<int> decodeWeekdays(String encoded) {
    if (encoded.trim().isEmpty) return {};
    return encoded
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((d) => d >= 1 && d <= 7)
        .toSet();
  }

  /// 计划偏好默认值（PRD §5.1）。
  static int get defaultDailyAvailableMinutes =>
      SettingsDefaults.dailyAvailableMinutes;
}
