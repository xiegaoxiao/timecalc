import 'package:drift/native.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/plan_import/data/plan_json_picker.dart';

import '../../../shared/nav_helper.dart';

/// 假 JSON 文件选择器：按序返回内容，null 模拟取消，可抛异常模拟读取失败。
class FakePlanJsonPicker implements PlanJsonPicker {
  FakePlanJsonPicker(this.results);

  final List<Object?> results; // String? / Exception
  int calls = 0;

  @override
  Future<String?> pickJson() async {
    if (calls >= results.length) return null;
    final result = results[calls++];
    if (result is Exception) throw result;
    return result as String?;
  }
}

/// 完整计划导入用户流程 Widget 测试。
void main() {
  late AppDatabase db;
  late FakePlanJsonPicker picker;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => DateTime(2026, 8, 5, 12)),
          planJsonPickerProvider.overrideWithValue(picker),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    picker = FakePlanJsonPicker([]);
  });

  tearDown(() async {
    await db.close();
  });

  /// 切到「目标」页（v1.12 起「导入完整计划」入口在目标页 AppBar；
  /// 默认落在「今天」tab，目标页 AppBar 处于 offstage）。
  Future<void> goPlan(WidgetTester tester) async {
    await tapNavDestination(tester, '目标');
  }

  /// 合法完整计划 JSON（固定时钟 2026-08-05，日期不早于今天）。
  const planJson = '''
{
  "plan_name": "2027考研数学备考计划",
  "start_date": "2026-08-09",
  "end_date": "2026-12-18",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "focus": "真题套卷",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-10": "武忠祥讲义：三重积分（听课+例题）"
              }
            },
            "daily_must_do": ["完成《三大计算》积分专项（每天30分钟）"]
          }
        }
      ]
    }
  ],
  "unclassified": [
    { "title": "复盘错题", "date": "2026-08-11", "note": "每周日复盘" }
  ]
}''';

  testWidgets('导入完整计划：新建目标并跳转详情，各表落库完整', (tester) async {
    await pumpApp(tester);
    await goPlan(tester);

    // 目标页 AppBar 打开「导入完整计划」。
    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();
    expect(find.text('导入完整计划'), findsOneWidget);

    // 粘贴 JSON 并等待自动校验（400ms 防抖）。
    await tester.enterText(find.byType(TextField).last, planJson);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // 校验通过 + 预览（目标/里程碑/科目任务/重复模板）。
    expect(find.text('校验通过：2 个任务'), findsOneWidget);
    expect(find.text('目标「2027考研数学备考计划」· 截止 2026-12-18'), findsOneWidget);
    expect(find.textContaining('2 个里程碑'), findsOneWidget);
    expect(find.text('科目「高等数学」1 个任务'), findsOneWidget);
    expect(find.text('1 个每天重复任务（每周例行）'), findsOneWidget);

    // 导入 → 跳转新目标详情页。
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('目标详情'), findsOneWidget);
    // 详情页展示导入的内容：里程碑 + 科目卡片 + 未分类任务
    // （科目任务列表在科目任务页，此处经数据库断言）。
    expect(find.text('强化阶段'), findsOneWidget);
    expect(find.text('第 1 周：真题套卷'), findsOneWidget);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('复盘错题'), findsOneWidget);

    // 数据库断言。
    final goal = (await db.select(db.goals).get()).single;
    expect(goal.title, '2027考研数学备考计划');
    expect(goal.deadlineDate, '2026-12-18');
    expect(await db.select(db.milestones).get(), hasLength(2));
    final subjects = await db.select(db.subjects).get();
    expect(subjects, hasLength(1));
    expect(subjects.single.name, '高等数学');
    // 任务：1 科目 + 1 未分类 + 7 模板实例（08-09 ~ 08-15 每天）。
    final tasks = await db.select(db.tasks).get();
    expect(tasks, hasLength(9));
    expect(tasks.where((t) => t.recurrenceTemplateId == null), hasLength(2));
    final template = (await db.select(db.recurrenceTemplates).get()).single;
    expect(template.ruleType, 'daily');
    // 未分类任务的 note 落库。
    final unclassified = tasks.firstWhere((t) => t.title == '复盘错题');
    expect(unclassified.note, '每周日复盘');
  });

  testWidgets('校验失败不写入任何数据', (tester) async {
    await pumpApp(tester);
    await goPlan(tester);

    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();

    // 非法 JSON：plan_name 缺失。
    await tester.enterText(
      find.byType(TextField).last,
      '{"start_date":"2026-08-09","end_date":"2026-08-15"}',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('发现 1 个问题'), findsOneWidget);
    expect(find.textContaining('plan_name 必填'), findsOneWidget);
    // 点「导入」兜底校验：仍失败，不写入。
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('导入完整计划'), findsOneWidget);
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.tasks).get(), isEmpty);
  });

  testWidgets('选择文件：读取 JSON 填入并自动校验通过', (tester) async {
    picker = FakePlanJsonPicker([planJson]);
    await pumpApp(tester);
    await goPlan(tester);
    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();

    // 点「选择文件」→ fake 返回 JSON 内容 → 填入输入框并自动校验。
    await tester.tap(find.text('选择文件'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(find.text('校验通过：2 个任务'), findsOneWidget);
    expect(find.text('目标「2027考研数学备考计划」· 截止 2026-12-18'), findsOneWidget);
  });

  testWidgets('选择文件：取消选择不动输入框', (tester) async {
    picker = FakePlanJsonPicker([null]); // 取消。
    await pumpApp(tester);
    await goPlan(tester);
    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();

    // 先把示例文本换成非法 JSON，再取消选择：内容保持不变。
    await tester.enterText(find.byType(TextField).last, '非法内容');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('发现 1 个问题'), findsOneWidget);

    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    // 内容未被替换，错误状态仍在。
    expect(find.text('发现 1 个问题'), findsOneWidget);
  });

  testWidgets('选择文件：读取失败提示 SnackBar', (tester) async {
    picker = FakePlanJsonPicker([Exception('权限不足')]);
    await pumpApp(tester);
    await goPlan(tester);
    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取文件失败'), findsOneWidget);
  });

  testWidgets('导入完整计划后进度页立即更新（回归：导入后全量失效）', (tester) async {
    await pumpApp(tester);
    await goPlan(tester);

    // 先访问进度页：无目标无任务，今日概览「目标剩余工作量」显示 -- 分。
    await tapNavDestination(tester, '进度');
    final overviewBefore = find.widgetWithText(Card, '今日概览');
    expect(
      find.descendant(of: overviewBefore, matching: find.text('-- 分')),
      findsNWidgets(2), // 已完成时长 + 目标剩余工作量
    );

    // 回目标页导入完整计划（含未完成任务 → 有数据但无时长）。
    await tapNavDestination(tester, '目标');
    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, planJson);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle(); // 自动跳转目标详情页

    // 返回并切到进度页：今日概览已更新——有任务后「目标剩余」显示 0 分
    // （无时长任务不计分钟，但 -- 无数据占位消失），已完成时长仍 -- 分。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tapNavDestination(tester, '进度');
    final overviewAfter = find.widgetWithText(Card, '今日概览');
    expect(
      find.descendant(of: overviewAfter, matching: find.text('-- 分')),
      findsOneWidget, // 仅已完成时长
    );
    expect(
      find.descendant(of: overviewAfter, matching: find.text('0 分')),
      findsOneWidget, // 目标剩余工作量
    );
  });

  testWidgets('导入带 minutes 的完整计划后进度页显示剩余工作量（回归：进度全空）',
      (tester) async {
    // 用户实际 JSON 结构：daily_breakdown 对象带时长、daily_must_do 对象
    // 带时长（继承到每天实例）、unclassified 带时长。
    const planWithMinutes = '''
{
  "plan_name": "2027考研数学备考计划",
  "start_date": "2026-08-09",
  "end_date": "2026-12-18",
  "stages": [
    {
      "stage": "强化阶段",
      "weekly_plan": [
        {
          "week": 1,
          "week_range": "2026-08-09 ~ 2026-08-15",
          "focus": "真题套卷",
          "subjects": {
            "高等数学": {
              "daily_breakdown": {
                "2026-08-10": { "title": "三重积分（听课+例题）", "minutes": 180 }
              }
            },
            "daily_must_do": [
              { "title": "完成《三大计算》积分专项", "minutes": 30 }
            ]
          }
        }
      ]
    }
  ],
  "unclassified": [
    { "title": "复盘错题", "date": "2026-08-11", "note": "每周日复盘", "minutes": 90 }
  ]
}''';

    await pumpApp(tester);
    await goPlan(tester);

    // 导入带时长的完整计划。
    await tester.tap(find.byTooltip('导入完整计划'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, planWithMinutes);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    // 校验通过：2 个任务 + 1 个例行模板（均带时长）。
    expect(find.text('校验通过：2 个任务'), findsOneWidget);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle(); // 自动跳转目标详情页
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // 切到进度页：剩余工作量趋势应有数据（180+90 = 270 分钟；重复模板
    // 实例另计 30×7，均在窗口内），任务耗时图应有计划段。
    await tapNavDestination(tester, '进度');

    // 空态不再出现。
    expect(find.text('还没有可展示的剩余工作量数据'), findsNothing);
    expect(find.text('还没有带预估时长的任务安排'), findsNothing);
    // 燃尽卡「当前剩余」= 180+90+30×7 = 480 分钟 = 8 小时。
    final burnCard = find.widgetWithText(Card, '剩余工作量趋势');
    expect(
      find.descendant(of: burnCard, matching: find.text('8 小时')),
      findsWidgets,
    );
    // 任务耗时图已渲染堆叠条。
    expect(find.byType(BarChart), findsOneWidget);
  });
}
