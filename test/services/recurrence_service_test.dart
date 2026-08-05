import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/tasks/domain/recurrence/rule_param.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_handler.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_registry.dart';
import 'package:timecalc/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:timecalc/services/recurrence_service.dart';

/// RecurrenceService / 规则引擎单元测试（FR-4，可扩展性）。
void main() {
  final service = RecurrenceService();

  group('occurrences（发生日窗口）', () {
    test('每天：起始日起逐日生成，受窗口限制', () {
      final dates = service.occurrences(
        ruleType: 'daily',
        json: const {},
        startDate: '2026-08-05',
        from: '2026-08-07',
        to: '2026-08-10',
      );
      expect(dates, ['2026-08-07', '2026-08-08', '2026-08-09', '2026-08-10']);
    });

    test('每周指定星期：仅生成选中星期', () {
      // 2026-08-05 为周三。起始日起每周一/三/五。
      final dates = service.occurrences(
        ruleType: 'weekly',
        json: const {'weekdays': [1, 3, 5]},
        startDate: '2026-08-05',
        from: '2026-08-05',
        to: '2026-08-12',
      );
      // 8/5(三)、8/7(五)、8/10(一)、8/12(三)。
      expect(dates, ['2026-08-05', '2026-08-07', '2026-08-10', '2026-08-12']);
    });

    test('每隔 N 天：起始日 + k·N', () {
      final dates = service.occurrences(
        ruleType: 'interval',
        json: const {'everyNDays': 3},
        startDate: '2026-08-05',
        from: '2026-08-05',
        to: '2026-08-12',
      );
      expect(dates, ['2026-08-05', '2026-08-08', '2026-08-11']);
    });

    test('间隔序列（艾宾浩斯默认 1,2,4,7,15,30）：第 1 次起始日当天，之后累计', () {
      final dates = service.occurrences(
        ruleType: 'sequence',
        json: const {'offsets': [1, 2, 4, 7, 15, 30]},
        startDate: '2026-08-05',
        from: '2026-08-05',
        to: '2026-09-30',
      );
      // 起始日 + 1、+1+2=3、+1+2+4=7、+1+2+4+7=14、+29（+59 超出窗口截断）。
      expect(dates, [
        '2026-08-05', // 第 1 次
        '2026-08-06', // +1
        '2026-08-08', // +3
        '2026-08-12', // +7
        '2026-08-19', // +14
        '2026-09-03', // +29
      ]);
    });

    test('间隔序列自定义序列', () {
      final dates = service.occurrences(
        ruleType: 'sequence',
        json: const {'offsets': [2, 5]},
        startDate: '2026-08-05',
        from: '2026-08-05',
        to: '2026-08-20',
      );
      expect(dates, ['2026-08-05', '2026-08-07', '2026-08-12']);
    });

    test('窗口 from 晚于起始日时只返回窗口内日期', () {
      final dates = service.occurrences(
        ruleType: 'daily',
        json: const {},
        startDate: '2026-08-05',
        from: '2026-08-10',
        to: '2026-08-12',
      );
      expect(dates, ['2026-08-10', '2026-08-11', '2026-08-12']);
    });
  });

  group('validate（规则校验）', () {
    test('weekly 至少一个星期', () {
      expect(service.validateRaw('weekly', const {'weekdays': []}), isNotNull);
      expect(service.validateRaw('weekly', const {'weekdays': [1]}), isNull);
    });

    test('interval 1～365', () {
      expect(service.validateRaw('interval', const {'everyNDays': 0}), isNotNull);
      expect(service.validateRaw('interval', const {'everyNDays': 366}), isNotNull);
      expect(service.validateRaw('interval', const {'everyNDays': 2}), isNull);
    });

    test('sequence 序列非空且为正整数', () {
      expect(service.validateRaw('sequence', const {'offsets': []}), isNotNull);
      expect(service.validateRaw('sequence', const {'offsets': [0]}), isNotNull);
      expect(service.validateRaw('sequence', const {'offsets': [1, 2, 4]}), isNull);
    });

    test('未知类型被拒绝', () {
      expect(service.validateRaw('unknown', const {}), contains('未知的规则类型'));
    });
  });

  group('RecurrenceRule 序列化往返', () {
    test('fromMap → ruleJson → jsonMap', () {
      final rule = RecurrenceRule.fromMap(
        ruleType: 'sequence',
        json: const {'offsets': [1, 2, 4]},
      );
      expect(rule.ruleType, 'sequence');
      expect(rule.jsonMap, {'offsets': [1, 2, 4]});
      expect(rule.validateWith(RecurrenceRuleRegistry()), isNull);
    });

    test('非法 ruleJson 解析为空 map', () {
      final rule = RecurrenceRule(ruleType: 'daily', ruleJson: 'not json');
      expect(rule.jsonMap, isEmpty);
    });
  });

  group('可扩展性：注册新 handler 即被全局使用', () {
    test('自定义规则无需改动数据层/生成逻辑即可接入', () {
      final registry = RecurrenceRuleRegistry();
      registry.register(_OddDaysHandler());

      expect(registry.handlerFor('odd-days'), isNotNull);

      // 对话框类型列表自动包含新规则（默认在末位）。
      expect(
        registry.all.map((h) => h.type),
        containsAll(['daily', 'weekly', 'interval', 'sequence', 'odd-days']),
      );

      // 生成逻辑自动可用。
      final dates = registry.occurrences(
        type: 'odd-days',
        json: const {},
        startDate: '2026-08-05',
        from: '2026-08-05',
        to: '2026-08-10',
      );
      expect(dates, ['2026-08-05', '2026-08-07', '2026-08-09']);
    });
  });
}

/// 测试用自定义规则：只在日期数字为奇数天发生（验证扩展性）。
class _OddDaysHandler extends RecurrenceRuleHandler {
  @override
  String get type => 'odd-days';
  @override
  String get label => '奇数天';
  @override
  List<RuleParam> get params => const [];
  @override
  Map<String, dynamic> defaultJson() => const {};
  @override
  String? validate(Map<String, dynamic> json) => null;

  @override
  List<String> occurrences({
    required Map<String, dynamic> json,
    required String startDate,
    required String from,
    required String to,
  }) {
    final out = <String>[];
    final start = _parse(startDate);
    final fromD = _parse(from);
    final toD = _parse(to);
    var cursor = start;
    while (!cursor.isAfter(toD)) {
      if (!cursor.isBefore(fromD) && cursor.day.isOdd) {
        out.add(_format(cursor));
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return out;
  }

  static DateTime _parse(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  static String _format(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}
