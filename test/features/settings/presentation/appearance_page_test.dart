import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/desktop/desktop_providers.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';

/// 外观设置页 Widget 测试（M10 明暗主题）。
///
/// 固定时钟 2026-08-05，验证：
/// - 初始态：默认选中「跟随系统」；
/// - 点击「深色」即写库 + SnackBar，根组件换肤为 dark（无保存按钮）；
/// - 点击「浅色」即写库 + 换肤为 light；
/// - 改回「跟随系统」即写库回 system。
void main() {
  late AppDatabase db;
  late DateTime fixedNow;

  Future<void> pumpPage(WidgetTester tester) async {
    // 设置页菜单较长（关闭行为/同步/自动备份/备份与恢复/已归档/外观/快捷键），
    // 放大视口避免「外观」落在默认 600px 视口外（ListView 惰性构建）。
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
          // widget 测试中桌面能力禁用（不触碰 windowManager/trayManager）。
          desktopControllerProvider.overrideWithValue(null),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
  }

  /// 点击分段按钮（深色/浅色/跟随系统标签在预览卡中重复出现，限定在按钮内）。
  Future<void> tapSegment(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(SegmentedButton<ThemeMode>),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('初始态：默认选中「跟随系统」，无保存按钮', (tester) async {
    await pumpPage(tester);

    expect(find.textContaining('选择应用的明暗主题'), findsOneWidget);
    final segmented = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(segmented.selected, {ThemeMode.system});
    expect(find.text('当前模式：跟随系统'), findsOneWidget);
    // 点击即生效，不再有独立的保存按钮。
    expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
  });

  testWidgets('点击「深色」即切换：写库 + SnackBar + 根组件换肤', (tester) async {
    await pumpPage(tester);
    await tapSegment(tester, '深色');

    expect(find.textContaining('已切换为深色主题'), findsOneWidget);
    final saved = await SettingsRepository(db).get();
    expect(saved.themeMode, 'dark');
    // 根组件 MaterialApp 已切到 dark 主题（不再跟随系统）。
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    // 预览卡同步更新。
    expect(find.text('当前模式：深色'), findsOneWidget);
  });

  testWidgets('点击「浅色」即切换：写库 + 换肤为 light', (tester) async {
    await pumpPage(tester);
    await tapSegment(tester, '浅色');

    expect(find.textContaining('已切换为浅色主题'), findsOneWidget);
    final saved = await SettingsRepository(db).get();
    expect(saved.themeMode, 'light');
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
  });

  testWidgets('改回「跟随系统」即切换：写库回 system', (tester) async {
    // 预置深色选择，进入页面后改回跟随系统。
    await SettingsRepository(db).updateThemeMode('dark');
    await pumpPage(tester);

    expect(find.text('当前模式：深色'), findsOneWidget);
    await tapSegment(tester, '跟随系统');

    expect(find.textContaining('已切换为跟随系统主题'), findsOneWidget);
    final saved = await SettingsRepository(db).get();
    expect(saved.themeMode, 'system');
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
  });
}
