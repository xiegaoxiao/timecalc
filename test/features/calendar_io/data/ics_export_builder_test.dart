import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/calendar_io/data/ics_export_builder.dart';
import 'package:timecalc/features/calendar_io/domain/ics_codec.dart';

/// 计划 → .ics 导出构造测试。
void main() {
  const builder = IcsExportBuilder();
  const codec = IcsCodec();

  Task task({
    required int id,
    String title = '任务',
    String plannedDate = '2026-08-06',
    String? startTime,
    int? estimatedMinutes,
    String? note,
    String status = 'todo',
    DateTime? archivedAt,
  }) {
    final now = DateTime.utc(2026, 8, 1);
    return Task(
      id: id,
      goalId: 1,
      subjectId: null,
      title: title,
      note: note,
      plannedDate: plannedDate,
      startTime: startTime,
      estimatedMinutes: estimatedMinutes,
      status: status,
      completedAt: null,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
      originalPlannedDate: null,
      archivedAt: archivedAt,
      recurrenceTemplateId: null,
  );
  }

  Milestone milestone({required int id, String title = '里程碑'}) {
    final now = DateTime.utc(2026, 8, 1);
    return Milestone(
      id: id,
      goalId: 1,
      title: title,
      date: '2026-08-20',
      status: 'todo',
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('任务导出为 VEVENT：日期/时刻/时长/备注，UID 稳定可复现', () {
    final calendar = builder.build(
      tasks: [
        task(
          id: 7,
          title: '高数：三重积分',
          startTime: '08:30',
          estimatedMinutes: 180,
          note: '例题 1-10',
        ),
      ],
      calendarName: 'TimeCalc 学习计划',
    );

    final event = calendar.events.single;
    expect(event.uid, 'timecalc-task-7@timecalc.local');
    expect(event.summary, '高数：三重积分');
    expect(event.startDate, '2026-08-06');
    expect(event.startTime, '08:30');
    expect(event.durationMinutes, 180);
    expect(event.description, contains('例题 1-10'));
    expect(event.description, contains('3 小时')); // 时长备注

    final text = builder.serialize(
      calendar,
      stamp: DateTime.utc(2026, 8, 1, 9),
    );
    expect(text, contains('X-WR-CALNAME:TimeCalc 学习计划'));
    expect(text, contains('DTSTART:20260806T083000'));
    expect(text, contains('DTEND:20260806T113000'));
    expect(text, contains('SUMMARY:高数：三重积分'));
  });

  test('只排到天的任务导出为全天事件（VALUE=DATE）', () {
    final calendar = builder.build(tasks: [task(id: 1, title: '复盘')]);
    final text = builder.serialize(calendar);
    expect(text, contains('DTSTART;VALUE=DATE:20260806'));
    expect(text, isNot(contains('DTEND')));
  });

  test('已完成任务进描述（不写成 CANCELLED）', () {
    final calendar = builder.build(tasks: [task(id: 2, status: 'done')]);
    final text = builder.serialize(calendar);
    expect(text, contains('STATUS:CONFIRMED'));
    expect(text, contains('已完成'));
    expect(text, isNot(contains('CANCELLED')));
  });

  test('归档任务不导出；里程碑导出为全天事件', () {
    final calendar = builder.build(
      tasks: [
        task(id: 1, title: '活跃'),
        task(id: 2, title: '已归档', archivedAt: DateTime.utc(2026, 8, 2)),
      ],
      milestones: [milestone(id: 3, title: '强化阶段')],
    );
    expect(calendar.events.map((e) => e.summary), ['活跃', '强化阶段']);
    expect(calendar.events.last.uid, 'timecalc-milestone-3@timecalc.local');
    expect(calendar.events.last.isAllDay, isTrue);
  });

  test('导出文本可被解析回同一批事件（自洽性）', () {
    final calendar = builder.build(
      tasks: [
        task(id: 1, title: '背单词', startTime: '20:30', estimatedMinutes: 30),
        task(id: 2, title: '套卷', plannedDate: '2026-08-07'),
      ],
    );
    final parsed = codec.parse(builder.serialize(calendar));
    expect(parsed.events.length, 2);
    expect(parsed.events.first.summary, '背单词');
    expect(parsed.events.first.startTime, '20:30');
    expect(parsed.events.first.durationMinutes, 30);
    expect(parsed.events.last.summary, '套卷');
    expect(parsed.events.last.isAllDay, isTrue);
  });
}
