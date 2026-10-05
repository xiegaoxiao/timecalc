import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/features/timetable/data/course_repository.dart';
import 'package:timecalc/features/timetable/domain/class_period.dart';
import 'package:timecalc/features/timetable/domain/course_palette.dart';
import 'package:timecalc/features/timetable/domain/timetable_import_parser.dart';

/// CourseRepository 内存数据库测试（SOP S5：DAO/Repository 层用内存库）。
void main() {
  late AppDatabase db;
  late CourseRepository courses;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    courses = CourseRepository(db, clock: () => DateTime(2026, 9, 14, 9));
  });

  tearDown(() async {
    await db.close();
  });

  /// 构造一门课的草稿（默认：周一 1-2 节、2-18 周、每周）。
  CourseDraft draft(
    String title, {
    int weekday = 1,
    int startPeriod = 1,
    int endPeriod = 2,
    int startWeek = 2,
    int endWeek = 18,
    String weekParity = WeekParity.all,
    String? color,
    String? location,
    String? teacher,
  }) {
    return CourseDraft(
      title: title,
      weekday: weekday,
      startPeriod: startPeriod,
      endPeriod: endPeriod,
      startWeek: startWeek,
      endWeek: endWeek,
      weekParity: weekParity,
      color: color,
      location: location,
      teacher: teacher,
    );
  }

  group('课程 CRUD（FR-10）', () {
    test('创建课程后按星期/节次排序返回', () async {
      await courses.create(
        title: '周三晚课',
        weekday: 3,
        startPeriod: 9,
        endPeriod: 12,
        startWeek: 11,
        endWeek: 18,
      );
      await courses.create(
        title: '周一早课',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 4,
        startWeek: 5,
        endWeek: 12,
      );
      await courses.create(
        title: '周一下午',
        weekday: 1,
        startPeriod: 5,
        endPeriod: 8,
        startWeek: 11,
        endWeek: 18,
      );

      final all = await courses.all();
      // 星期优先，其次起始节次：周一(1-4) → 周一(5-8) → 周三(9-12)。
      expect(all.map((c) => c.title).toList(), [
        '周一早课',
        '周一下午',
        '周三晚课',
      ]);
    });

    test('未指定配色时按调色板取默认色', () async {
      final course = await courses.create(
        title: '算法设计与分析',
        weekday: 4,
        startPeriod: 5,
        endPeriod: 8,
        startWeek: 2,
        endWeek: 8,
      );
      expect(course.color, CoursePalette.defaultHex);
      expect(course.weekParity, WeekParity.all); // 未传时按每周
      expect(await courses.all(), hasLength(1));
    });

    test('创建时夹取越界范围（脏输入不落库为非法区间）', () async {
      final course = await courses.create(
        title: '越界课程',
        weekday: 9,
        startPeriod: 20,
        endPeriod: 0,
        startWeek: 0,
        endWeek: 99,
      );
      expect(course.weekday, 7);
      expect(course.startPeriod, ClassPeriods.count);
      // 结束节次不早于起始节次。
      expect(course.endPeriod, ClassPeriods.count);
      expect(course.startWeek, 1);
      expect(course.endWeek, 30);
    });

    test('更新课程后内容与 updatedAt 生效', () async {
      final created = await courses.create(
        title: '软件需求工程',
        weekday: 2,
        startPeriod: 3,
        endPeriod: 4,
        startWeek: 2,
        endWeek: 18,
      );

      await courses.update(
        created.id,
        title: '软件需求工程（改）',
        teacher: '石渐蔚',
        location: '教B215',
        weekday: 2,
        startPeriod: 3,
        endPeriod: 4,
        startWeek: 3,
        endWeek: 16,
        weekParity: WeekParity.odd,
        category: '选修课',
        color: '#2F6F9F',
        note: '以任课教师通知为准',
      );

      final updated = (await courses.all()).single;
      expect(updated.id, created.id);
      expect(updated.title, '软件需求工程（改）');
      expect(updated.teacher, '石渐蔚');
      expect(updated.location, '教B215');
      expect(updated.startWeek, 3);
      expect(updated.endWeek, 16);
      expect(updated.weekParity, WeekParity.odd);
      expect(updated.category, '选修课');
      expect(updated.color, '#2F6F9F');
      expect(updated.note, '以任课教师通知为准');
    });

    test('删除单门与清空全部', () async {
      final a = await courses.create(
        title: 'A',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 4,
      );
      await courses.create(
        title: 'B',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 4,
      );

      await courses.delete(a.id);
      expect((await courses.all()).map((c) => c.title), ['B']);

      final removed = await courses.deleteAll();
      expect(removed, 1);
      expect(await courses.all(), isEmpty);
    });
  });

  group('课表导入写入', () {
    test('追加模式：保留现有课程并按序分配配色', () async {
      await courses.create(
        title: '原有课程',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 4,
      );

      final stats = await courses.importCourses([
        draft('导入课A', weekday: 2),
        draft('导入课B', weekday: 3, color: '#B0523F'),
      ], replace: false);

      expect(stats.inserted, 2);
      expect(stats.removed, 0);

      final all = await courses.all();
      expect(all.map((c) => c.title), ['原有课程', '导入课A', '导入课B']);
      // 无自带色值的按调色板顺序取色；自带合法色值以文件为准。
      expect(all[1].color, CoursePalette.at(0));
      expect(all[2].color, '#B0523F');
    });

    test('替换模式：先清空再写入，重复导入不翻倍', () async {
      await courses.create(
        title: '旧的课',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 4,
      );

      final first = await courses.importCourses([
        draft('移动智能', weekday: 1, startPeriod: 5, endPeriod: 8),
        draft('人工智能', weekday: 3, startPeriod: 9, endPeriod: 12),
      ], replace: true);

      expect(first.inserted, 2);
      expect(first.removed, 1);
      expect((await courses.all()).map((c) => c.title), ['移动智能', '人工智能']);

      // 同一份课表再导入一次：数量不翻倍。
      final second = await courses.importCourses([
        draft('移动智能', weekday: 1, startPeriod: 5, endPeriod: 8),
        draft('人工智能', weekday: 3, startPeriod: 9, endPeriod: 12),
      ], replace: true);

      expect(second.removed, 2);
      expect(await courses.all(), hasLength(2));
    });

    test('替换模式失败时整体回滚（不出现「清了旧的又没有新的」）', () async {
      await courses.create(
        title: '旧课表',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 4,
      );

      // 标题超过 200 字：drift 的长度校验在插入时抛错，事务整体回滚。
      final tooLong = CourseDraft(
        title: 'x' * 500,
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 4,
      );

      await expectLater(
        courses.importCourses([tooLong], replace: true),
        throwsA(anything),
      );

      // 旧课表仍在（回滚生效，NFR-2）。
      final all = await courses.all();
      expect(all, hasLength(1));
      expect(all.single.title, '旧课表');
    });
  });
}
