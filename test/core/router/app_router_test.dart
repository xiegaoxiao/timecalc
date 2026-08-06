// 路由参数防护回归测试（P2-8）。
//
// 畸形路由参数（非数字 goalId/subjectId，如外部深链拼写错误）必须被
// redirect 到首页，而不是在 build 途中抛 FormatException 红屏。
// 注意：redirect 由挂载后的 GoRouterDelegate 驱动，因此测试必须把
// MaterialApp（TimeCalcApp）挂载到 widget tree 中，而非仅读 router。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/router/app_router.dart';

Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const TimeCalcApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('畸形 goalId 参数被重定向到首页（P2-8 回归）', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    final router = container.read(appRouterProvider);

    router.go('/goals/not-a-number');
    await tester.pumpAndSettle();

    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.path, '/today');
    // 首页主导航仍在（未被详情页替换）。
    expect(find.text('今天'), findsWidgets);
  });

  testWidgets('畸形 subjectId 参数被重定向到首页（P2-8 回归）', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    final router = container.read(appRouterProvider);

    router.go('/goals/1/subjects/xyz');
    await tester.pumpAndSettle();

    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.path, '/today');
    expect(find.text('今天'), findsWidgets);
  });

  testWidgets('合法参数正常导航到目标详情（P2-8 无回归）', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    final router = container.read(appRouterProvider);

    // 不存在的目标 id 也应正常进入详情页（显示「目标不存在」），不被误重定向。
    router.go('/goals/42');
    await tester.pumpAndSettle();

    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.path, '/goals/42');
    expect(find.text('目标不存在'), findsOneWidget);
  });
}
