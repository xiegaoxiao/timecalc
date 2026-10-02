import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/core/theme/app_theme.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/plan/presentation/calendar_view.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

void main() {
  late AppDatabase db;

  setUpAll(() => initializeDateFormatting('zh_CN'));
  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
  });
  tearDown(() async {
    await db.close();
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets(
      'calendar keeps all day metadata inside aligned cells at $scale× text scale',
      (tester) async {
        final goal = await GoalRepository(
          db,
        ).create(title: '学习', deadlineDate: '2026-12-31');
        await TaskRepository(db).create(
          goalId: goal.id,
          title: '过载日任务',
          plannedDate: '2026-08-05',
          estimatedMinutes: 150,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              // Select an empty day so this test isolates the calendar grid.
              clockProvider.overrideWithValue(() => DateTime(2026, 8, 6)),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const Scaffold(body: CalendarView()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final cell = find
            .ancestor(of: find.text('5'), matching: find.byType(Container))
            .first;
        final cellRect = tester.getRect(cell);
        expect(cellRect.height, greaterThanOrEqualTo(80));
        for (final label in ['5', '0/1', '150分', '超出30']) {
          final text = find.text(label);
          expect(text, findsOneWidget);
          final textRect = tester.getRect(text);
          expect(cellRect.contains(textRect.topLeft), isTrue);
          expect(cellRect.contains(textRect.bottomRight), isTrue);
        }

        // Empty cells in the same week stretch to the populated cell's height.
        final neighborRect = tester.getRect(
          find
              .ancestor(of: find.text('3'), matching: find.byType(Container))
              .first,
        );
        expect(neighborRect.top, cellRect.top);
        expect(neighborRect.bottom, cellRect.bottom);
        final dayContext = tester.element(find.text('5'));
        expect(MediaQuery.textScalerOf(dayContext).scale(11), 11 * scale);
      },
    );
  }
}
