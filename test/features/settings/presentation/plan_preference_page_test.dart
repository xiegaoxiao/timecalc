import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';

/// 计划偏好独立页测试（进度页入口卡 push 进入）。
///
/// 验证：修改每日可用时长 / 每周可用日保存后写库，SnackBar 提示。
void main() {
  late AppDatabase db;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 进度页入口卡 → 独立偏好页。
  Future<void> openPreference(WidgetTester tester) async {
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('计划偏好'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('修改每日可用时长并保存：写库 + SnackBar（PRD §5.1）', (tester) async {
    await pumpApp(tester);
    await openPreference(tester);

    // 默认 2 小时 → 小时加 1 → 3 小时。
    await tester.tap(find.byTooltip('小时加'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 3 小时'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('计划偏好已保存'), findsOneWidget);

    final settings = await db.select(db.settings).getSingle();
    expect(settings.dailyAvailableMinutes, 180);
    expect(settings.availableWeekdays, '1,2,3,4,5,6,7');
  });

  testWidgets('修改每周可用日并保存：写库生效', (tester) async {
    await pumpApp(tester);
    await openPreference(tester);

    // 取消「周二」（默认全部选中）。
    await tester.tap(find.text('周二'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('计划偏好已保存'), findsOneWidget);

    final settings = await db.select(db.settings).getSingle();
    expect(settings.availableWeekdays, '1,3,4,5,6,7');
  });

  testWidgets('每日可用时长设为 0 时保存被阻止', (tester) async {
    await pumpApp(tester);
    await openPreference(tester);

    // 小时减两次 → 0 分。
    await tester.tap(find.byTooltip('小时减'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('小时减'));
    await tester.pumpAndSettle();
    expect(find.text('当前共 0 分'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('每日可用时长至少 1 分钟'), findsOneWidget);
    expect(find.text('计划偏好已保存'), findsNothing);

    final settings = await db.select(db.settings).getSingle();
    expect(settings.dailyAvailableMinutes, 120);
  });

  testWidgets('每周可用日全取消时保存被阻止（M5：口径矛盾修复）', (tester) async {
    await pumpApp(tester);
    await openPreference(tester);

    // 点「全部取消」清空可用日（此前允许保存，导致日历全灰但负载按
    // 全可用计算的自相矛盾）。
    await tester.tap(find.text('全部取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('每周至少选择一个可用日'), findsOneWidget);
    expect(find.text('计划偏好已保存'), findsNothing);

    // 库内保持默认全选，未被空集合覆盖。
    final settings = await db.select(db.settings).getSingle();
    expect(settings.availableWeekdays, '1,2,3,4,5,6,7');
  });
}
