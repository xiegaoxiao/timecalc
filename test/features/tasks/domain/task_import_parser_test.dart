import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/tasks/domain/task_import_parser.dart';

/// TaskImportParser 单元测试（JSON 合法性 / 日期校验 / 科目与未分类隔离）。
void main() {
  const parser = TaskImportParser();
  final today = DateTime(2026, 8, 5, 12); // 周三

  group('合法导入', () {
    test('科目与未分类任务隔离解析', () {
      const json = '''
      {
        "subjects": {
          "数学": [ { "title": "真题 2013", "date": "2026-08-06", "minutes": 180 } ],
          "英语": [ { "title": "真题 2023", "date": "2026-08-07" } ]
        },
        "unclassified": [ { "title": "复盘", "date": "2026-08-06" } ]
      }''';

      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
      expect(result.plan!.items, hasLength(3));
      expect(result.plan!.subjectOrder, ['数学', '英语']);

      final mathTask = result.plan!.items[0];
      expect(mathTask.title, '真题 2013');
      expect(mathTask.subjectName, '数学');
      expect(mathTask.date, '2026-08-06');
      expect(mathTask.minutes, 180);

      final unclassified = result.plan!.items[2];
      expect(unclassified.subjectName, isNull);
    });

    test('今天的日期允许', () {
      const json = '{"unclassified": [ { "title": "今日任务", "date": "2026-08-05" } ]}';
      expect(parser.parse(json, today: today).isValid, isTrue);
    });

    test('缺少 subjects/unclassified 时解析失败', () {
      const json = '{"foo": []}';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('没有可导入的任务'));
    });

    test('未知顶层键被忽略（宽松）', () {
      const json = '{"unclassified": [{"title":"A","date":"2026-08-06"}], "note": "x"}';
      expect(parser.parse(json, today: today).isValid, isTrue);
    });
  });

  group('JSON 结构校验', () {
    test('非法 JSON 语法', () {
      final result = parser.parse('{ 这不是 JSON', today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('JSON 格式不合法'));
    });

    test('顶层不是对象', () {
      final result = parser.parse('[1, 2]', today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('顶层必须是对象'));
    });

    test('subjects 不是对象', () {
      const json = '{"subjects": [1, 2]}';
      expect(parser.parse(json, today: today).issues.single.message, contains('subjects 必须是对象'));
    });

    test('科目值为空数组仍通过，但无任务时报错', () {
      const json = '{"subjects": {"数学": []}}';
      expect(parser.parse(json, today: today).issues.single.message, contains('没有可导入的任务'));
    });

    test('任务项不是对象', () {
      const json = '{"unclassified": ["字符串"]}';
      final result = parser.parse(json, today: today);
      expect(result.issues.single.location, '未分类 · 第 1 项');
      expect(result.issues.single.message, contains('必须是对象'));
    });

    test('title 缺失或为空', () {
      const json = '{"unclassified": [ { "date": "2026-08-06" } ]}';
      expect(parser.parse(json, today: today).issues.single.message, contains('title 必填'));
      const json2 = '{"unclassified": [ { "title": "  ", "date": "2026-08-06" } ]}';
      expect(parser.parse(json2, today: today).issues.single.message, contains('title 必填'));
    });

    test('title 超过 200 字被拒绝（与数据库约束一致，回归）', () {
      final longTitle = '长' * 201;
      final json = '{"unclassified": [{"title": "$longTitle", "date": "2026-08-06"}]}';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('200'));
    });

    test('科目名称超过 100 字被拒绝（回归）', () {
      final longSubject = '科' * 101;
      final json = '{"subjects": {"$longSubject": [{"title": "A", "date": "2026-08-06"}]}}';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('100'));
    });

    test('minutes 非法', () {
      const badType = '{"unclassified": [{"title":"A","date":"2026-08-06","minutes":"180"}]}';
      expect(parser.parse(badType, today: today).issues.single.message, contains('minutes 必须是整数'));
      const badRange = '{"unclassified": [{"title":"A","date":"2026-08-06","minutes":1441}]}';
      expect(parser.parse(badRange, today: today).issues.single.message, contains('1～1440'));
    });
  });

  group('日期校验', () {
    test('格式不合法', () {
      const json = '{"unclassified": [{"title":"A","date":"2026/08/06"}]}';
      expect(parser.parse(json, today: today).issues.single.message, contains('yyyy-MM-dd'));
    });

    test('非法日历日期（2026-02-30）', () {
      const json = '{"unclassified": [{"title":"A","date":"2026-02-30"}]}';
      expect(parser.parse(json, today: today).issues.single.message, contains('不是有效日期'));
    });

    test('早于今天的日期被拒绝', () {
      const json = '{"unclassified": [{"title":"A","date":"2026-08-04"}]}';
      final issue = parser.parse(json, today: today).issues.single;
      expect(issue.message, contains('不能早于今天'));
    });

    test('多条目错误全部收集并带位置', () {
      const json = '''
      {
        "subjects": {
          "数学": [ { "title": "A", "date": "2026-02-30" } ]
        },
        "unclassified": [
          { "title": "B", "date": "2026-08-04" },
          { "title": "  ", "date": "2026-08-06" }
        ]
      }''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(result.issues, hasLength(3));
      expect(result.issues[0].location, '科目「数学」 · 第 1 项');
      expect(result.issues[1].location, '未分类 · 第 1 项');
      expect(result.issues[2].location, '未分类 · 第 2 项');
    });
  });
}
