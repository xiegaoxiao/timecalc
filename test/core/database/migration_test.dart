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
/// - v1 -> v3 升级成功：v1 数据在升级后保留，新列/新表可用且符合 v3 结构；
/// - v2 -> v3 升级成功：v2 数据保留，archived_at 默认 null；
/// - 升级失败：失败后原数据保持可用，修复后迁移可重试成功。
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

  test('schema v3：tasks 含归档标记列', () async {
    final taskColumns = await _columns(db, 'tasks');
    expect(taskColumns, contains('archived_at'));
  });

  test('schema v4：tasks 含重复模板关联列，recurrence_templates 表存在', () async {
    final taskColumns = await _columns(db, 'tasks');
    expect(taskColumns, contains('recurrence_template_id'));

    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    expect(tables.map((row) => row.read<String>('name')), contains('recurrence_templates'));

    final columns = await _columns(db, 'recurrence_templates');
    expect(columns, containsAll([
      'id', 'goal_id', 'subject_id', 'title', 'estimated_minutes',
      'rule_type', 'rule_json', 'start_date', 'end_date', 'active',
      'generated_through_date', 'created_at', 'updated_at',
    ]));
  });

  test('schema v5：recurrence_templates 含删除实例墓碑列', () async {
    final columns = await _columns(db, 'recurrence_templates');
    expect(columns, contains('deleted_instance_dates'));
  });

  test('schema v6：settings 含关闭按钮行为列（默认 exit）', () async {
    final columns = await _columns(db, 'settings');
    expect(columns, contains('close_behavior'));

    // 默认值为 exit（FR-8.1：默认直接退出）。
    final inserted = await db.into(db.settings).insert(
      SettingsCompanion.insert(
        id: const Value(1),
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    final settings = await (db.select(db.settings)
          ..where((s) => s.id.equals(inserted)))
        .getSingle();
    expect(settings.closeBehavior, 'exit');
  });

  test('schema v1 -> v6：迁移成功保留数据，结构符合 v6 预期', () async {
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

    // 以真实 AppDatabase 打开并执行 v1 -> v6 迁移，再与 v6 预期结构比对。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 6);

    // 数据在升级后保留，新列默认 null。
    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '迁移目标');
    expect(goal.deadlineDate, '2026-08-05');

    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, '迁移任务');
    expect(task.plannedDate, '2026-08-05');
    expect(task.originalPlannedDate, isNull);
    expect(task.archivedAt, isNull);
    expect(task.recurrenceTemplateId, isNull);

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(names, containsAll(['settings', 'recurrence_templates']));

    await upgraded.close();
    schema.close();
  });

  test('schema v2 -> v6：v2 数据保留，新列默认 null', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // 以 v2 结构初始化数据库并写入数据（含 settings 默认行）。
    final schema = await verifier.schemaAt(2);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v2 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO tasks (goal_id, title, planned_date, original_planned_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?, ?)',
      ['v2 任务', '2026-08-06', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 6);

    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, 'v2 任务');
    expect(task.plannedDate, '2026-08-06');
    expect(task.originalPlannedDate, '2026-08-05');
    expect(task.archivedAt, isNull);
    expect(task.recurrenceTemplateId, isNull);

    // 用原始 SQL 读取 settings（中间版本库没有 v9 新增列，typed 读取会
    // 因缺列 map 失败；这里只断言 v6 已存在的列）。
    final settingsRow = await upgraded.customSelect(
      'SELECT daily_available_minutes, close_behavior FROM settings WHERE id = 1',
    ).getSingle();
    expect(settingsRow.read<int>('daily_available_minutes'), 120);
    // v2 行升级后 close_behavior 取默认值 exit。
    expect(settingsRow.read<String>('close_behavior'), 'exit');

    await upgraded.close();
    schema.close();
  });

  test('schema v1 -> v6：迁移失败时原 v1 数据保持可用，修复后可重试成功', () async {
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
    await verifier.migrateAndValidate(repaired, 6);

    final goal = await (repaired.select(repaired.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '失败恢复目标');
    expect(goal.deadlineDate, '2026-08-05');

    await repaired.close();
    schema.close();
  });

  test('schema v3 -> v6：v3 数据保留，重复列/表就绪', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(3);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v3 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO tasks (goal_id, title, planned_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?)',
      ['v3 任务', '2026-08-06', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 6);

    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, 'v3 任务');
    expect(task.recurrenceTemplateId, isNull);

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    expect(tables.map((row) => row.read<String>('name')), contains('recurrence_templates'));

    await upgraded.close();
    schema.close();
  });

  test('schema v4 -> v6：v4 数据保留，墓碑列默认 null', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(4);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v4 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO tasks (goal_id, title, planned_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?)',
      ['v4 任务', '2026-08-06', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO recurrence_templates '
      '(goal_id, title, rule_type, rule_json, start_date, generated_through_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?, ?, ?, ?)',
      ['v4 模板', 'daily', '{}', '2026-08-06', '2026-09-04', 1750000000, 1750000000],
    );

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 6);

    // 任务与模板数据保留；新墓碑列默认 null。
    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, 'v4 任务');

    final template = await upgraded.select(upgraded.recurrenceTemplates).getSingle();
    expect(template.title, 'v4 模板');
    expect(template.deletedInstanceDates, isNull);

    await upgraded.close();
    schema.close();
  });

  test('schema v5 -> v6：v5 数据保留，关闭行为列默认 exit', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(5);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v5 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 6);

    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, 'v5 目标');

    // 原始 SQL 读取（中间版本库缺 v9 新列，见 v2 -> v6 用例注释）。
    final settingsRow = await upgraded.customSelect(
      'SELECT close_behavior FROM settings WHERE id = 1',
    ).getSingle();
    expect(settingsRow.read<String>('close_behavior'), 'exit');

    await upgraded.close();
    schema.close();
  });

  test('半迁移状态：v4 版本号但 v5 列已存在时迁移可重复成功（幂等回归）', () async {
    // 复现真实缺陷：开发库 user_version=4，但 recurrence_templates 已含
    // deleted_instance_dates（drift v5 迁移已执行过，版本号却落后）。
    // 旧实现 from4To5 再次 addColumn 抛「duplicate column name」。
    //
    // 用 drift 自己的 v5 快照建库（列定义与 v5 完全一致），再把版本号
    // 重置为 4，精确模拟该半迁移状态。
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(5);
    final raw = schema.rawDatabase;
    raw.execute('PRAGMA user_version = 4'); // 模拟版本号落后
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['半迁移目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO tasks (goal_id, title, planned_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?)',
      ['半迁移任务', '2026-08-06', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO recurrence_templates '
      '(goal_id, title, rule_type, rule_json, start_date, generated_through_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?, ?, ?, ?)',
      ['半迁移模板', 'daily', '{}', '2026-08-06', '2026-09-04', 1750000000, 1750000000],
    );

    // 旧实现在此抛 SqliteException(duplicate column name)；幂等实现应成功。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 6);

    // 迁移成功且数据保留；既有 v5 列未被重建破坏，v6 新列正确补上。
    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '半迁移目标');
    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, '半迁移任务');
    final template = await upgraded.select(upgraded.recurrenceTemplates).getSingle();
    expect(template.title, '半迁移模板');
    expect(template.deletedInstanceDates, isNull); // 既有列保留
    // 原始 SQL 读取（中间版本库缺 v9 新列，见 v2 -> v6 用例注释）。
    final settingsRow = await upgraded.customSelect(
      'SELECT close_behavior FROM settings WHERE id = 1',
    ).getSingle();
    expect(settingsRow.read<String>('close_behavior'), 'exit'); // v6 新列补上

    await upgraded.close();
    schema.close();
  });

  test('schema v3 -> v6：迁移失败时原 v3 数据保持可用，修复后可重试成功', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(3);
    schema.rawDatabase.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['失败恢复目标', '2026-08-05', 1750000000, 1750000000],
    );

    final broken = _FailingMigrationDb(schema.newConnection());
    await expectLater(
      broken.select(broken.goals).get(),
      throwsA(isA<StateError>()),
    );

    final repaired = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(repaired, 6);

    final goal = await (repaired.select(repaired.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '失败恢复目标');

    await repaired.close();
    schema.close();
  });

  test('schema v6 -> v7：里程碑表创建，v6 数据保留', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // 以 v6 结构初始化数据库并写入数据。
    final schema = await verifier.schemaAt(6);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v6 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );

    // 以真实 AppDatabase 打开并执行 v6 -> v7 迁移，再与 v7 预期结构比对。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 7);

    // v6 数据保留。
    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, 'v6 目标');
    expect(goal.deadlineDate, '2026-08-05');

    // v7 新表存在且可写入（含外键关联目标）。
    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(names, contains('milestones'));

    await upgraded.into(upgraded.milestones).insert(
          MilestonesCompanion.insert(
            goalId: 1,
            title: '里程碑一',
            date: '2026-08-01',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1750000000, isUtc: true),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1750000000, isUtc: true),
          ),
        );
    final milestone = await upgraded.select(upgraded.milestones).getSingle();
    expect(milestone.title, '里程碑一');
    expect(milestone.goalId, 1);
    expect(milestone.status, 'todo');

    await upgraded.close();
    schema.close();
  });

  test('schema v1 -> v7：迁移成功保留数据，里程碑表存在', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
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

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 7);

    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, '迁移目标');
    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, '迁移任务');

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(names, containsAll(['settings', 'recurrence_templates', 'milestones']));

    await upgraded.close();
    schema.close();
  });

  test('半迁移状态：v6 版本号但里程碑表已存在时迁移可重复成功（幂等回归）', () async {
    // 里程碑表用 v7 快照建库（结构一致），再把版本号重置为 6，模拟
    // 「表已手工创建但 user_version 落后」的半迁移状态。
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(7);
    final raw = schema.rawDatabase;
    raw.execute('PRAGMA user_version = 6'); // 模拟版本号落后

    // 旧实现 createTable 抛 duplicate table name；createTable 自带
    // IF NOT EXISTS，幂等实现应成功。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 7);

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(names, contains('milestones'));

    await upgraded.close();
    schema.close();
  });

  test('schema v7 -> v8：检查项表创建，v7 数据保留', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // 以 v7 结构初始化数据库并写入数据。
    final schema = await verifier.schemaAt(7);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v7 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO tasks (goal_id, title, planned_date, created_at, updated_at) '
      'VALUES (1, ?, ?, ?, ?)',
      ['v7 任务', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );

    // 以真实 AppDatabase 打开并执行 v7 -> v8 迁移，再与 v8 预期结构比对。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 8);

    // v7 数据保留。
    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, 'v7 任务');

    // v8 新表存在且可写入（含外键关联任务）。
    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(names, contains('checklist_items'));

    await upgraded.into(upgraded.checklistItems).insert(
          ChecklistItemsCompanion.insert(
            taskId: 1,
            title: '检查项一',
            sortOrder: const Value(0),
            createdAt: DateTime.fromMillisecondsSinceEpoch(1750000000, isUtc: true),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1750000000, isUtc: true),
          ),
        );
    final item = await upgraded.select(upgraded.checklistItems).getSingle();
    expect(item.title, '检查项一');
    expect(item.taskId, 1);
    expect(item.done, isFalse);

    await upgraded.close();
    schema.close();
  });

  test('schema v1 -> v8：迁移成功保留数据，检查项表存在', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
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

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 8);

    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, '迁移任务');

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(
      names,
      containsAll(['settings', 'recurrence_templates', 'milestones', 'checklist_items']),
    );

    await upgraded.close();
    schema.close();
  });

  test('半迁移状态：v7 版本号但检查项表已存在时迁移可重复成功（幂等回归）', () async {
    // 检查项表用 v8 快照建库（结构一致），再把版本号重置为 7，模拟
    // 「表已手工创建但 user_version 落后」的半迁移状态。
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(8);
    final raw = schema.rawDatabase;
    raw.execute('PRAGMA user_version = 7'); // 模拟版本号落后

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 8);

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(names, contains('checklist_items'));

    await upgraded.close();
    schema.close();
  });

  test('schema v8 -> v9：自动备份配置列补齐，v8 数据保留', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // 以 v8 结构初始化数据库并写入数据（含 settings 默认行）。
    final schema = await verifier.schemaAt(8);
    final raw = schema.rawDatabase;
    raw.execute(
      'INSERT INTO goals (title, deadline_date, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['v8 目标', '2026-08-05', 1750000000, 1750000000],
    );
    raw.execute(
      'INSERT INTO settings (id, created_at, updated_at) VALUES (1, ?, ?)',
      [1750000000, 1750000000],
    );

    // 以真实 AppDatabase 打开并执行 v8 -> v9 迁移。
    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 9);

    // v8 数据保留。
    final goal = await (upgraded.select(upgraded.goals)..where((g) => g.id.equals(1))).getSingle();
    expect(goal.title, 'v8 目标');

    // v9 新增 6 个自动备份配置列，旧行取默认值（FR-9.4）。
    final settings = await upgraded.select(upgraded.settings).getSingle();
    expect(settings.autoBackupEnabled, isFalse);
    expect(settings.localBackupFolder, isNull);
    expect(settings.webdavUrl, isNull);
    expect(settings.webdavUsername, isNull);
    expect(settings.webdavPasswordSaved, isFalse);
    expect(settings.lastAutoBackupAt, isNull);
    expect(settings.closeBehavior, 'exit'); // 既有列保留

    await upgraded.close();
    schema.close();
  });

  test('schema v1 -> v9：迁移成功保留数据，自动备份配置列存在', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
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

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 9);

    final task = await (upgraded.select(upgraded.tasks)..where((t) => t.id.equals(1))).getSingle();
    expect(task.title, '迁移任务');

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(
      names,
      containsAll(['settings', 'recurrence_templates', 'milestones', 'checklist_items']),
    );

    final columns = await upgraded.customSelect(
      "SELECT name FROM pragma_table_info('settings')",
    ).get();
    final settingColumns = columns.map((row) => row.read<String>('name')).toSet();
    expect(settingColumns, containsAll([
      'auto_backup_enabled',
      'local_backup_folder',
      'webdav_url',
      'webdav_username',
      'webdav_password_saved',
      'last_auto_backup_at',
    ]));

    await upgraded.close();
    schema.close();
  });

  test('半迁移状态：v8 版本号但自动备份配置列已存在时迁移可重复成功（幂等回归）', () async {
    // settings 用 v9 快照建库（含全部新列），再把版本号重置为 8，模拟
    // 「列已手工补上但 user_version 落后」的半迁移状态（addColumnIfMissing
    // 幂等，不抛 duplicate column name）。
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(9);
    final raw = schema.rawDatabase;
    raw.execute('PRAGMA user_version = 8'); // 模拟版本号落后

    final upgraded = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(upgraded, 9);

    final settings = await upgraded.select(upgraded.settings).getSingleOrNull();
    // 默认行由 SettingsRepository 惰性 seed；迁移本身不写 settings 行。
    expect(settings, isNull);

    final columns = await upgraded.customSelect(
      "SELECT name FROM pragma_table_info('settings')",
    ).get();
    final settingColumns = columns.map((row) => row.read<String>('name')).toSet();
    expect(settingColumns, contains('auto_backup_enabled'));

    await upgraded.close();
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
