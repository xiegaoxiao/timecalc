import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../domain/class_period.dart';
import '../domain/course_palette.dart';
import '../domain/timetable_import_parser.dart';

/// 课表导入的写入结果统计（供 UI 提示）。
class CourseImportStats {
  const CourseImportStats({required this.inserted, required this.removed});

  /// 写入的课程数。
  final int inserted;

  /// 替换导入时清除的旧课程数（追加导入为 0）。
  final int removed;
}

/// 课程数据访问层（FR-10 课表）。
///
/// 与 TaskRepository 的差别：课程没有完成状态、不改期、不参与负载统计，
/// 因此这里只有纯 CRUD 与「整表替换/追加」两种导入写入，没有事务型的
/// 状态流转。导入写入放单事务，保证「替换」语义要么全清全写、要么不动
/// （NFR-2：禁止半条写入）。
class CourseRepository {
  CourseRepository(this._db, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() clock;

  /// 全部课程，按「星期 → 起始节次 → 标题」排序（网格与列表共用次序）。
  Future<List<Course>> all() {
    final query = _db.select(_db.courses)
      ..orderBy([
        (c) => OrderingTerm.asc(c.weekday),
        (c) => OrderingTerm.asc(c.startPeriod),
        (c) => OrderingTerm.asc(c.endPeriod),
        (c) => OrderingTerm.asc(c.title),
      ]);
    return query.get();
  }

  /// 新建课程，返回落库后的行（含自增 id）。
  ///
  /// 调用方负责确保节次/周次/星期范围合法（表单校验与导入解析都已先过
  /// 一遍；本层再夹一次边界，避免脏值落库后网格越界）。
  Future<Course> create({
    required String title,
    String? teacher,
    String? location,
    required int weekday,
    required int startPeriod,
    required int endPeriod,
    required int startWeek,
    required int endWeek,
    String? weekParity,
    String? category,
    String? color,
    String? note,
  }) {
    return createFromDraft(
      CourseDraft(
        title: title,
        teacher: teacher,
        location: location,
        weekday: weekday,
        startPeriod: startPeriod,
        endPeriod: endPeriod,
        startWeek: startWeek,
        endWeek: endWeek,
        weekParity: weekParity ?? 'all',
        category: category,
        color: color,
        note: note,
      ),
      colorIndex: 0,
    );
  }

  /// 按导入草稿新建（颜色缺省时由 [colorIndex] 决定）。
  Future<Course> createFromDraft(CourseDraft draft, {int colorIndex = 0}) async {
    final now = clock().toUtc();
    final id = await _db.into(_db.courses).insert(
          CoursesCompanion.insert(
            title: draft.title,
            teacher: Value(draft.teacher),
            location: Value(draft.location),
            weekday: _clamp(draft.weekday, 1, 7),
            startPeriod: _clamp(draft.startPeriod, 1, ClassPeriods.count),
            endPeriod: _clamp(
              draft.endPeriod,
              _clamp(draft.startPeriod, 1, ClassPeriods.count),
              ClassPeriods.count,
            ),
            startWeek: _clamp(draft.startWeek, 1, 30),
            endWeek: _clamp(
              draft.endWeek,
              _clamp(draft.startWeek, 1, 30),
              30,
            ),
            weekParity: Value(draft.weekParity),
            category: Value(draft.category),
            color: draft.color ?? CoursePalette.at(colorIndex),
            note: Value(draft.note),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (_db.select(_db.courses)..where((c) => c.id.equals(id)))
        .getSingle();
  }

  /// 更新课程（表单编辑）。范围夹取同 [createFromDraft]。
  Future<void> update(
    int id, {
    required String title,
    String? teacher,
    String? location,
    required int weekday,
    required int startPeriod,
    required int endPeriod,
    required int startWeek,
    required int endWeek,
    required String weekParity,
    String? category,
    required String color,
    String? note,
  }) {
    return (_db.update(_db.courses)..where((c) => c.id.equals(id))).write(
      CoursesCompanion(
        title: Value(title),
        teacher: Value(teacher),
        location: Value(location),
        weekday: Value(_clamp(weekday, 1, 7)),
        startPeriod: Value(_clamp(startPeriod, 1, ClassPeriods.count)),
        endPeriod: Value(
          _clamp(endPeriod, _clamp(startPeriod, 1, ClassPeriods.count),
              ClassPeriods.count),
        ),
        startWeek: Value(_clamp(startWeek, 1, 30)),
        endWeek: Value(_clamp(endWeek, _clamp(startWeek, 1, 30), 30)),
        weekParity: Value(weekParity),
        category: Value(category),
        color: Value(color),
        note: Value(note),
        updatedAt: Value(clock().toUtc()),
      ),
    );
  }

  Future<void> delete(int id) =>
      (_db.delete(_db.courses)..where((c) => c.id.equals(id))).go();

  /// 清空全部课程（课表页「清空课表」）。
  Future<int> deleteAll() => _db.delete(_db.courses).go();

  /// 导入课程：[replace] 为 true 时先清空现有课表再写入（单事务）。
  ///
  /// 单事务是硬要求——「替换」若中途失败，用户会既丢旧课表又没拿到新课表。
  Future<CourseImportStats> importCourses(
    List<CourseDraft> drafts, {
    required bool replace,
  }) {
    return _db.transaction(() async {
      final removed = replace ? await _db.delete(_db.courses).go() : 0;
      // 颜色按写入序在调色板上分配：同一份文件重复导入得到同样的配色，
      // 且草稿自带合法色值时以文件为准（不覆盖用户显式指定的颜色）。
      for (var i = 0; i < drafts.length; i++) {
        await createFromDraft(drafts[i], colorIndex: i);
      }
      return CourseImportStats(inserted: drafts.length, removed: removed);
    });
  }

  static int _clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}
