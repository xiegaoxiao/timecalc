import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/presentation/goal_list_page.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

import '../../../shared/nav_helper.dart';

/// 目标页 Dashboard 卡片布局 Widget 测试（v1.13 + 信息层级重构）。
///
/// 固定时钟 2026-08-05。验证：
/// - 区块头「我的目标 / 新建目标」+ 顶部统计胶囊（进行中/已完成/全部）；
/// - 单目标通栏大卡（占满内容宽度，消除孤卡小角）；
/// - 大号完成度 %、彩色进度条、统计块（已完成 x/y / 学习时长 / 剩余时间）；
/// - 无任务时 `0%` 与 `--` 占位（区分「没计划」与「0 完成」）；
/// - 多目标双列网格。
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

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  /// 目标页中唯一的目标卡片（懒加载行列表内的 Card；以 GoalListBody 为界，
  /// 避免 IndexedStack 常驻的其他页（今日页等）含 Card 干扰定位）。
  Finder goalCardFinder() => find.descendant(
    of: find.byType(GoalListBody),
    matching: find.byType(Card),
  );

  testWidgets('目标页区块头：我的目标标题 + 新建目标入口（Dashboard 语言）', (tester) async {
    await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
    await pumpApp(tester);

    await tapNavDestination(tester, '目标');

    expect(find.text('我的目标'), findsOneWidget);
    // 新建目标按钮（取代 FAB）。
    expect(find.widgetWithText(FilledButton, '新建目标'), findsOneWidget);
    // tooltip 语义保留（兼容无障碍与旧测试定位）。
    expect(find.byTooltip('创建目标'), findsOneWidget);
  });

  testWidgets('单目标：通栏大卡占满内容宽度，展示进度/统计/查看详情', (tester) async {
    final goal = await goals.create(
      title: '考研数学',
      description: '零基础冲 140+',
      deadlineDate: '2026-12-20',
    );
    // 2 个任务各 60 分钟，1 个完成 → 50%、已完成 1 小时、剩余 1 小时。
    final a = await tasks.create(
      goalId: goal.id,
      title: '高数第 1 章',
      plannedDate: '2026-08-05',
      estimatedMinutes: 60,
    );
    await tasks.create(
      goalId: goal.id,
      title: '高数第 2 章',
      plannedDate: '2026-08-06',
      estimatedMinutes: 60,
    );
    await tasks.setDone(a.id, true);

    await pumpApp(tester);
    await tapNavDestination(tester, '目标');

    // 通栏：单目标卡片宽度应接近内容区宽度（约 690，双列时仅约 338）。
    final cardSize = tester.getSize(goalCardFinder());
    expect(cardSize.width, greaterThan(500));

    // 大号完成度数字（视觉焦点）+ 进度条。
    expect(find.text('50%'), findsOneWidget);
    expect(
      find.descendant(
        of: goalCardFinder(),
        matching: find.byType(LinearProgressIndicator),
      ),
      findsOneWidget,
    );
    // 描述刻意不在卡片展示（信息密度优先，详情页可见）——目标带描述时
    // 卡片上也不应出现描述文本。
    expect(find.text('零基础冲 140+'), findsNothing);

    // 统计块（标题 + 数值结构）：已完成 / 学习时长 / 剩余时间。
    // 「已完成」出现两处：顶部统计胶囊标签 + 卡片统计块标题。
    expect(find.text('已完成'), findsNWidgets(2));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('学习时长'), findsOneWidget);
    expect(find.text('剩余时间'), findsOneWidget);
    // 学习时长与剩余时间均为 1 小时（2 任务各 60 分钟，1 个完成）。
    expect(find.text('1 小时'), findsNWidgets(2));

    // 截止区间（创建日 → 截止日）+ 倒计时徽标。
    expect(find.textContaining('→ 2026.12.20'), findsOneWidget);
    expect(find.text('剩余 137 天'), findsOneWidget);

    // 「查看详情 →」主操作。
    expect(find.text('查看详情 →'), findsOneWidget);

    // 顶部统计胶囊：进行中 1 / 已完成 0 / 全部 1。
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('无任务目标：0% 灰色占位与统计行 -- 占位（区分「没计划」）', (tester) async {
    await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
    await pumpApp(tester);

    await tapNavDestination(tester, '目标');

    // 无任务：完成度 0% 灰色占位，统计块用 `--`（同今日页口径）。
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('-- / --'), findsOneWidget); // 已完成
    expect(find.text('--'), findsNWidgets(2)); // 学习时长 / 剩余时间
  });

  testWidgets('多目标：自适应双列网格（左右各一卡）', (tester) async {
    // 宽桌面视口（1400px 内容区）下才出现双列；默认 800 视口只够单列。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await goals.create(title: '考研数学', deadlineDate: '2026-12-20');
    await goals.create(title: 'Java 后端', deadlineDate: '2027-02-01');
    await pumpApp(tester);

    await tapNavDestination(tester, '目标');

    expect(find.text('考研数学'), findsOneWidget);
    expect(find.text('Java 后端'), findsOneWidget);

    // 两个卡片左右分列：中心 x 坐标相差明显（单列通栏时几乎相同）。
    final cards = goalCardFinder();
    expect(cards, findsNWidgets(2));
    final firstX = tester.getCenter(cards.at(0)).dx;
    final secondX = tester.getCenter(cards.at(1)).dx;
    expect((firstX - secondX).abs(), greaterThan(200));
  });

  testWidgets('系统放大字号（textScaler 2.0）：卡片按内容自适应高度，不溢出（回归）', (tester) async {
    // review 反馈：旧固定 mainAxisExtent 268 在系统放大字号/标题两行时
    // RenderFlex overflow（旧 ListTile 自适应，固定高度是回归）。
    // 现在卡片随内容自然增高，放大字号下不得再抛布局溢出。
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await goals.create(
      title: '考研数学 2027 全程规划（含强化与冲刺阶段）',
      deadlineDate: '2026-12-20',
    );
    await pumpApp(tester);
    await tapNavDestination(tester, '目标');

    // 布局阶段不应有异常（RenderFlex overflow 会经 FlutterError 上报）。
    expect(tester.takeException(), isNull);
    expect(find.text('考研数学 2027 全程规划（含强化与冲刺阶段）'), findsOneWidget);
    // 卡片仍通栏渲染且内容可见（「查看详情」未被挤出视口外不可见）。
    expect(find.text('查看详情 →'), findsOneWidget);
  });
}
