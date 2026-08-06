import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'migration.dart' as migration_steps;
import 'tables.dart';

part 'database.g.dart';

/// 幂等地给表加列：列已存在（半迁移/手工补列/重复升级场景）则跳过。
///
/// 背景：drift 的 [Migrator.addColumn] 直接执行 `ALTER TABLE ... ADD COLUMN`，
/// 若列已存在（例如开发过程中手工补列但 `PRAGMA user_version` 落后，或
/// 迁移中途失败后列已写入）会抛「duplicate column name」。每个加列步骤
/// 先查 `PRAGMA table_info` 再决定是否执行，使迁移可重复/可恢复
/// （NFR-2：升级失败后原库可继续使用并修复）。
Future<void> addColumnIfMissing(
  Migrator m,
  TableInfo table,
  GeneratedColumn column,
) async {
  final rows = await m.database
      .customSelect('PRAGMA table_info(${table.aliasedName})')
      .get();
  final existing = rows.map((row) => row.read<String>('name')).toSet();
  if (existing.contains(column.name)) return;
  await m.addColumn(table, column);
}

/// TimeCalc 本地数据库（schema v6）。
///
/// v1：目标/科目/任务三张表。
/// v2：Tasks 增加 original_planned_date；新增 Settings 计划偏好表（M2）。
/// v3：Tasks 增加 archived_at（JSON 导入替换时归档保留的历史记录）。
/// v4：Tasks 增加 recurrence_template_id；新增 RecurrenceTemplates 表（FR-4）。
/// v5：RecurrenceTemplates 增加 deleted_instance_dates（删除实例墓碑，
///     滚动生成跳过已删除日期，防止被删实例复活）。
/// v6：Settings 增加 close_behavior（FR-8.1 关闭按钮行为：退出/最小化到托盘）。
/// v7：新增 Milestones 里程碑表（FR-2 目标下的阶段性节点）。
/// 后续 schema 变更必须提供 migration 与 migration 测试（SOP S3、NFR-2）。
@DriftDatabase(tables: [Goals, Subjects, Milestones, Tasks, Settings, RecurrenceTemplates])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 生产环境连接：使用 drift_flutter 的跨平台默认位置。
  factory AppDatabase.open() =>
      AppDatabase(driftDatabase(name: 'timecalc'));

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        // 使用 drift 生成的 step-by-step 迁移：每个步骤使用「目标版本」的
        // 表结构快照（drift_dev schema steps 生成），确保建表/加列与历史
        // schema 完全一致（例如 v4 建 recurrence_templates 时不含 v5 新列）。
        onUpgrade: migration_steps.stepByStep(
          from1To2: (m, schema) async {
            // v1 -> v2：任务记录原计划日期；新增计划偏好表（M2）。
            // Settings 默认行不在此写入，由 SettingsRepository.get() 惰性 seed。
            // createTable 自带 IF NOT EXISTS；加列用幂等 helper 防半迁移重复。
            await addColumnIfMissing(
              m,
              schema.tasks,
              schema.tasks.originalPlannedDate,
            );
            await m.createTable(schema.settings);
          },
          from2To3: (m, schema) async {
            // v2 -> v3：任务增加归档标记（JSON 导入替换保留历史）。
            await addColumnIfMissing(m, schema.tasks, schema.tasks.archivedAt);
          },
          from3To4: (m, schema) async {
            // v3 -> v4：任务关联重复模板；新增重复模板表（FR-4）。
            await addColumnIfMissing(
              m,
              schema.tasks,
              schema.tasks.recurrenceTemplateId,
            );
            await m.createTable(schema.recurrenceTemplates);
          },
          from4To5: (m, schema) async {
            // v4 -> v5：重复模板增加删除实例墓碑列（防止被删实例复活）。
            await addColumnIfMissing(
              m,
              schema.recurrenceTemplates,
              schema.recurrenceTemplates.deletedInstanceDates,
            );
          },
          from5To6: (m, schema) async {
            // v5 -> v6：设置增加关闭按钮行为列（FR-8.1，退出/最小化到托盘）。
            await addColumnIfMissing(
              m,
              schema.settings,
              schema.settings.closeBehavior,
            );
          },
          from6To7: (m, schema) async {
            // v6 -> v7：新增里程碑表（FR-2 目标下的阶段性节点）。
            // createTable 自带 IF NOT EXISTS，重复升级/半迁移安全。
            await m.createTable(schema.milestones);
          },
        ),
      );
}
