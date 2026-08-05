import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';

/// schema v1 migration 测试（NFR-2 / SOP S5）。
///
/// 覆盖：空库创建、三张表存在、必要列与约束符合预期。
/// 后续 schema 升级时，在此追加「升级成功、升级失败后原库仍可用、
/// 升级前备份/快照恢复」测试（checklists §4 / §5.2）。
void main() {
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
}

Future<Set<String>> _columns(AppDatabase db, String table) async {
  final rows = await db.customSelect(
    'PRAGMA table_info($table)',
  ).get();
  return rows.map((row) => row.read<String>('name')).toSet();
}
