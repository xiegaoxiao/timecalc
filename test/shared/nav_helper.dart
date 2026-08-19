import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 点击主导航目的地（宽窗 NavigationRail / 自定义桌面侧栏 / 窄窗
/// NavigationBar 通用）。
///
/// 背景：测试默认视口 800×600 逻辑宽 ≥ [kDesktopNavigationBreakpoint] 会走
/// 桌面分支（原 NavigationRail，v1.17 起为自定义侧栏 `desktop-sidebar`），
/// 旧式 `find.descendant(of: NavigationBar, ...)` 会定位失败；同时进度页
/// 燃尽图 X 轴也标注「今天」，裸 `find.text` 有歧义，必须限定在导航组件内。
/// 此辅助按当前布局分支自动选择作用域。
Future<void> tapNavDestination(
  WidgetTester tester,
  String label,
) async {
  final rail = find.byType(NavigationRail);
  if (rail.evaluate().isNotEmpty) {
    await tester.tap(
      find.descendant(of: rail, matching: find.text(label)),
    );
    await tester.pumpAndSettle();
    return;
  }
  final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
  if (sidebar.evaluate().isNotEmpty) {
    await tester.tap(
      find.descendant(of: sidebar, matching: find.text(label)),
    );
    await tester.pumpAndSettle();
    return;
  }
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}
