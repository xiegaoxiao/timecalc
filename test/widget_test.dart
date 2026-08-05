// TimeCalc 应用骨架冒烟测试。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:timecalc/app.dart';

void main() {
  testWidgets('应用启动并展示主导航（骨架冒烟）', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: TimeCalcApp()));
    await tester.pumpAndSettle();

    // 四个一级导航入口均存在（PRD §7）。
    expect(find.text('今天'), findsWidgets);
    expect(find.text('计划'), findsWidgets);
    expect(find.text('进度'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });
}
