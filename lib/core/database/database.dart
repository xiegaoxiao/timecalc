import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// TimeCalc 本地数据库（schema v1）。
///
/// M1 承载目标/科目/任务三张表。后续 schema 变更必须提供
/// migration 与 migration 测试（SOP S3、NFR-2）。
@DriftDatabase(tables: [Goals, Subjects, Tasks])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 生产环境连接：使用 drift_flutter 的跨平台默认位置。
  factory AppDatabase.open() =>
      AppDatabase(driftDatabase(name: 'timecalc'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // schema v1 之后每次升级在此追加迁移步骤，并配套 migration 测试。
        },
      );
}
