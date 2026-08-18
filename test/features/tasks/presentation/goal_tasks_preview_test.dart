import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

import '../../../shared/nav_helper.dart';

/// 任务区预览限制 + 目标全部任务页 Widget 测试（2026-08-18）。
///
/// 场景：详情页未分类任务超过 8 条时只预览前 8 条 + 「查看全部」入口，
/// 进入全部任务页后按科目分组全量展示、组头可折叠。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
  late TaskRepository tasks;
  late int goalId;

  Future<void> pumpApp(WidgetTester tester) async {
    // 详情页内容长，放大视口避免任务区按钮落在视口外
    // （ListView 惰性构建，视口外 find 不到）。
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => DateTime(2026, 8, 5, 12)),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openGoalDetail(WidgetTester tester) async {
    await pumpApp(tester);
    await tapNavDestination(tester, '目标');
    await tester.tap(find.text('考研数学'));
    await tester.pumpAndSettle();
  }

  Future<void> createTasks(
    int count, {
    int? subjectId,
    String titlePrefix = '任务',
  }) async {
    for (var i = 1; i <= count; i++) {
      final day = i < 10 ? '0$i' : '$i';
      await tasks.create(
        goalId: goalId,
        subjectId: subjectId,
        title: '$titlePrefix $i',
        plannedDate: '2026-08-$day',
      );
    }
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    subjects = SubjectRepository(db);
    tasks = TaskRepository(db);
    goalId = (await goals.create(title: '考研数学', deadlineDate: '2026-12-20')).id;
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('详情页未分类任务超过 8 条：只预览前 8 条 + 查看全部入口', (tester) async {
    await createTasks(12);

    await openGoalDetail(tester);

    // 预览：前 8 条可见，第 9/12 条不出现。
    expect(find.text('任务 1'), findsOneWidget);
    expect(find.text('任务 8'), findsOneWidget);
    expect(find.text('任务 9'), findsNothing);
    expect(find.text('任务 12'), findsNothing);
    // 末尾「查看全部」行展示任务总数。
    expect(find.text('查看全部 12 个任务'), findsOneWidget);

    // 点「查看全部」进入目标全部任务页：全量出现。
    await tester.tap(find.text('查看全部 12 个任务'));
    await tester.pumpAndSettle();

    expect(find.text('全部任务'), findsOneWidget); // AppBar 标题
    expect(find.text('任务 9'), findsOneWidget);
    expect(find.text('任务 12'), findsOneWidget);
  });

  testWidgets('详情页未分类任务 ≤ 8 条：不显示查看全部入口', (tester) async {
    await createTasks(5);

    await openGoalDetail(tester);

    expect(find.text('任务 5'), findsOneWidget);
    expect(find.textContaining('查看全部'), findsNothing);
  });

  testWidgets('全部任务页按科目分组：未分类在前、科目组可折叠、总览统计', (tester) async {
    // 未分类 9 条（>8 触发详情页查看全部入口）+ 高数科目 2 条。
    await createTasks(9);
    final subjectId = (await subjects.create(
      goalId: goalId,
      name: '高数',
      color: '#3F6C51',
    )).id;
    await createTasks(2, subjectId: subjectId, titlePrefix: '高数任务');

    await openGoalDetail(tester);
    await tester.tap(find.text('查看全部 9 个任务'));
    await tester.pumpAndSettle();

    // 总览统计。
    expect(find.textContaining('共 11 个任务'), findsOneWidget);
    // 分组：未分类组在前，科目组可见；两组任务均全量展示。
    // 「高数」出现在组头 + 组内任务行的科目标签上（findsWidgets）。
    expect(find.text('未分类任务'), findsOneWidget);
    expect(find.text('高数'), findsWidgets);
    expect(find.text('任务 9'), findsOneWidget);
    expect(find.text('高数任务 1'), findsOneWidget);
    expect(find.text('高数任务 2'), findsOneWidget);

    // 科目组头可折叠：点击「高数」组头（树序第一个，位于任务行之前）
    // → 该组任务消失，未分类组不受影响；组头仍在。
    await tester.tap(find.text('高数').first);
    await tester.pumpAndSettle();
    expect(find.text('高数任务 1'), findsNothing);
    expect(find.text('高数任务 2'), findsNothing);
    expect(find.text('任务 9'), findsOneWidget);
    expect(find.text('高数'), findsOneWidget); // 只剩组头
  });
}
