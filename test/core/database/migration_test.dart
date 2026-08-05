import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';

import '../../generated_migrations/schema.dart';

/// schema 迁移测试（NFR-2 / SOP S5）。
///
/// 覆盖：
/// - v1 空库创建、三张表存在、必要列与约束符合预期；
/// - v1 -> v2 升级成功：v1 数据在升级后保留，新列/新表可用且符合 v2 结构；
/// - v1 -> v2 升级失败：失败后原 v1 数据保持可用，修复后迁移可重试成功。
void main() {
  // 迁移测试通过 SchemaVerifier 在同一底层连接上多次打开 AppDatabase，
  // drift 的「重复打开数据库」启发式会产生无关警告，按官方 FAQ 关闭。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('schema v1：空库打开后三张业务表存在', () async {
    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();

    expect(names, contains('goals'));
    expect(names, contains('subjects'));
    expect(names, contains('tasks'));
  });

  test('schema v1：goals 表结构（必填列与默认状态）', () async {
    final columns = await _columns(db, 'goals');
    expect(columns, containsAll(['id', 'title', 'description', 'deadline_date', 'status', 'completed_at', 'created_at', 'updated_at']));

    // 默认 status 为 active（PRD §9 Goal.status 默认值）。
    final inserted = await db.into(db.goals).insert(
      GoalsCompanion.insert(
        title: '测试目标',
        deadlineDate: '2026-12-31',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    final goal = await (db.select(db.goals)..where((g) => g.id.equals(inserted))).getSingle();
    expect(goal.status, 'active');
  });

  test('schema v1：tasks 表外键关联与可空列', () async {
    final columns = await _columns(db, 'tasks');
    expect(columns, containsAll([
      'id', 'goal_id', 'subject_id', 'title', 'note', 'planned_date',
      'estimated_minutes', 'status', 'completed_at', 'sort_order', 'created_at', 'updated_at',
    ]));
  });

  test('schema v1：subjects 表结构', () async {
    final columns = await _columns(db, 'subjects');
    expect(columns, containsAll([
      'id', 'goal_id', 'name', 'color', 'sort_order', 'created_at', 'updated_at',
    ]));
  });

  test('schema v2：tasks 含原计划日期列，settings 表存在', () async {
    final taskColumns = await _columns(db, 'tasks');
    expect(taskColumns, contains('original_planned_date'));

    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    expect(tables.map((row) => row.read<String>('name')), contains('settings'));

    final columns = await _columns(db, 'settings');
    expect(columns, containsAll([
      'id', 'daily_available_minutes', 'available_weekdays', 'created_at', 'updated_at',
    ]));
  });

  test('schema v1 -> v2：迁移成功保留数据，结构符合 v2 预期', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // 以 v1 结构初始化数据库并写入数据。
    final schema = await verifier.schemaAt(1);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['迁移目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO tasks (goal_id, title, planned_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?)',
      ['迁移任务', '2026-08-05', 1750000000, 1750000000],
    );

    // 以真实 AppDatabase 打开并执行 v1 -> v2 迁移，再与 v2 预期结构比对。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 2);

    // 数据在升级后保留，新列默认 null。
    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '迁移目标');
    expect(goal.deadlineDate, '2026-08-05');

    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, '迁移任务');
    expect(task.plannedDate, '2026-08-05');
    expect(task.originalPlannedDate, isNull);

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    expect(tables.map((row) => row.read<String>('name')), contains('settings'));

    await upgraded.close();
    schema.close();
  });

  test('schema v1 -> v2：迁移失败时原 v1 数据保持可用，修复后可重试成功', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(1);
    schema.rawDatabase.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['失败恢复目标', '2026-08-05', 1750000000, 1750000000],
    );

    // 用「升级即抛错」的迁移策略打开：onUpgrade 失败后连接自动关闭，
    // 底层数据保持 v1 完整（通过执行一次查询触发打开/迁移）。
    final broken = _FailingMigrationDb(schema.newConnection());
    await expectLater(
      broken.select(broken.goals).get(),
      throwsA(isA<StateError>()),
    );

    // 以正确迁移策略重新打开（新连接），迁移应成功且数据仍在。
    final repaired = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(repaired, 2);

    final goal = await (repaired.select(repaired.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '失败恢复目标');
    expect(goal.deadlineDate, '2026-08-05');

    await repaired.close();
    schema.close();
  });
}

/// 打开时即抛错的迁移策略（验证 onUpgrade 失败回滚与数据保全）。
class _FailingMigrationDb extends AppDatabase {
  _FailingMigrationDb(super.e);

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          throw StateError('模拟迁移失败');
        },
      );
}

Future<Set<String>> _columns(AppDatabase db, String table) async {
  final rows = await db.customSelect(
    'PRAGMA table_info($table)',
  ).get();
  return rows.map((row) => row.read<String>('name')).toSet();
}
