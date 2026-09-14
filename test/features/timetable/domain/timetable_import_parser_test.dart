import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/features/timetable/domain/timetable_import_parser.dart';

/// 课表导入解析单元测试（FR-10）。
///
/// 覆盖两条真实路径：
/// - iCalendar（含 `RRULE` 周重复 + `DESCRIPTION` 结构化字段 + 仅钟点的兜底
///   换算），用例直接取自「人工智能学院 2026-2027（1）学期研究生课程安排表」
///   导出的课表 ICS；
/// - 课表 JSON（字段直给，无损往返）。
void main() {
  const parser = TimetableImportParser();

  /// 拼一份 ICS（[events] 为完整 VEVENT 块）。
  String ics(List<String> events, {String? name}) {
    return [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      if (name != null) 'X-WR-CALNAME:$name',
      ...events,
      'END:VCALENDAR',
      '',
    ].join('\r\n');
  }

  String vevent(
    String summary, {
    required String start,
    required String end,
    String? location,
    String? description,
    String? rrule,
    String? status,
  }) {
    return [
      'BEGIN:VEVENT',
      'UID:$summary-1',
      'DTSTART;$start',
      'DTEND;$end',
      'SUMMARY:$summary',
      if (location != null) 'LOCATION:$location',
      if (description != null) 'DESCRIPTION:$description',
      if (rrule != null) 'RRULE:$rrule',
      if (status != null) 'STATUS:$status',
      'END:VEVENT',
    ].join('\r\n');
  }

  group('iCalendar 导入', () {
    test('DESCRIPTION 结构化字段（教师/周次/类别）与显式节次被完整读取', () {
      final result = parser.parse(
        ics([
          vevent(
            '软件需求工程',
            start: 'DTSTART:20260915T102000',
            end: 'DTEND:20260915T115000',
            location: '教B215',
            description: '教师：石渐蔚｜周次：2-18周｜类别：选修课/方向必修课',
            rrule: 'FREQ=WEEKLY;COUNT=17',
          ),
        ], name: '谢永恒课表'),
      );

      expect(result.isValid, isTrue);
      expect(result.calendarName, '谢永恒课表');
      expect(result.courses, hasLength(1));
      final course = result.courses.single;
      expect(course.title, '软件需求工程');
      expect(course.teacher, '石渐蔚');
      expect(course.location, '教B215');
      expect(course.category, '选修课/方向必修课');
      expect(course.weekday, 2); // 2026-09-15 是周二
      expect(course.startPeriod, 3);
      expect(course.endPeriod, 4);
      expect(course.startWeek, 2);
      expect(course.endWeek, 18);
      expect(course.weekParity, WeekParity.all);
      // 学期基准由「首次上课日 + 起始周」反推：第 1 周周一 = 2026-09-07。
      expect(result.semesterStart, '2026-09-07');
    });

    test('晚上 9-12 节：钟点与校历作息不一致时以 DESCRIPTION 的节次为准', () {
      // 官方标注 18:30 开始（校历第 9 节是 19:00），若按钟点换算会落到第 8 节。
      final result = parser.parse(
        ics([
          vevent(
            '人工智能',
            start: 'DTSTART:20261118T183000',
            end: 'DTEND:20261118T213000',
            location: '教B111',
            description: '教师：范晨悠、费超群｜周次：11-18周｜类别：方向必修课｜节次：9-12节',
            rrule: 'FREQ=WEEKLY;COUNT=8',
          ),
        ]),
      );

      final course = result.courses.single;
      expect(course.startPeriod, 9);
      expect(course.endPeriod, 12);
      expect(course.weekday, 3);
      expect(course.startWeek, 11);
      expect(course.endWeek, 18);
      expect(result.semesterStart, '2026-09-07');
    });

    test('无节次标注时按钟点就近换算节次', () {
      final result = parser.parse(
        ics([
          vevent(
            '论文写作与学术规范',
            start: 'DTSTART:20260917T083000',
            end: 'DTEND:20260917T100000',
            location: '教A309',
            description: '教师：杜志斌等｜周次：2-10周',
            rrule: 'FREQ=WEEKLY;COUNT=9',
          ),
          vevent(
            '算法设计与分析（理论）',
            start: 'DTSTART:20260917T140000',
            end: 'DTEND:20260917T171000',
            location: '教A309',
            description: '教师：梁军、汪红松、曲超｜周次：2-8周',
            rrule: 'FREQ=WEEKLY;COUNT=7',
          ),
        ]),
      );

      expect(result.courses[0].startPeriod, 1);
      expect(result.courses[0].endPeriod, 2);
      expect(result.courses[1].startPeriod, 5);
      expect(result.courses[1].endPeriod, 8);
    });

    test('多门课共同反推学期基准：取出现次数最多的候选', () {
      final result = parser.parse(
        ics([
          vevent(
            '课程A',
            start: 'DTSTART:20260915T102000',
            end: 'DTEND:20260915T115000',
            description: '周次：2-18周',
            rrule: 'FREQ=WEEKLY;COUNT=17',
          ),
          vevent(
            '课程B',
            start: 'DTSTART:20261118T183000',
            end: 'DTEND:20261118T213000',
            description: '周次：11-18周',
            rrule: 'FREQ=WEEKLY;COUNT=8',
          ),
          vevent(
            '课程C',
            start: 'DTSTART:20260916T140000',
            end: 'DTEND:20260916T162000',
            description: '周次：2-17周',
            rrule: 'FREQ=WEEKLY;COUNT=16',
          ),
        ]),
      );

      expect(result.courses, hasLength(3));
      expect(result.semesterStart, '2026-09-07');
    });

    test('INTERVAL=2 按起始周奇偶判为单/双周；周次标注优先于 RRULE 计数', () {
      final result = parser.parse(
        ics([
          vevent(
            '双周课',
            start: 'DTSTART:20260914T102000',
            end: 'DTEND:20260914T115000',
            // 起始周为第 2 周（偶数）→ 双周。
            description: '周次：2-16周',
            rrule: 'FREQ=WEEKLY;INTERVAL=2;COUNT=8',
          ),
          vevent(
            '单周课',
            start: 'DTSTART:20260921T102000',
            end: 'DTEND:20260921T115000',
            // 起始周为第 3 周（奇数）→ 单周。
            description: '周次：3-17周',
            rrule: 'FREQ=WEEKLY;INTERVAL=2;COUNT=8',
          ),
        ]),
      );

      expect(result.courses[0].weekParity, WeekParity.even);
      expect(result.courses[1].weekParity, WeekParity.odd);
    });

    test('无周次标注时由 RRULE COUNT 推 1..COUNT', () {
      final result = parser.parse(
        ics([
          vevent(
            '每周课',
            start: 'DTSTART:20260914T102000',
            end: 'DTEND:20260914T115000',
            rrule: 'FREQ=WEEKLY;COUNT=12',
          ),
        ]),
      );

      expect(result.courses.single.startWeek, 1);
      expect(result.courses.single.endWeek, 12);
      // 起始周 1 → 首次上课日所在周即第 1 周。
      expect(result.semesterStart, '2026-09-14');
    });

    test('未识别的 DESCRIPTION 片段并入备注，不丢信息', () {
      final result = parser.parse(
        ics([
          vevent(
            '算法设计与分析（实验）',
            start: 'DTSTART:20260916T175000',
            end: 'DTEND:20260916T203000',
            // RFC 5545 的 DESCRIPTION 里换行以 `\n` 转义（源码里写作 `\\n`）。
            description: '教师：梁军｜周次：2-8周｜节次：9-12节\\n注：官方标注 17:50 开始，以任课教师通知为准',
            rrule: 'FREQ=WEEKLY;COUNT=7',
          ),
        ]),
      );

      final course = result.courses.single;
      expect(course.teacher, '梁军');
      expect(course.note, contains('官方标注 17:50 开始'));
      // 「注：…」的键被识别为备注，不应把键名一起塞进备注。
      expect(course.note, isNot(contains('注：')));
    });

    test('单次日程（无 RRULE 且无周次）与已取消日程被跳过并计数', () {
      final result = parser.parse(
        ics([
          vevent(
            '每周课',
            start: 'DTSTART:20260914T102000',
            end: 'DTEND:20260914T115000',
            rrule: 'FREQ=WEEKLY;COUNT=4',
          ),
          vevent(
            '一次性讲座',
            start: 'DTSTART:20260914T140000',
            end: 'DTEND:20260914T160000',
          ),
          vevent(
            '已取消的课',
            start: 'DTSTART:20260915T140000',
            end: 'DTEND:20260915T160000',
            rrule: 'FREQ=WEEKLY;COUNT=4',
            status: 'CANCELLED',
          ),
        ]),
      );

      expect(result.courses, hasLength(1));
      expect(result.skippedEvents, 2);
      expect(result.isValid, isTrue);
    });

    test('全部事件都不可导入时给出可读原因', () {
      final result = parser.parse(
        ics([
          vevent(
            '一次性讲座',
            start: 'DTSTART:20260914T140000',
            end: 'DTEND:20260914T160000',
          ),
        ]),
      );

      expect(result.isValid, isFalse);
      expect(result.issues, hasLength(1));
      expect(result.issues.single.message, contains('单次日程'));
    });

    test('不是 iCalendar 也不是 JSON 时给出格式错误', () {
      final result = parser.parse('这不是课表');
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('不是有效的 JSON'));
    });

    test('空日历（无 VEVENT）报错', () {
      final result = parser.parse(ics(const []));
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('没有事件'));
    });

    test('非 WEEKLY 的重复规则不作为课程导入', () {
      // FREQ=DAILY 不是课表语义：无周次标注时无法定位教学周 → 跳过。
      final result = parser.parse(
        ics([
          vevent(
            '每日晨读',
            start: 'DTSTART:20260914T083000',
            end: 'DTEND:20260914T090000',
            rrule: 'FREQ=DAILY;COUNT=30',
          ),
        ]),
      );

      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('单次日程'));
    });
  });

  group('课表 JSON 导入', () {
    test('字段直给时段与周次，学期基准来自 timetable.semester_start', () {
      final result = parser.parse('''
{
  "timetable": { "semester_start": "2026-09-07", "name": "谢永恒课表" },
  "courses": [
    {
      "title": "算法设计与分析",
      "teacher": "梁军、汪红松、曲超",
      "location": "教A309",
      "weekday": 4,
      "start_period": 5,
      "end_period": 8,
      "start_week": 2,
      "end_week": 8,
      "week_parity": "all",
      "category": "学科基础课"
    },
    {
      "title": "移动智能",
      "weekday": 1,
      "start_period": 5,
      "end_period": 8,
      "start_week": 11,
      "end_week": 18,
      "location": "教A209"
    }
  ]
}
''');

      expect(result.isValid, isTrue);
      expect(result.semesterStart, '2026-09-07');
      expect(result.calendarName, '谢永恒课表');
      expect(result.courses, hasLength(2));

      final first = result.courses[0];
      expect(first.title, '算法设计与分析');
      expect(first.teacher, '梁军、汪红松、曲超');
      expect(first.weekday, 4);
      expect(first.startPeriod, 5);
      expect(first.endPeriod, 8);
      expect(first.startWeek, 2);
      expect(first.endWeek, 8);
      expect(first.weekParity, WeekParity.all);
      expect(first.category, '学科基础课');

      // 缺省字段落到安全默认值（每周、无教师）。
      final second = result.courses[1];
      expect(second.weekParity, WeekParity.all);
      expect(second.teacher, isNull);
      expect(second.note, isNull);
      expect(second.color, isNull);
    });

    test('中文别名与中文星期/单双周文本都被接受', () {
      final result = parser.parse('''
{
  "courses": [
    {
      "课程名称": "具身认知与机器智能",
      "教师": "余松森，周娴玮",
      "上课地点": "教A309",
      "星期": "周一",
      "startPeriod": 1,
      "endPeriod": 4,
      "startWeek": 5,
      "endWeek": 12,
      "单双周": "单周"
    }
  ]
}
''');

      final course = result.courses.single;
      expect(course.title, '具身认知与机器智能');
      expect(course.teacher, '余松森，周娴玮');
      expect(course.location, '教A309');
      expect(course.weekday, 1);
      expect(course.weekParity, WeekParity.odd);
    });

    test('非法字段逐条报错且不写入任何课程', () {
      final result = parser.parse('''
{
  "courses": [
    { "title": "缺星期", "start_period": 1, "end_period": 2, "start_week": 1, "end_week": 2 },
    { "title": "节次越界", "weekday": 1, "start_period": 0, "end_period": 2, "start_week": 1, "end_week": 2 },
    { "title": "周次倒挂", "weekday": 1, "start_period": 1, "end_period": 2, "start_week": 8, "end_week": 2 },
    { "title": "单双周非法", "weekday": 1, "start_period": 1, "end_period": 2, "start_week": 1, "end_week": 2, "week_parity": "隔周" },
    { "weekday": 1, "start_period": 1, "end_period": 2, "start_week": 1, "end_week": 2 }
  ]
}
''');

      expect(result.isValid, isFalse);
      expect(result.courses, isEmpty);
      expect(result.issues, hasLength(5));
      expect(result.issues[0].location, '第 1 门课');
      expect(result.issues[0].message, contains('星期几不合法'));
      expect(result.issues[1].message, contains('节次不合法'));
      expect(result.issues[2].message, contains('教学周不合法'));
      expect(result.issues[3].message, contains('单双周取值不合法'));
      expect(result.issues[4].message, contains('缺少课程名'));
    });

    test('顶层不是对象、缺 courses、courses 为空时分别报错', () {
      expect(
        parser.parse('[1, 2]').issues.single.message,
        contains('顶层应为对象'),
      );
      expect(
        parser.parse('{"timetable": {}}').issues.single.message,
        contains('缺少 courses 数组'),
      );
      expect(
        parser.parse('{"courses": []}').issues.single.message,
        contains('没有可导入的课程'),
      );
    });

    test('课程名超长被拒绝', () {
      final longTitle = 'a' * (TimetableImportParser.maxTitleLength + 1);
      final result = parser.parse(
        '{"courses":[{"title":"$longTitle","weekday":1,'
        '"start_period":1,"end_period":2,"start_week":1,"end_week":2}]}',
      );
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('不能超过'));
    });

    test('教学周超过 30 被拒绝', () {
      final result = parser.parse(
        '{"courses":[{"title":"超长学期","weekday":1,'
        '"start_period":1,"end_period":2,"start_week":1,"end_week":40}]}',
      );
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('教学周不合法'));
    });

    test('合法 color 原样保留，非法 color 归 null（由导入侧分配）', () {
      final result = parser.parse(
        '{"courses":['
        '{"title":"带色","weekday":1,"start_period":1,"end_period":2,'
        '"start_week":1,"end_week":2,"color":"#2F6F9F"},'
        '{"title":"脏色","weekday":1,"start_period":3,"end_period":4,'
        '"start_week":1,"end_week":2,"color":"red"}'
        ']}',
      );

      expect(result.courses[0].color, '#2F6F9F');
      expect(result.courses[1].color, isNull);
    });
  });

  group('格式判别', () {
    test('按内容判别：BEGIN:VCALENDAR 开头走 ICS，其余走 JSON', () {
      // 前面有空白也应识别为 ICS（文件可能带 BOM/空行）。
      final result = parser.parse('\n  BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n');
      expect(result.issues.single.message, contains('没有事件'));

      final json = parser.parse('  {"courses": []}');
      expect(json.issues.single.message, contains('没有可导入的课程'));
    });
  });
}
