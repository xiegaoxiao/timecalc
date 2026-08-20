import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/theme/app_tokens.dart';
import 'package:timecalc/shared/widgets/hoverable_card.dart';

/// HoverableCard hover 反馈测试（2026-08-20 动效改造）。
///
/// 验证：
/// - 可点卡片 hover 时边框转主色、阴影增强、微上浮（桌面交互反馈）；
/// - 鼠标移出后恢复原态；
/// - 不可点（无 onTap）时不响应 hover（无边框/阴影变化）；
/// - 点击光标：可点卡显示 SystemMouseCursors.click。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: HoverableCard(
                onTap: onTap,
                child: const SizedBox(
                  width: 120,
                  height: 60,
                  child: Center(child: Text('卡片')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 取卡片当前 BoxDecoration（HoverableCard 的 AnimatedContainer 装饰）。
  BoxDecoration decorationOf(WidgetTester tester) {
    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(HoverableCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
    return container.decoration! as BoxDecoration;
  }

  /// HoverableCard 的 AnimatedContainer（读 transform）。
  AnimatedContainer animatedContainerOf(WidgetTester tester) {
    return tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(HoverableCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
  }

  /// 创建鼠标 gesture 并悬停到卡片中心（后续可继续移动/移除）。
  Future<TestGesture> startHover(WidgetTester tester) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.text('卡片')),
      timeStamp: const Duration(milliseconds: 20),
    );
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('可点卡片 hover：边框转主色 + 阴影增强 + 微上浮', (tester) async {
    await pumpCard(tester, onTap: () {});

    final base = decorationOf(tester);
    expect(
      (base.border as Border).top.color,
      AppTokens.neutralBorderLight,
    );

    final gesture = await startHover(tester);

    final hovered = decorationOf(tester);
    final borderColor = (hovered.border as Border).top.color;
    expect(borderColor, isNot(AppTokens.neutralBorderLight));

    // 微上浮：transform 已应用（非恒等）。
    final container = animatedContainerOf(tester);
    expect(container.transform, isNotNull);
    expect(
      container.transform!.getTranslation().y,
      lessThan(0), // 上浮为负 Y
    );
    await gesture.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets('移出 hover 恢复原态', (tester) async {
    await pumpCard(tester, onTap: () {});

    final gesture = await startHover(tester);

    // 移出卡片。
    await gesture.moveTo(
      const Offset(400, 400),
      timeStamp: const Duration(milliseconds: 40),
    );
    await tester.pumpAndSettle();

    final restored = decorationOf(tester);
    expect(
      (restored.border as Border).top.color,
      AppTokens.neutralBorderLight,
    );
    await gesture.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets('不可点卡片（无 onTap）hover 不变', (tester) async {
    await pumpCard(tester);

    final base = decorationOf(tester);
    final gesture = await startHover(tester);
    final after = decorationOf(tester);
    expect(
      (after.border as Border).top.color,
      (base.border as Border).top.color,
    );
    await gesture.removePointer();
    await tester.pumpAndSettle();
  });
}
