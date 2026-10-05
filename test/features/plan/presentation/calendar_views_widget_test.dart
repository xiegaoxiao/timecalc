import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

import 'package:timecalc/shared/widgets/clash_tones.dart';
import 'package:timecalc/shared/widgets/completion_checkbox.dart';

import '../../../shared/nav_helper.dart';

/// 计划页双视图（周/月）Widget 测试。
///
/// 固定时钟 2026-08-05（周三，处于 2026-08-03~08-09 那一周）。
/// 验证：
/// - 视图切换器存在（周/月两段）且默认月视图；
/// - 周视图：显示当周 7 天、跨月周正确（2026-08 月首 8/1 是周六）；
/// - 「回到今天」从任意视图回当前单元。
///
/// 年视图已于 2026-10 删除（与进度页热力图语义重复），用例同步移除。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCalendar(WidgetTester tester) async {
    await tapNavDestination(tester, '计划');
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('视图切换器存在且默认月视图', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await pumpApp(tester);
    await openCalendar(tester);

    // 两段切换器。
    expect(find.text('周'), findsOneWidget);
    expect(find.text('月'), findsOneWidget);
    // 默认月视图标题。
    expect(find.text('2026年8月'), findsOneWidget);
  });

  testWidgets('周视图：显示当周 7 天与负载聚合，跨月周正常', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 当周（8/3 周一 ~ 8/9 周日）任务：周一 2 个（1 完成）、周三 1 个。
    await tasks.create(
      goalId: goal.id,
      title: '周一周一',
      plannedDate: '2026-08-03',
      estimatedMinutes: 60,
    );
    final done1 = await tasks.create(
      goalId: goal.id,
      title: '周一完成',
      plannedDate: '2026-08-03',
      estimatedMinutes: 30,
    );
    await tasks.setDone(done1.id, true);
    await tasks.create(
      goalId: goal.id,
      title: '周三任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );
    // 下周任务（不应出现在本周）。
    await tasks.create(
      goalId: goal.id,
      title: '下周任务',
      plannedDate: '2026-08-10',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 切到周视图。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();

    // 标题：本周 8/3~8/9（新格式：8月3日 – 9日 · 第 32 周）。
    expect(find.textContaining('8月3日'), findsOneWidget);
    expect(find.textContaining('第'), findsOneWidget);

    // 7 天都在（日期号）。
    for (final day in ['3', '4', '5', '6', '7', '8', '9']) {
      expect(find.text(day), findsWidgets);
    }
    // 周一的负载聚合（2/2 完成 1 + 时长 1h30）。
    expect(find.text('1/2'), findsOneWidget);
    // 下周任务不出现。
    expect(find.text('下周任务'), findsNothing);
  });

  testWidgets('周视图选中格任务条可读：撞色序列着色胶囊，不再随格子前景色（回归 2026-08-16）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 今天（8/5 周三，默认选中）放 4 个任务：3 条进胶囊预览 + 1 条溢出。
    for (final title in ['高数练习', '英语阅读', '政治刷题', '专业课复习']) {
      await tasks.create(
        goalId: goal.id,
        title: title,
        plannedDate: '2026-08-05',
        estimatedMinutes: 30,
      );
    }
    // 非选中日（8/4 周二）放 1 个任务：普通胶囊变体。
    await tasks.create(
      goalId: goal.id,
      title: '昨日回顾',
      plannedDate: '2026-08-04',
      estimatedMinutes: 30,
    );

    await pumpApp(tester);
    await openCalendar(tester);
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();

    // 主题取自视图切换器（标题在周格胶囊与选日面板各出现一次，不能作锚点）。
    final context = tester.element(find.text('月'));
    final scheme = Theme.of(context).colorScheme;
    // 事件块按**目标 id** 稳定映射到撞色序列（暖/冷/点缀）：
    // 胶囊底色＝序列色 8% 半透明底压在不透明卡片底上，文字/图标＝序列色。
    final series = ClashTones.chartSeries(context);
    final accent = series[goal.id % series.length];
    final pillColor = Color.alphaBlend(
      ClashTones.tint(accent, alpha: 0.08),
      scheme.surfaceContainerLowest,
    );

    // 选中格（今天 8/5）胶囊文字（fontSize 10，区别于选日面板的完整
    // TaskTile）＝撞色序列色；此前是「onPrimary 覆盖层 + onPrimary 文字」，
    // 选中格改为冷藏青浅容器后那种写法会变成浅底白字，完全不可读。
    final selectedTitle = tester
        .widgetList<Text>(find.text('高数练习'))
        .firstWhere((t) => t.style?.fontSize == 10);
    expect(selectedTitle.style?.color, accent);

    final pill = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('高数练习'),
            matching: find.byType(Container),
          ),
        )
        .firstWhere((c) => c.constraints?.maxHeight == 16);
    expect((pill.decoration as BoxDecoration).color, pillColor);

    // 溢出文案走中性次级文字（冷浅底与白卡底上都可读）。
    expect(
      tester.widget<Text>(find.text('+1 项')).style?.color,
      scheme.onSurfaceVariant,
    );

    // 非选中格同样是撞色序列色（不再继承格子前景色）。
    final unselectedTitle = tester
        .widgetList<Text>(find.text('昨日回顾'))
        .firstWhere((t) => t.style?.fontSize == 10);
    expect(unselectedTitle.style?.color, accent);

    // 今天 vs 选中必须一眼可分（默认二者重合）：冷浅底 + 暖粗描边。
    final cool = ClashTones.of(context, ClashTone.cool);
    final warm = ClashTones.of(context, ClashTone.warm);
    BoxDecoration cellDecoration(String day) {
      final container = tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text(day).first,
              matching: find.byType(Container),
            ),
          )
          .firstWhere((c) => (c.decoration as BoxDecoration?)?.border != null);
      return container.decoration as BoxDecoration;
    }

    final todaySelected = cellDecoration('5');
    expect(todaySelected.color, cool.soft, reason: '选中日期格＝冷藏青浅容器');
    expect(
      (todaySelected.border as Border).top.color,
      warm.ink,
      reason: '今天＝暖色粗描边',
    );
    expect((todaySelected.border as Border).top.width, 2);

    // 换选到非今天的 8/4：选中态为冷描边，8/5 回落为「只是今天」（暖底）。
    await tester.tap(find.text('4').first);
    await tester.pumpAndSettle();
    final day4Selected = cellDecoration('4');
    expect(day4Selected.color, cool.soft);
    expect((day4Selected.border as Border).top.color, cool.ink);
    expect((day4Selected.border as Border).top.width, 1.5);

    final todayOnly = cellDecoration('5');
    expect(todayOnly.color, warm.soft, reason: '未选中的今天＝暖色浅容器');
    expect((todayOnly.border as Border).top.color, warm.ink);
  });

  testWidgets('周视图勾选任务后即时刷新（回归：invalidatePlanData 补上 tasksByWeek）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '周三任务',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );

    await pumpApp(tester);
    await openCalendar(tester);

    // 切到周视图（8/3~8/9）。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    // 选中周三 8/5：任务出现在周格任务条预览 + 选日面板（两处）。
    await tester.tap(find.text('5').first);
    await tester.pumpAndSettle();
    expect(find.text('周三任务'), findsWidgets);

    // 勾选前：8/5 周格聚合 0/1。
    expect(find.text('0/1'), findsOneWidget);

    // 勾选完成。
    await tester.tap(find.byType(CompletionCheckbox).first);
    await tester.pumpAndSettle();

    // 勾选后：8/5 周格聚合即时更新为 1/1。
    // （此前 tasksByWeekProvider 未纳入失效清单，周视图在勾选后保持陈旧，
    //   2026-08-15 审查 #4；invalidatePlanData 补上后此回归通过。）
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('0/1'), findsNothing);
  });

  testWidgets('「回到今天」从周视图回当前周', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await pumpApp(tester);
    await openCalendar(tester);

    // 周视图切到上一周，出现「回到今天」，点击回本周。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一单元'));
    await tester.pumpAndSettle();
    expect(find.text('回到今天'), findsOneWidget);
    await tester.tap(find.text('回到今天'));
    await tester.pumpAndSettle();
    expect(find.textContaining('8月3日'), findsOneWidget);
    expect(find.textContaining('第'), findsOneWidget);
  });
}
