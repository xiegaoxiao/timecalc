import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 无障碍 Widget 测试（NFR-4 / checklists §8）。
///
/// - 日历「超出」格：红色文本外附警告图标（状态不只依赖颜色）；
/// - 日历格 Semantics 标签（屏幕阅读器可读：日期/完成/时长/超出）；
/// - 热力图色块 Semantics 标签（日期 + 完成项数）；
/// - 核心流程键盘可达（Tab 可聚焦「添加任务」按钮）。
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
    fixedNow = DateTime(2026, 8, 5, 12); // 周三
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('日历「超出」格附警告图标，不只依赖颜色（NFR-4）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 今日 150 分钟 > 默认可用 120 分钟 → 超出 30 分钟。
    await tasks.create(goalId: goal.id, title: 'A', plannedDate: '2026-08-05', estimatedMinutes: 90);
    await tasks.create(goalId: goal.id, title: 'B', plannedDate: '2026-08-05', estimatedMinutes: 60);

    await pumpApp(tester);
    // v1.12 起计划页即纯日历，直接进入计划页即可见月历。
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();

    // 超出格同时有红色文本与警告图标（非颜色提示）。
    expect(find.text('超出30m'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
  });

  testWidgets('日历格提供屏幕阅读器可读的 Semantics 标签（NFR-4）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(goalId: goal.id, title: 'A', plannedDate: '2026-08-05', estimatedMinutes: 90);

    await pumpApp(tester);
    final semantics = tester.ensureSemantics();
    // v1.12 起计划页即纯日历，直接进入计划页即可见月历。
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();

    // 2026-08-05：完成 0/1，时长 1h30m（无超出）。
    // Semantics 标签可能与 InkWell 节点合并，用 RegExp 匹配包含关系。
    expect(
      find.bySemanticsLabel(RegExp('2026-08-05，完成 0/1')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('热力图色块提供日期与完成数的 Semantics 标签（NFR-4）', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 今日（本地 2026-08-05）完成一项。
    await db.into(db.tasks).insert(TasksCompanion.insert(
          goalId: goal.id,
          title: '已完成',
          plannedDate: '2026-08-05',
          estimatedMinutes: const Value(30),
          status: const Value('done'),
          completedAt: Value(fixedNow.toUtc()),
          createdAt: fixedNow.toUtc(),
          updatedAt: fixedNow.toUtc(),
        ));

    await pumpApp(tester);
    final semantics = tester.ensureSemantics();
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('2026-08-05：完成 1 项'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('核心流程键盘可达：Tab 可达「添加任务」按钮（NFR-4）', (tester) async {
    // 需要至少一个目标，今天页空态才显示「添加任务」按钮。
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);

    final addButton = find.widgetWithText(FilledButton, '添加任务');
    expect(addButton, findsOneWidget);
    final buttonElement = tester.element(addButton);

    // 从初始焦点连续 Tab，直到焦点落在「添加任务」按钮内部（NFR-4 键盘操作）。
    var reached = false;
    for (var i = 0; i < 25 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      reached = _isWithin(focusedContext, buttonElement);
    }
    expect(reached, isTrue, reason: 'Tab 应可达「添加任务」按钮（NFR-4 键盘操作）');
  });
}

/// [descendant] 是否位于 [ancestor] 的 Element 祖先链中（含自身）。
bool _isWithin(BuildContext? descendant, BuildContext ancestor) {
  if (descendant == null) return false;
  if (identical(descendant, ancestor)) return true;
  var within = false;
  (descendant as Element).visitAncestorElements((element) {
    if (identical(element, ancestor)) {
      within = true;
      return false; // 停止向上遍历
    }
    return true;
  });
  return within;
}
