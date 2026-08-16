import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/desktop/desktop_providers.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/core/theme/accent_palette.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';

/// 外观设置页 Widget 测试（M10 明暗主题 + 2026-08-16 主题色系）。
///
/// 固定时钟 2026-08-05，验证：
/// - 初始态：默认选中「跟随系统」+ 绿色色系；
/// - 点击「深色」即写库 + SnackBar，根组件换肤为 dark（无保存按钮）；
/// - 点击「浅色」即写库 + 换肤为 light；
/// - 改回「跟随系统」即写库回 system；
/// - 点击「蓝色」即写库 + 根组件色系切换（MaterialApp.theme 的
///   AccentPalette 变为 blue）+ SnackBar + 预览同步；改回「绿色」恢复。
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

  /// 点击明暗分段按钮（深色/浅色/跟随系统标签在预览卡中重复出现，限定在按钮内）。
  Future<void> tapSegment(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(SegmentedButton<ThemeMode>),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  /// 点击色系分段按钮（绿色/蓝色标签限定在色系按钮内）。
  Future<void> tapAccentSegment(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(SegmentedButton<AccentPalette>),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  /// 根组件 MaterialApp 当前生效的色系。
  AccentPalette appAccent(WidgetTester tester) {
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    return app.theme!.extension<AccentPalette>()!;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('初始态：默认选中「跟随系统」与绿色色系，无保存按钮', (tester) async {
    await pumpPage(tester);

    expect(find.textContaining('选择应用的明暗主题'), findsOneWidget);
    final segmented = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(segmented.selected, {ThemeMode.system});
    final accentSegmented = tester.widget<SegmentedButton<AccentPalette>>(
      find.byType(SegmentedButton<AccentPalette>),
    );
    expect(accentSegmented.selected, {greenAccent});
    expect(find.textContaining('当前模式：跟随系统'), findsOneWidget);
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
    expect(find.textContaining('当前模式：深色'), findsOneWidget);
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

    expect(find.textContaining('当前模式：深色'), findsOneWidget);
    await tapSegment(tester, '跟随系统');

    expect(find.textContaining('已切换为跟随系统主题'), findsOneWidget);
    final saved = await SettingsRepository(db).get();
    expect(saved.themeMode, 'system');
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
  });

  testWidgets('点击「蓝色」即切换色系：写库 + 根组件换肤 + SnackBar', (tester) async {
    await pumpPage(tester);
    await tapAccentSegment(tester, '蓝色');

    expect(find.textContaining('已切换为蓝色主题'), findsOneWidget);
    final saved = await SettingsRepository(db).get();
    expect(saved.accentColor, 'blue');
    // 根组件色系已切换（theme 里注册的 AccentPalette 变为 blue）。
    expect(appAccent(tester).id, 'blue');
    // 预览卡同步更新（文案为「当前模式：跟随系统 · 蓝色色系」）。
    expect(find.textContaining('当前模式：跟随系统 · 蓝色色系'), findsOneWidget);
  });

  testWidgets('色系选择持久化：预置蓝色进入页面选中、改回绿色恢复', (tester) async {
    await SettingsRepository(db).updateAccentColor('blue');
    await pumpPage(tester);

    final accentSegmented = tester.widget<SegmentedButton<AccentPalette>>(
      find.byType(SegmentedButton<AccentPalette>),
    );
    expect(accentSegmented.selected, {blueAccent});

    await tapAccentSegment(tester, '绿色');
    expect(find.textContaining('已切换为绿色主题'), findsOneWidget);
    expect((await SettingsRepository(db).get()).accentColor, 'green');
    expect(appAccent(tester).id, 'green');
  });
}
