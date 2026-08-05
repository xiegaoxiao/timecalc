import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// TimeCalc 本地数据库（schema v3）。
///
/// v1：目标/科目/任务三张表。
/// v2：Tasks 增加 original_planned_date；新增 Settings 计划偏好表（M2）。
/// v3：Tasks 增加 archived_at（JSON 导入替换时归档保留的历史记录）。
/// 后续 schema 变更必须提供 migration 与 migration 测试（SOP S3、NFR-2）。
@DriftDatabase(tables: [Goals, Subjects, Tasks, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 生产环境连接：使用 drift_flutter 的跨平台默认位置。
  factory AppDatabase.open() =>
      AppDatabase(driftDatabase(name: 'timecalc'));

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v1 -> v2：任务记录原计划日期；新增计划偏好表（M2）。
            // Settings 默认行不在此写入，由 SettingsRepository.get() 惰性 seed。
            await m.addColumn(tasks, tasks.originalPlannedDate);
            await m.createTable(settings);
          }
          if (from < 3) {
            // v2 -> v3：任务增加归档标记（JSON 导入替换保留历史）。
            await m.addColumn(tasks, tasks.archivedAt);
          }
        },
      );
}
