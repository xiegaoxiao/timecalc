import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/calendar_io/domain/ics_codec.dart';

/// iCalendar（RFC 5545 子集）编解码单元测试。
void main() {
  const codec = IcsCodec();

  /// 包一层 VCALENDAR，便于拼测试用例。
  String wrap(String body, {String? extraProperty}) => [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Test//Test//CN',
    ?extraProperty,
    body,
    'END:VCALENDAR',
    '',
  ].join('\r\n');

  group('parse：DTSTART 形态', () {
    test('VALUE=DATE 解析为全天事件', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
UID:a@test
SUMMARY:背单词
DTSTART;VALUE=DATE:20260805
END:VEVENT'''),
      );
      final event = calendar.events.single;
      expect(event.summary, '背单词');
      expect(event.startDate, '2026-08-05');
      expect(event.startTime, isNull);
      expect(event.isAllDay, isTrue);
    });

    test('8 位日期值（无 VALUE=DATE）同样按全天处理', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:交作业
DTSTART:20260806
END:VEVENT'''),
      );
      expect(calendar.events.single.isAllDay, isTrue);
      expect(calendar.events.single.startDate, '2026-08-06');
    });

    test('浮动本地时间解析出钟点', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:数学真题
DTSTART:20260805T203000
END:VEVENT'''),
      );
      final event = calendar.events.single;
      expect(event.startDate, '2026-08-05');
      expect(event.startTime, '20:30');
      expect(event.isAllDay, isFalse);
    });

    test('带 Z 的 UTC 时间转成本地日期与钟点', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:跨国会议
DTSTART:20260805T010000Z
END:VEVENT'''),
      );
      // 期望值由本机时区换算得出，测试不依赖运行环境所在时区。
      final expected = DateTime.utc(2026, 8, 5, 1).toLocal();
      final event = calendar.events.single;
      expect(
        event.startDate,
        '${expected.year}-${expected.month.toString().padLeft(2, '0')}-'
        '${expected.day.toString().padLeft(2, '0')}',
      );
      expect(
        event.startTime,
        '${expected.hour.toString().padLeft(2, '0')}:'
        '${expected.minute.toString().padLeft(2, '0')}',
      );
    });

    test('带 TZID 的时间按墙上时间原样保留', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:东京课程
DTSTART;TZID=Asia/Tokyo:20260805T090000
END:VEVENT'''),
      );
      expect(calendar.events.single.startTime, '09:00');
    });
  });

  group('parse：时长与结束时间', () {
    test('DTEND − DTSTART 推导时长', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:听课
DTSTART:20260805T080000
DTEND:20260805T103000
END:VEVENT'''),
      );
      expect(calendar.events.single.durationMinutes, 150);
      expect(calendar.events.single.endTime, '10:30');
    });

    test('DURATION 推导时长（PT1H30M）', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:套卷
DTSTART:20260805T140000
DURATION:PT1H30M
END:VEVENT'''),
      );
      expect(calendar.events.single.durationMinutes, 90);
    });

    test('DURATION P1D 与 PT90M 等价，负时长视为无效', () {
      final positive = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:整天
DTSTART;VALUE=DATE:20260805
DURATION:P1D
END:VEVENT'''),
      );
      expect(positive.events.single.durationMinutes, 1440);

      final negative = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:负时长
DTSTART:20260805T140000
DURATION:-PT15M
END:VEVENT'''),
      );
      expect(negative.events.single.durationMinutes, isNull);
    });
  });

  group('parse：文本与折行', () {
    test('反转义 \\n \\, \\; \\\\', () {
      final calendar = codec.parse(
        wrap(
          'BEGIN:VEVENT\r\n'
          'SUMMARY:第一行\\n第二行\r\n'
          'DESCRIPTION:含\\,逗号\\;分号\\\\反斜杠\r\n'
          'DTSTART;VALUE=DATE:20260805\r\n'
          'END:VEVENT',
        ),
      );
      final event = calendar.events.single;
      expect(event.summary, '第一行\n第二行');
      expect(event.description, r'含,逗号;分号\反斜杠');
    });

    test('折行的长标题被还原为一行', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:这是一个很长的中文标题用来验证折行还原是否正常工作
 续行部分
DTSTART;VALUE=DATE:20260805
END:VEVENT'''),
      );
      expect(calendar.events.single.summary, '这是一个很长的中文标题用来验证折行还原是否正常工作续行部分');
    });

    test('读取 X-WR-CALNAME 作为日历名', () {
      final calendar = codec.parse(
        wrap(
          'BEGIN:VEVENT\r\nSUMMARY:事件\r\nDTSTART;VALUE=DATE:20260805\r\nEND:VEVENT',
          extraProperty: 'X-WR-CALNAME:考研日历',
        ),
      );
      expect(calendar.name, '考研日历');
    });
  });

  group('parse：容错', () {
    test('忽略 VTIMEZONE / VALARM / VTODO 等其他组件', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VTIMEZONE
TZID:Asia/Shanghai
BEGIN:STANDARD
TZOFFSETFROM:+0800
TZOFFSETTO:+0800
DTSTART:19700101T000000
END:STANDARD
END:VTIMEZONE
BEGIN:VTODO
SUMMARY:这不是日程
DTSTART;VALUE=DATE:20260805
END:VTODO
BEGIN:VEVENT
SUMMARY:真正的日程
DTSTART;VALUE=DATE:20260805
END:VEVENT'''),
      );
      expect(calendar.events.length, 1);
      expect(calendar.events.single.summary, '真正的日程');
    });

    test('缺 SUMMARY 或 DTSTART 的事件被跳过，不影响其余事件', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
DTSTART;VALUE=DATE:20260805
END:VEVENT
BEGIN:VEVENT
SUMMARY:无开始时间
END:VEVENT
BEGIN:VEVENT
SUMMARY:正常事件
DTSTART;VALUE=DATE:20260806
END:VEVENT'''),
      );
      expect(calendar.events.length, 1);
      expect(calendar.events.single.summary, '正常事件');
    });

    test('STATUS:CANCELLED 被标记为已取消', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:已取消的课
STATUS:CANCELLED
DTSTART:20260805T090000
END:VEVENT'''),
      );
      expect(calendar.events.single.isCancelled, isTrue);
    });

    test('非法日期的事件被跳过', () {
      final calendar = codec.parse(
        wrap('''
BEGIN:VEVENT
SUMMARY:2 月 30 日
DTSTART;VALUE=DATE:20260230
END:VEVENT'''),
      );
      expect(calendar.events, isEmpty);
    });

    test('缺少 VCALENDAR 抛 FormatException', () {
      expect(() => codec.parse('SUMMARY:孤立事件'), throwsFormatException);
    });
  });

  group('serialize', () {
    test('全天事件写 VALUE=DATE 且不写 DTEND', () {
      final text = codec.serialize(
        const IcsCalendar(
          name: '我的计划',
          events: [
            IcsEvent(uid: 'u1@test', summary: '背单词', startDate: '2026-08-05'),
          ],
        ),
        stamp: DateTime.utc(2026, 8, 1, 12),
      );
      expect(text, contains('BEGIN:VCALENDAR'));
      expect(text, contains('VERSION:2.0'));
      expect(text, contains('X-WR-CALNAME:我的计划'));
      expect(text, contains('DTSTART;VALUE=DATE:20260805'));
      expect(text, contains('DTSTAMP:20260801T120000Z'));
      expect(text, contains('UID:u1@test'));
      expect(text, isNot(contains('DTEND')));
      // CRLF 行尾 + 末尾换行。
      expect(text, endsWith('END:VCALENDAR\r\n'));
    });

    test('定时事件按预估时长写 DTEND（缺省 1 小时）', () {
      final withDuration = codec.serialize(
        const IcsCalendar(
          events: [
            IcsEvent(
              summary: '听课',
              startDate: '2026-08-05',
              startTime: '08:30',
              durationMinutes: 150,
            ),
          ],
        ),
      );
      expect(withDuration, contains('DTSTART:20260805T083000'));
      expect(withDuration, contains('DTEND:20260805T110000'));

      final withoutDuration = codec.serialize(
        const IcsCalendar(
          events: [
            IcsEvent(
              summary: '听课',
              startDate: '2026-08-05',
              startTime: '08:30',
            ),
          ],
        ),
      );
      expect(withoutDuration, contains('DTEND:20260805T093000'));
    });

    test('跨天的定时事件结束日期进位', () {
      final text = codec.serialize(
        const IcsCalendar(
          events: [
            IcsEvent(
              summary: '熬夜冲刺',
              startDate: '2026-08-05',
              startTime: '23:30',
              durationMinutes: 120,
            ),
          ],
        ),
      );
      expect(text, contains('DTSTART:20260805T233000'));
      expect(text, contains('DTEND:20260806T013000'));
    });

    test('文本转义分号/逗号/换行/反斜杠', () {
      final text = codec.serialize(
        const IcsCalendar(
          events: [
            IcsEvent(
              summary: '数学;英语,政治',
              description: '第一行\n第二行\\结尾',
              startDate: '2026-08-05',
            ),
          ],
        ),
      );
      expect(text, contains(r'SUMMARY:数学\;英语\,政治'));
      expect(text, contains(r'DESCRIPTION:第一行\n第二行\\结尾'));
      // 全角标点不是分隔符，保持原样（避免无谓转义）。
      final fullWidth = codec.serialize(
        const IcsCalendar(
          events: [IcsEvent(summary: '数学；英语，政治', startDate: '2026-08-05')],
        ),
      );
      expect(fullWidth, contains('SUMMARY:数学；英语，政治'));
    });

    test('按 UTF-8 字节折行：中文长标题每行不超过 75 字节', () {
      final longTitle = '线性表' * 40; // 每字 3 字节，必然需要折行
      final text = codec.serialize(
        IcsCalendar(
          events: [IcsEvent(summary: longTitle, startDate: '2026-08-05')],
        ),
      );
      final lines = text.split('\r\n');
      for (final line in lines) {
        expect(
          utf8.encode(line).length,
          lessThanOrEqualTo(75),
          reason: '行超出 75 字节：$line',
        );
      }
      expect(lines.where((l) => l.startsWith(' ')).length, greaterThan(0));
    });

    test('解析与序列化往返：定时事件保真', () {
      const original = IcsCalendar(
        name: '考研日历',
        events: [
          IcsEvent(
            uid: 't1@test',
            summary: '高数：三重积分',
            description: '例题 1-10',
            startDate: '2026-08-05',
            startTime: '08:30',
            durationMinutes: 180,
          ),
          IcsEvent(uid: 't2@test', summary: '全天复盘', startDate: '2026-08-06'),
        ],
      );
      final roundTripped = codec.parse(codec.serialize(original));
      expect(roundTripped.name, '考研日历');
      expect(roundTripped.events.length, 2);

      final first = roundTripped.events.first;
      expect(first.summary, '高数：三重积分');
      expect(first.description, '例题 1-10');
      expect(first.startDate, '2026-08-05');
      expect(first.startTime, '08:30');
      expect(first.durationMinutes, 180);

      final second = roundTripped.events.last;
      expect(second.summary, '全天复盘');
      expect(second.isAllDay, isTrue);
    });
  });
}
