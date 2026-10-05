import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timecalc/core/theme/app_theme.dart';
import 'package:timecalc/shared/widgets/app_time_picker.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    ValueChanged<TimeOfDay?> onResult, {
    bool dark = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await showAppTimePicker(
                  context: context,
                  initialTime: const TimeOfDay(hour: 10, minute: 7),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('validates range, then submits exact time with keyboard', (
    tester,
  ) async {
    TimeOfDay? result;
    await open(tester, (value) => result = value);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '24');
    await tester.enterText(fields.last, '60');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 00–23'), findsOneWidget);
    expect(find.text('请输入 00–59'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(fields.first, '23');
    await tester.enterText(fields.last, '59');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 23, minute: 59));
  });

  testWidgets('minute shortcut preserves hour; cancel returns null', (
    tester,
  ) async {
    TimeOfDay? result;
    await open(tester, (value) => result = value);
    await tester.tap(find.text('30 分'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 10, minute: 30));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('small window and enlarged text, dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, (_) {}, dark: dark);
      expect(tester.takeException(), isNull);
      expect(find.text('确定').hitTestable(), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
