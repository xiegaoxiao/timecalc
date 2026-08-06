import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/shared/widgets/duration_step_input.dart';

/// DurationStepInput 长按步进行为测试（P0-1 回归）。
///
/// 长按 500ms（kLongPressTimeout）触发 onLongPressStart → 立即步进一次并
/// 启动 400ms 一次性 Timer，之后每 100ms 周期步进；松开（onLongPressEnd）
/// 必须停止全部步进。此前一次性 Timer 未跟踪，短长按（不足 400ms 松开）
/// 后周期性步进仍会启动，数值一直自动变化。
void main() {
  Future<Widget> build({
    required int initial,
    required ValueChanged<int?> onChanged,
  }) async {
    return MaterialApp(
      home: Scaffold(
        body: DurationStepInput(
          label: '时长',
          value: initial,
          onChanged: onChanged,
          hourFieldKey: const Key('hourField'),
          minuteFieldKey: const Key('minuteField'),
        ),
      ),
    );
  }

  testWidgets('长按保持时连续步进，松开后停止', (tester) async {
    final values = <int?>[];
    await tester.pumpWidget(
      await build(initial: 0, onChanged: values.add),
    );

    final addButton = find.byTooltip('小时加');
    expect(addButton, findsOneWidget);
    final center = tester.getCenter(addButton);

    final gesture = await tester.startGesture(center);
    // 超过 kLongPressTimeout（500ms）：onLongPressStart 触发，立即步进一次。
    await tester.pump(const Duration(milliseconds: 600));
    final afterHold = values.last!;
    expect(afterHold, greaterThan(0));

    // 一次性 Timer（400ms）已过，进入周期步进（每 100ms 一次）。
    await tester.pump(const Duration(milliseconds: 600));
    expect(values.last!, greaterThan(afterHold));

    final beforeUp = values.last!;
    await gesture.up(); // onLongPressEnd → 停止全部步进
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(values.last!, beforeUp);
  });

  testWidgets('短长按（不足 400ms）松开后不再自动步进（P0-1 回归）', (tester) async {
    final values = <int?>[];
    await tester.pumpWidget(
      await build(initial: 0, onChanged: values.add),
    );

    final addButton = find.byTooltip('小时加');
    final center = tester.getCenter(addButton);

    final gesture = await tester.startGesture(center);
    // 按住已触发 onLongPressStart（>500ms），但一次性 Timer（+400ms）未到。
    await tester.pump(const Duration(milliseconds: 520));
    final valueAtRelease = values.last!;
    expect(valueAtRelease, greaterThan(0));

    await gesture.up(); // onLongPressEnd → 应取消一次性 Timer

    // 修复前：一次性 Timer 未被取消，400ms 后启动周期步进，数值持续变化；
    // 修复后：一次性 Timer 被取消，数值保持不变。
    await tester.pump(const Duration(milliseconds: 500));
    expect(values.last!, valueAtRelease);
    await tester.pump(const Duration(milliseconds: 500));
    expect(values.last!, valueAtRelease);
  });
}
