import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/plan_import/domain/ics_plan_parser.dart';

/// iCalendar → 待导入计划 的桥接解析单元测试。
void main() {
  const parser = IcsPlanParser();
  final today = DateTime(2026, 8, 5, 12);

  String wrap(String body, {String? calendarName}) => [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    if (calendarName != null) 'X-WR-CALNAME:$calendarName',
    body,
    'END:VCALENDAR',
    '',
  ].join('\r\n');

  test('VEVENT 映射为任务：标题/日期/时刻/时长/备注', () {
    final result = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:高数：三重积分
DESCRIPTION:例题 1-10
DTSTART:20260806T083000
DTEND:20260806T113000
END:VEVENT
BEGIN:VEVENT
SUMMARY:全天复盘
DTSTART;VALUE=DATE:20260807
END:VEVENT''', calendarName: '考研日历'),
      today: today,
    );

    expect(result.isValid, isTrue);
    final plan = result.plan!;
    expect(plan.goalTitle, '考研日历');
    expect(plan.tasks.length, 2);

    final first = plan.tasks.first;
    expect(first.title, '高数：三重积分');
    expect(first.date, '2026-08-06');
    expect(first.time, '08:30');
    expect(first.minutes, 180);
    expect(first.note, '例题 1-10');
    expect(first.subjectName, isNull);

    final second = plan.tasks.last;
    expect(second.title, '全天复盘');
    expect(second.date, '2026-08-07');
    expect(second.time, isNull);
    expect(second.minutes, isNull);
  });

  test('目标截止日取全部事件中最晚的日期', () {
    final result = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:晚一些
DTSTART;VALUE=DATE:20260901
END:VEVENT
BEGIN:VEVENT
SUMMARY:早一些
DTSTART;VALUE=DATE:20260810
END:VEVENT'''),
      today: today,
    );
    expect(result.plan!.deadlineDate, '2026-09-01');
  });

  test('早于今天的事件跳过并统计，已取消事件同样跳过', () {
    final result = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:昨天的课
DTSTART;VALUE=DATE:20260804
END:VEVENT
BEGIN:VEVENT
SUMMARY:已取消的课
STATUS:CANCELLED
DTSTART;VALUE=DATE:20260806
END:VEVENT
BEGIN:VEVENT
SUMMARY:今天的课
DTSTART;VALUE=DATE:20260805
END:VEVENT'''),
      today: today,
    );
    final plan = result.plan!;
    expect(plan.tasks.map((t) => t.title), ['今天的课']);
    expect(plan.skippedTasks, 2);
  });

  test('无日历名时用文件名作目标标题；都没有则用默认名', () {
    final withFallback = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:事件
DTSTART;VALUE=DATE:20260806
END:VEVENT'''),
      today: today,
      fallbackTitle: '从手机导出的日历',
    );
    expect(withFallback.plan!.goalTitle, '从手机导出的日历');

    final withoutFallback = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:事件
DTSTART;VALUE=DATE:20260806
END:VEVENT'''),
      today: today,
    );
    expect(withoutFallback.plan!.goalTitle, '导入的日历');
  });

  test('全天多日事件的时长封顶到 1440 分钟', () {
    final result = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:三天集训
DTSTART;VALUE=DATE:20260806
DURATION:P3D
END:VEVENT'''),
      today: today,
    );
    expect(result.plan!.tasks.single.minutes, 1440);
  });

  test('无事件 / 全部事件被跳过时报 issue 不给计划', () {
    final empty = parser.parse(
      wrap('BEGIN:VTIMEZONE\nTZID:Asia/Shanghai\nEND:VTIMEZONE'),
      today: today,
    );
    expect(empty.isValid, isFalse);
    expect(empty.issues.single.message, contains('没有可导入的事件'));

    final allPast = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:旧事件
DTSTART;VALUE=DATE:20260101
END:VEVENT'''),
      today: today,
    );
    expect(allPast.isValid, isFalse);
    expect(allPast.issues.single.message, contains('早于今天'));
  });

  test('非 iCalendar 文本报可读错误', () {
    final result = parser.parse('{"plan_name": "这是 JSON"}', today: today);
    expect(result.isValid, isFalse);
    expect(result.issues.single.message, contains('BEGIN:VCALENDAR'));
  });

  test('超长事件标题报 issue', () {
    final result = parser.parse(
      wrap('''
BEGIN:VEVENT
SUMMARY:${'超' * 201}
DTSTART;VALUE=DATE:20260806
END:VEVENT'''),
      today: today,
    );
    expect(result.isValid, isFalse);
    expect(result.issues.single.message, contains('200'));
  });
}
