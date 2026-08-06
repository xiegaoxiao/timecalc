import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/milestone_repository.dart';

/// 今天页最近里程碑 Widget 测试（FR-2.3）。
///
/// 内存数据库 + 固定时钟（2026-08-05）。首页（今天页）每个目标卡片仅
/// 展示距离最近的一个未完成里程碑；无里程碑时不显示该行。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late MilestoneRepository milestones;
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
    milestones = MilestoneRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('首页目标卡片展示最近的未完成里程碑（FR-2.3）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    // 两个未完成里程碑：较晚（2026-11-01）与最近（2026-09-15）。
    await milestones.create(
      goalId: 1,
      title: '较晚节点',
      date: '2026-11-01',
    );
    await milestones.create(
      goalId: 1,
      title: '最近节点',
      date: '2026-09-15',
    );

    await pumpApp(tester);

    expect(find.text('考研'), findsOneWidget);
    expect(find.textContaining('下一里程碑：最近节点 · 2026-09-15'), findsOneWidget);
    expect(find.textContaining('较晚节点'), findsNothing);
  });

  testWidgets('无里程碑时目标卡片不显示里程碑行（FR-2.3）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');

    await pumpApp(tester);

    expect(find.text('考研'), findsOneWidget);
    expect(find.textContaining('下一里程碑'), findsNothing);
  });

  testWidgets('里程碑全部完成后首页不再展示（FR-2.3）', (tester) async {
    await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final m = await milestones.create(
      goalId: 1,
      title: '已完成节点',
      date: '2026-09-15',
    );
    await milestones.update(id: m.id, done: true);

    await pumpApp(tester);

    expect(find.text('考研'), findsOneWidget);
    expect(find.textContaining('下一里程碑'), findsNothing);
  });
}
