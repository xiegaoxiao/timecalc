import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/shared/widgets/progressive_rows.dart';

/// ProgressiveRows 视口驱动懒构建单测（2026-08-16 v2）。
void main() {
  testWidgets('初始仅构建视口附近的行，滚动到底才构建全部', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 1,
            itemBuilder: (_, _) => ProgressiveRows(
              itemCount: 200,
              itemBuilder: (_, i) => SizedBox(
                key: ValueKey('row$i'),
                height: 50,
                child: Text('row$i'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 视口 400 + 预载 400 ≈ 800px ÷ 50px 行 ≈ 16 行，按 24/批取整为 48
    // （初始 24 + 扩展 24），远小于 200——懒加载语义成立。
    final builtInitially = find.byType(SizedBox).evaluate().length;
    expect(
      builtInitially,
      lessThan(100),
      reason: '未滚动时不应构建全部 200 行（懒加载语义），实际 $builtInitially',
    );
    expect(builtInitially, greaterThan(0));

    // 滚到底：分批补齐，最终全部构建。
    for (var i = 0; i < 60; i++) {
      if (find.byType(SizedBox).evaluate().length >= 200) break;
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
    }
    expect(find.byType(SizedBox).evaluate().length, 200);
  });

  testWidgets('行数不超过初始块时行为与普通列表一致（一次全建，无额外帧）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ProgressiveRows(
                itemCount: 3,
                itemBuilder: (_, i) => Text('row$i'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('row0'), findsOneWidget);
    expect(find.text('row1'), findsOneWidget);
    expect(find.text('row2'), findsOneWidget);
  });

  testWidgets('SingleChildScrollView 场景（RenderSingleChildViewport）同样懒加载',
      (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProgressiveRows(
              itemCount: 200,
              itemBuilder: (_, i) => SizedBox(
                key: ValueKey('row$i'),
                height: 50,
                child: Text('row$i'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 视口 400 + 预载 400 ≈ 800px ÷ 50px 行 ≈ 16 行，按 24/批取整为 48，
    // 远小于 200——SingleChildScrollView 内懒加载语义同样成立。
    final builtInitially = find.byType(SizedBox).evaluate().length;
    expect(
      builtInitially,
      lessThan(100),
      reason:
          '未滚动时不应构建全部 200 行（SingleChildScrollView 懒加载语义），'
          '实际 $builtInitially',
    );
    expect(builtInitially, greaterThan(0));

    // 滚到底：分批补齐，最终全部构建。
    for (var i = 0; i < 60; i++) {
      if (find.byType(SizedBox).evaluate().length >= 200) break;
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
    }
    expect(find.byType(SizedBox).evaluate().length, 200);
  });
}
