import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/plan_import/domain/plan_import_parser.dart';

/// 完整计划解析器测试：层级 JSON → ImportedPlan 的映射与校验。
void main() {
  const parser = PlanImportParser();
  // 固定时钟 2026-08-05（与既有测试一致）。
  final today = DateTime(2026, 8, 5, 12);

  /// 最小合法 JSON：单阶段、单周、单科目、单日任务。
  /// [unclassified] 为 null 时不输出该键（部分用例不关心未分类任务）。
  String minimalPlan({
    String start = '2026-08-09',
    String end = '2026-08-15',
    bool withFocus = false,
    bool withMustDo = false,
    String? unclassified,
  }) {
    final focusJson = withFocus ? '"focus": "真题套卷",' : '';
    // daily_must_do 是 subjects 对象内最后一个键：用前置逗号拼接，避免尾逗号。
    final mustDoJson = withMustDo
        ? ',\n            "daily_must_do": ["完成《三大计算》积分专项（每天30分钟）"]'
        : '';
    final unclassifiedJson = unclassified == null
        ? ''
        : ',\n  "unclassified": $unclassified';
    return '''
{
  "plan_name": "2027考研数学备考计划",
  "start_date": "$start",
  "end_date": "$end",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "$start ~ $end",
          $focusJson
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-10": "武忠祥讲义：三重积分（听课+例题）"
              }
            }$mustDoJson
          }
        }
      ]
    }
  ]$unclassifiedJson
}''';
  }

  group('合法导入', () {
    test('最小计划：目标 + 阶段里程碑 + 科目任务 + 未分类', () {
      final result = parser.parse(
        minimalPlan(unclassified: '[{"title": "复盘错题", "date": "2026-08-10"}]'),
        today: today,
      );
      expect(result.isValid, isTrue);
      final plan = result.plan!;
      // 目标。
      expect(plan.goalTitle, '2027考研数学备考计划');
      expect(plan.deadlineDate, '2026-08-15');
      // 阶段里程碑（无 focus，仅阶段级）。
      expect(plan.milestones, hasLength(1));
      expect(plan.milestones.first.title, '强化阶段');
      expect(plan.milestones.first.date, '2026-08-09');
      // 科目任务。
      expect(plan.subjectOrder, ['高等数学']);
      expect(plan.tasks, hasLength(2));
      final mathTask = plan.tasks.firstWhere((t) => t.subjectName == '高等数学');
      expect(mathTask.title, '武忠祥讲义：三重积分（听课+例题）');
      expect(mathTask.date, '2026-08-10');
      // 未分类任务（note 落库）。
      final unclassified = plan.tasks.firstWhere((t) => t.subjectName == null);
      expect(unclassified.title, '复盘错题');
      expect(unclassified.note, isNull);
      // 无模板。
      expect(plan.templates, isEmpty);
      expect(plan.skippedTasks, 0);
    });

    test('unclassified 带 note：note 被保留', () {
      final result = parser.parse(
        minimalPlan(
          unclassified:
              '[{"title": "复盘错题", "date": "2026-08-10", "note": "每周日复盘"}]',
        ),
        today: today,
      );
      expect(result.isValid, isTrue);
      final task = result.plan!.tasks.firstWhere((t) => t.subjectName == null);
      expect(task.note, '每周日复盘');
    });

    test('阶段 + 每周 focus：生成阶段里程碑与周里程碑', () {
      final result = parser.parse(
        minimalPlan(withFocus: true),
        today: today,
      );
      expect(result.isValid, isTrue);
      final plan = result.plan!;
      expect(plan.milestones, hasLength(2));
      expect(plan.milestones[0].title, '强化阶段');
      expect(plan.milestones[0].date, '2026-08-09');
      expect(plan.milestones[1].title, '第 1 周：真题套卷');
      expect(plan.milestones[1].date, '2026-08-09');
    });

    test('daily_must_do：每周生成一个「每天」重复模板，覆盖该周 7 天', () {
      final result = parser.parse(
        minimalPlan(withMustDo: true),
        today: today,
      );
      expect(result.isValid, isTrue);
      final plan = result.plan!;
      expect(plan.templates, hasLength(1));
      final template = plan.templates.single;
      expect(template.title, '完成《三大计算》积分专项（每天30分钟）');
      expect(template.startDate, '2026-08-09');
      expect(template.endDate, '2026-08-15');
      expect(ImportedPlanTemplate.ruleType, 'daily');
      expect(ImportedPlanTemplate.ruleJson, '{}');
    });

    test('daily_must_do 对象写法带 minutes：解析并保留（继承到每天实例）', () {
      final result = parser.parse(
        minimalPlan(
          withMustDo: true,
          // 覆盖 minimalPlan 内的 mustDo 文本写法。
        ).replaceFirst(
          '"daily_must_do": ["完成《三大计算》积分专项（每天30分钟）"]',
          '"daily_must_do": [{ "title": "完成《三大计算》积分专项", "minutes": 30 }]',
        ),
        today: today,
      );
      expect(result.isValid, isTrue);
      final template = result.plan!.templates.single;
      expect(template.title, '完成《三大计算》积分专项');
      expect(template.minutes, 30);
    });

    test('daily_must_do 对象缺 title：整体校验不通过', () {
      final result = parser.parse(
        minimalPlan(withMustDo: true).replaceFirst(
          '"daily_must_do": ["完成《三大计算》积分专项（每天30分钟）"]',
          '"daily_must_do": [{ "minutes": 30 }]',
        ),
        today: today,
      );
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('daily_must_do 条目必须是非空文本')),
      );
    });

    test('daily_must_do 对象 minutes 非法：整体校验不通过', () {
      final result = parser.parse(
        minimalPlan(withMustDo: true).replaceFirst(
          '"daily_must_do": ["完成《三大计算》积分专项（每天30分钟）"]',
          '"daily_must_do": [{ "title": "例行", "minutes": 0 }]',
        ),
        today: today,
      );
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('minutes 必须在 1～1440 之间')),
      );
    });

    test('多周计划：每日任务跨周汇总，模板逐周生成', () {
      const json = '''
{
  "plan_name": "备考计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-22",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-10": "任务A"
              }
            },
            "daily_must_do": ["每天例行1"]
          }
        },
        {
          "week": 2,
          "week_range": "2026-08-16 ~ 2026-08-22",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-17": "任务B"
              }
            },
            "daily_must_do": ["每天例行2"]
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
      final plan = result.plan!;
      expect(plan.tasks.map((t) => t.title).toSet(), {'任务A', '任务B'});
      expect(plan.templates, hasLength(2));
      expect(plan.templates[1].startDate, '2026-08-16');
      expect(plan.templates[1].endDate, '2026-08-22');
    });

    test('未知顶层键被忽略（宽松契约，同 TaskImportParser）', () {
      // 在顶层对象内注入未知键（替换末尾的顶层闭合大括号）。
      final json = minimalPlan().replaceFirstMapped(
        RegExp(r'}$'),
        (_) => ', "extra_key": {"ignored": true}}',
      );
      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
    });
  });

  group('预估时长 minutes（进度页统计依赖，FR-7.4）', () {
    test('unclassified 条目带 minutes：解析并保留', () {
      final result = parser.parse(
        minimalPlan(
          unclassified:
              '[{"title": "复盘错题", "date": "2026-08-10", "minutes": 90}]',
        ),
        today: today,
      );
      expect(result.isValid, isTrue);
      final task = result.plan!.tasks.firstWhere((t) => t.subjectName == null);
      expect(task.minutes, 90);
    });

    test('daily_breakdown 对象写法带 minutes：解析并保留', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-10": { "title": "三重积分（听课+例题）", "minutes": 180 }
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
      final task = result.plan!.tasks.single;
      expect(task.title, '三重积分（听课+例题）');
      expect(task.subjectName, '高等数学');
      expect(task.minutes, 180);
    });

    test('daily_breakdown 文本写法仍兼容：minutes 为 null', () {
      final result = parser.parse(minimalPlan(), today: today);
      expect(result.isValid, isTrue);
      expect(result.plan!.tasks.first.minutes, isNull);
    });

    test('minutes 非整数：整体校验不通过', () {
      final result = parser.parse(
        minimalPlan(
          unclassified:
              '[{"title": "任务", "date": "2026-08-10", "minutes": "90"}]',
        ),
        today: today,
      );
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('minutes 必须是整数')),
      );
    });

    test('minutes 越界（0 / 1441）：整体校验不通过', () {
      for (final bad in [0, 1441]) {
        final result = parser.parse(
          minimalPlan(
            unclassified:
                '[{"title": "任务", "date": "2026-08-10", "minutes": $bad}]',
          ),
          today: today,
        );
        expect(result.isValid, isFalse, reason: 'minutes=$bad 应被拦截');
        expect(
          result.issues.map((i) => i.message),
          anyElement(contains('minutes 必须在 1～1440 之间')),
        );
      }
    });

    test('daily_breakdown 对象缺 title：整体校验不通过', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-10": { "minutes": 180 }
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('任务内容不能为空')),
      );
    });
  });

  group('校验错误', () {
    test('plan_name 缺失', () {
      final result = parser.parse(
        '{ "end_date": "2026-08-15" }',
        today: today,
      );
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('plan_name 必填')),
      );
    });

    test('end_date 缺失', () {
      final result = parser.parse('{ "plan_name": "计划" }', today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('end_date 必填')),
      );
    });

    test('end_date 早于 start_date', () {
      final result = parser.parse(
        '{ "plan_name": "计划", "start_date": "2026-08-15", "end_date": "2026-08-09" }',
        today: today,
      );
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('end_date 不能早于 start_date')),
      );
    });

    test('非对象顶层', () {
      final result = parser.parse('[1, 2]', today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('顶层必须是对象'));
    });

    test('非法 JSON', () {
      final result = parser.parse('{ 不是JSON', today: today);
      expect(result.isValid, isFalse);
      expect(result.issues.single.message, contains('JSON 格式不合法'));
    });

    test('非法日期（2026-02-30 溢出归一化被拦截）', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "数学": {
              "daily_breakdown": {
                "2026-02-30": "任务"
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('2026-02-30 不是有效日期')),
      );
    });

    test('畸形日期文本不崩溃：start_date 非日期 → 校验错误而非异常（S1）', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "abc",
  "end_date": "2026-08-15",
  "stages": []
}''';
      // 不抛异常（旧版 _parseDate 直接 int.parse 抛 FormatException）。
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(result.issues, isNotEmpty);
    });

    test('畸形日期文本不崩溃：daily_breakdown 键非日期 → 校验错误而非异常（S1）', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "数学": {
              "daily_breakdown": {
                "abc": "任务"
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('abc 不是有效日期')),
      );
    });

    test('非零填充日期被规范化（S1：2026-8-6 → 2026-08-06，字典序一致）', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "数学": {
              "daily_breakdown": {
                "2026-8-10": "任务"
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
      final task = result.plan!.tasks.single;
      // 规范化输出：入库日期与 byDate/byDateRange 查询格式一致，任务
      // 不再因字典序错位在日期视图消失。
      expect(task.date, '2026-08-10');
    });

    test('超长阶段/周里程碑标题被拦截（M10）', () {
      final longName = '长' * 201;
      final json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "$longName",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "focus": "周焦点",
          "subjects": {
            "数学": {
              "daily_breakdown": {
                "2026-08-10": "任务"
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('阶段名称不能超过 200 字')),
      );
    });

    test('空科目名被拦截（M10/L11：不再静默写入空名科目）', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "subjects": {
            "": {
              "daily_breakdown": {
                "2026-08-10": "任务"
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('科目名称不能为空')),
      );
    });

    test('当前周模板起始日钳制到今天（L34：不生成历史日期实例）', () {
      final json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-03",
  "end_date": "2026-08-09",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-03 ~ 2026-08-09",
          "subjects": {
            "daily_must_do": ["每日例行"]
          }
        }
      ]
    }
  ]
}''';
      // today = 2026-08-05（周三），周一起始 08-03 已过半。
      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
      expect(result.plan!.templates.single.startDate, '2026-08-05');
      expect(result.plan!.templates.single.endDate, '2026-08-09');
    });

    test('里程碑日期晚于截止日（FR-2.2 语义，导入侧校验）', () {
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-08-09",
  "end_date": "2026-08-15",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-30 ~ 2026-09-05",
          "subjects": {
            "数学": {
              "daily_breakdown": {
                "2026-08-10": "任务"
              }
            }
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isFalse);
      expect(
        result.issues.map((i) => i.message),
        anyElement(contains('里程碑「阶段」日期晚于目标截止日')),
      );
    });
  });

  group('日期策略（历史任务跳过）', () {
    test('早于今天的任务跳过并计入统计', () {
      final result = parser.parse(
        minimalPlan(unclassified: '[{"title": "旧任务", "date": "2026-08-01"}]'),
        today: today,
      );
      expect(result.isValid, isTrue);
      final plan = result.plan!;
      expect(plan.skippedTasks, 1);
      expect(plan.tasks.where((t) => t.title == '旧任务'), isEmpty);
    });

    test('整周已过去的 daily_must_do 模板跳过并统计', () {
      // 模板周 2026-07-26 ~ 08-01 早于今天（08-05）整周过去。
      const json = '''
{
  "plan_name": "计划",
  "start_date": "2026-07-26",
  "end_date": "2026-08-01",
  "stages": [
    {
      "stage": "阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-07-26 ~ 2026-08-01",
          "subjects": {
            "daily_must_do": ["每天例行"]
          }
        }
      ]
    }
  ]
}''';
      final result = parser.parse(json, today: today);
      expect(result.isValid, isTrue);
      final plan = result.plan!;
      expect(plan.skippedTemplates, 1);
      expect(plan.templates, isEmpty);
    });

    test('目标/里程碑日期不跳过（历史计划期保留，不报错）', () {
      final result = parser.parse(
        minimalPlan(start: '2026-07-01', end: '2026-08-05'),
        today: today,
      );
      expect(result.isValid, isTrue);
      expect(result.plan!.deadlineDate, '2026-08-05');
    });
  });
}
