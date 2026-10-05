import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/core/theme/app_theme.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/plan/presentation/calendar_view.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'desktop calendar previews tasks and selects detail, dark=$dark',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final goal = await GoalRepository(
          db,
        ).create(title: '28考研数学全程计划（零基础冲140+）', deadlineDate: '2027-12-25');
        final repo = TaskRepository(db);
        for (var day = 15; day <= 30; day++) {
          for (var i = 0; i < 3; i++) {
            await repo.create(
              goalId: goal.id,
              title: ['高等数学 · 第七讲错题复盘', '英语阅读与长难句练习', '每日回顾：整理导图和公式'][i],
              plannedDate: '2026-09-$day',
              estimatedMinutes: [90, 30, 20][i],
              startTime: ['09:00', '14:00', '20:00'][i],
            );
          }
        }
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              clockProvider.overrideWithValue(() => DateTime(2026, 9, 19)),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: RepaintBoundary(
                key: boundary,
                child: const Scaffold(body: CalendarView()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('calendar-detail-scroll')),
          findsOneWidget,
        );
        expect(find.text('09:00 高等数学 · 第七讲错题复盘'), findsWidgets);
        await tester.tap(find.text('24'));
        await tester.pumpAndSettle();
        expect(find.text('2026-09-24 星期四'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(ActionChip));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(680, 900);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('calendar-detail-scroll')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
