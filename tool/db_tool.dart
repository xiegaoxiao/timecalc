// 视觉验收辅助工具（一次性）：直接读写 TimeCalc 的 SQLite 库。
//
// 用途：
//   1) `inspect <db>`  —— 只读打印 settings 与各表计数，确认当前色系；
//   2) `set-accent <db> <id>` —— 改 settings.accent_color（仅用于让真机
//      截图能看到新撞色方案）；
//   3) `seed <db>` —— 灌入一组样例数据（目标/科目/任务/里程碑/课程），
//      让六大页面的撞色设计在截图里真正有内容可看。
//
// 运行：dart run tool/db_tool.dart <cmd> <dbPath> [arg]
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: db_tool.dart <inspect|set-accent|seed> <db> [arg]');
    exit(64);
  }
  // sqlite3 3.5.x 通过 native assets 构建钩子解析原生库
  // （build/native_assets/windows/sqlite3.dll），无需手动 override。
  final cmd = args[0];
  final dbPath = args[1];
  final db = sqlite3.open(dbPath);
  try {
    switch (cmd) {
      case 'inspect':
        _inspect(db);
      case 'set-accent':
        _setAccent(db, args[2]);
      case 'seed':
        _seed(db);
      case 'ddl':
        _ddl(db);
      default:
        stderr.writeln('unknown command: $cmd');
        exit(64);
    }
  } finally {
    db.dispose();
  }
}

void _inspect(Database db) {
  stdout.writeln('== settings ==');
  for (final row in db.select('SELECT * FROM settings')) {
    stdout.writeln(row);
  }
  stdout.writeln('== counts ==');
  const tables = [
    'goals',
    'subjects',
    'tasks',
    'milestones',
    'courses',
    'checklist_items',
    'recurrence_templates',
  ];
  for (final t in tables) {
    try {
      final n = db.select('SELECT COUNT(*) AS c FROM $t').first['c'];
      stdout.writeln('$t: $n');
    } catch (e) {
      stdout.writeln('$t: (n/a)');
    }
  }
}

void _ddl(Database db) {
  for (final r in db.select(
    "SELECT name, sql FROM sqlite_master WHERE type='table' "
    "AND name IN ('goals','subjects','tasks','milestones','courses','checklist_items') "
    'ORDER BY name',
  )) {
    stdout.writeln('--- ${r['name']} ---');
    stdout.writeln(r['sql']);
  }
}

void _setAccent(Database db, String id) {
  db.execute('UPDATE settings SET accent_color = ? WHERE id = 1', [id]);
  stdout.writeln('accent_color -> ${db.select('SELECT accent_color FROM settings').first['accent_color']}');
}

/// 灌入样例数据（仅用于真机截图）。所有时间戳为 UTC epoch 秒。
void _seed(Database db) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  String d(DateTime x) =>
      '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';

  final today = DateTime.now();
  final plus = (int days) => d(today.add(Duration(days: days)));

  // 清空业务表（保留 settings）。
  for (final t in [
    'checklist_items',
    'tasks',
    'milestones',
    'subjects',
    'goals',
    'courses',
  ]) {
    try {
      db.execute('DELETE FROM $t');
    } catch (_) {}
  }

  // —— 目标 ×3（进行中 / 进行中 / 已完成）——
  final goals = <List<Object?>>[
    ['考研数学全程', '把高数、线代、概率论过完三遍并压到 140+', plus(96), 'active'],
    ['英语六级冲刺', '真题两轮 + 写作模板', plus(38), 'active'],
    ['毕业设计', '已完成开题与中期', plus(-6), 'completed'],
  ];
  for (final g in goals) {
    db.execute(
      'INSERT INTO goals (title, description, deadline_date, status, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [g[0], g[1], g[2], g[3], now, now],
    );
  }

  final goalIds = db.select('SELECT id, title FROM goals ORDER BY id').toList();

  // —— 科目（color 为 NOT NULL 的 #RRGGBB 文本）——
  const palette = [
    '#3F6C51',
    '#2F6F9F',
    '#B0523F',
    '#7A4E9E',
    '#2E7D7A',
    '#9A7B24',
  ];
  final subjects = <String, List<String>>{
    '考研数学全程': ['高数', '线代', '概率论'],
    '英语六级冲刺': ['听力', '阅读', '写作'],
    '毕业设计': ['文献', '实验'],
  };
  var colorIdx = 0;
  for (final g in goalIds) {
    for (final s in subjects[g['title']] ?? const <String>[]) {
      db.execute(
        'INSERT INTO subjects (goal_id, name, color, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [g['id'], s, palette[colorIdx++ % palette.length], now, now],
      );
    }
  }

  // —— 任务（覆盖今天/逾期/未来/已完成，带预估时长与科目）——
  final subjRows = db.select('SELECT id, goal_id, name FROM subjects').toList();
  int? subjOf(int goalId, String name) {
    for (final r in subjRows) {
      if (r['goal_id'] == goalId && r['name'] == name) return r['id'] as int;
    }
    return null;
  }

  final g1 = goalIds[0]['id'] as int;
  final g2 = goalIds[1]['id'] as int;
  final g3 = goalIds[2]['id'] as int;

  final tasks = <List<Object?>>[
    // 今天
    [g1, subjOf(g1, '高数'), '高数 第 8 章 定积分应用', todayStr(today), 120, null, 'todo', 0],
    [g1, subjOf(g1, '线代'), '线代 特征值与二次型', todayStr(today), 90, '09:00', 'todo', 0],
    [g2, subjOf(g2, '听力'), '六级听力 长对话精听', todayStr(today), 45, null, 'done', 1],
    [g2, subjOf(g2, '阅读'), '阅读 真题 2 篇', todayStr(today), 60, '14:30', 'todo', 0],
    // 逾期
    [g1, subjOf(g1, '概率论'), '概率论 大数定律习题', plus(-2), 75, null, 'todo', 0],
    [g3, subjOf(g3, '文献'), '补交文献综述', plus(-5), 40, null, 'todo', 0],
    // 未来
    [g1, subjOf(g1, '高数'), '高数 第 9 章 重积分', plus(1), 150, null, 'todo', 0],
    [g1, subjOf(g1, '线代'), '线代 模拟卷一套', plus(2), 180, null, 'todo', 0],
    [g2, subjOf(g2, '写作'), '写作 模板默写', plus(3), 50, null, 'todo', 0],
    [g1, subjOf(g1, '概率论'), '概率论 第 3 章', plus(5), 100, null, 'todo', 0],
    // 已完成历史（给进度页图表喂数据）
    [g1, subjOf(g1, '高数'), '高数 第 5 章 中值定理', plus(-8), 110, null, 'done', 1],
    [g1, subjOf(g1, '线代'), '线代 矩阵秩', plus(-7), 80, null, 'done', 1],
    [g2, subjOf(g2, '听力'), '听力 短对话', plus(-6), 40, null, 'done', 1],
    [g3, subjOf(g3, '实验'), '实验数据整理', plus(-4), 130, null, 'done', 1],
    [g1, subjOf(g1, '概率论'), '概率论 随机变量', plus(-3), 95, null, 'done', 1],
    [g2, subjOf(g2, '阅读'), '阅读 长难句', plus(-2), 55, null, 'done', 1],
    [g1, subjOf(g1, '高数'), '高数 第 7 章 微分方程', plus(-1), 140, null, 'done', 1],
  ];

  for (final t in tasks) {
    final done = t[7] == 1;
    // 注意列序：planned_date, start_time, estimated_minutes —— 元组里
    // 存的是 (…, 分钟数 t[4], 时刻字符串 t[5], …)，故此处必须交换。
    db.execute(
      'INSERT INTO tasks (goal_id, subject_id, title, planned_date, start_time, '
      'estimated_minutes, status, completed_at, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        t[0], t[1], t[2], t[3], t[5], t[4], t[6],
        done ? now - 3600 : null, now, now,
      ],
    );
  }

  // —— 里程碑（列名为 date，状态 todo/done）——
  db.execute(
    'INSERT INTO milestones (goal_id, title, date, status, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [g1, '高数基础阶段', plus(20), 'todo', now, now],
  );
  db.execute(
    'INSERT INTO milestones (goal_id, title, date, status, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [g1, '强化阶段完成', plus(60), 'todo', now, now],
  );
  db.execute(
    'INSERT INTO milestones (goal_id, title, date, status, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [g2, '听力专项达标', plus(10), 'done', now, now],
  );

  // —— 课表课程（列名：title/teacher/location/.../color）——
  final courses = <List<Object?>>[
    ['高等数学', '张老师', 'A-301', 1, 1, 2, 1, 16, '#2F6F9F'],
    ['线性代数', '李老师', 'B-205', 2, 3, 4, 1, 16, '#7A4E9E'],
    ['大学英语', '王老师', 'C-108', 3, 1, 2, 1, 16, '#B0523F'],
    ['概率论', '赵老师', 'A-204', 3, 5, 6, 1, 16, '#2E7D7A'],
    ['数据结构', '陈老师', 'D-401', 4, 3, 4, 1, 16, '#3F6C51'],
    ['体育', '刘老师', '操场', 4, 7, 8, 1, 16, '#9A7B24'],
    ['毕业设计', '导师', '实验室', 5, 5, 6, 1, 16, '#8A5A2B'],
  ];
  for (final c in courses) {
    db.execute(
      'INSERT INTO courses (title, teacher, location, weekday, start_period, '
      'end_period, start_week, end_week, week_parity, color, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7],
        'all', c[8], now, now,
      ],
    );
  }

  stdout.writeln('seeded.');
  stdout.writeln(db.select('SELECT COUNT(*) c FROM tasks').first);
  stdout.writeln(db.select('SELECT COUNT(*) c FROM goals').first);
}

String todayStr(DateTime x) =>
    '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
