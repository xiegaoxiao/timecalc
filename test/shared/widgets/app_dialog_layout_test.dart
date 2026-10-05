import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timecalc/core/theme/app_theme.dart';
import 'package:timecalc/shared/widgets/app_dialog.dart';
import 'package:timecalc/shared/widgets/app_form_field.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'dialog scrolls with visible actions in small window, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(360, 420);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var saved = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 420),
                textScaler: TextScaler.linear(1.5),
              ),
              child: Scaffold(
                body: AppDialog(
                  title: '添加任务',
                  titleIcon: Icons.bolt_outlined,
                  content: Column(
                    children: List.generate(
                      12,
                      (index) => Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: AppFormField(label: '字段 $index', hint: '请输入'),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('取消操作')),
                    FilledButton(
                      onPressed: () => saved = true,
                      child: const Text('保存此项任务'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('保存此项任务').hitTestable(), findsOneWidget);
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -900),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('保存此项任务'));
        expect(saved, isTrue);
      },
    );
  }

  testWidgets(
    'empty pickers expose hints and disabled picker cannot activate',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                AppDateField(
                  label: '日期',
                  value: null,
                  enabled: false,
                  onTap: () => taps++,
                ),
                AppTimeField(label: '时刻', value: null, onTap: () => taps++),
              ],
            ),
          ),
        ),
      );
      expect(find.text('请选择日期'), findsOneWidget);
      expect(find.text('未设置（只排到天）'), findsOneWidget);
      await tester.tap(find.text('请选择日期'));
      expect(taps, 0);
      await tester.tap(find.text('未设置（只排到天）'));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
