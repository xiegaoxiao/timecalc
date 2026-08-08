import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/desktop/desktop_controller.dart';
import 'package:timecalc/core/desktop/desktop_providers.dart';
import 'package:timecalc/core/desktop/window_state_store.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/backup/data/backup_file_picker.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';

/// 设置页 Widget 测试（整宽菜单 + FR-8.1 关闭行为子页 / FR-9 备份入口）。
///
/// 固定时钟 2026-08-05，验证：
/// - 设置页为整宽长条形菜单，六项入口齐全（FR-8.1 / FR-9.1 / 重置数据）
/// - 关闭行为子页：分段选择与保存写库（FR-8.1）
/// - 保存后实时应用到桌面层（FR-8.1 无需重启）
/// - 文件选择器以假实现注入，不触碰平台对话框
void main() {
  late AppDatabase db;
  late DateTime fixedNow;
  late FakeBackupFilePicker picker;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
          backupFilePickerProvider.overrideWithValue(picker),
          // widget 测试中桌面能力禁用（不触碰 windowManager/trayManager）。
          desktopControllerProvider.overrideWithValue(null),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  Future<void> openCloseBehavior(WidgetTester tester) async {
    await openSettings(tester);
    await tester.tap(find.text('关闭行为'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fixedNow = DateTime(2026, 8, 5, 12);
    picker = FakeBackupFilePicker();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('设置页为整宽菜单，六项入口齐全（FR-8.1 / FR-9.1 / 重置数据）', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    expect(find.text('关闭行为'), findsOneWidget);
    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('已归档任务'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('快捷键'), findsOneWidget);
    expect(find.text('重置数据'), findsOneWidget);

    // 菜单页本身不再平铺关闭行为按钮或备份操作按钮（收敛到子页）。
    expect(find.text('导出备份'), findsNothing);
    expect(find.text('从备份恢复'), findsNothing);
    expect(find.text('最小化到托盘'), findsNothing);
  });

  testWidgets('切换关闭行为为「最小化到托盘」即写库（FR-8.1，点击即生效）', (tester) async {
    await pumpApp(tester);
    await openCloseBehavior(tester);

    await tester.tap(find.text('最小化到托盘'));
    await tester.pumpAndSettle();

    // 点击即写库（无保存按钮）。
    expect(find.text('已切换为最小化到托盘'), findsOneWidget);
    final settings = await db.select(db.settings).getSingle();
    expect(settings.closeBehavior, 'minimize_to_tray');
  });

  testWidgets('点击关闭行为分段后实时应用到桌面层（FR-8.1 无需重启）', (tester) async {
    final controller = _RecordingDesktopController(SettingsRepository(db));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
          backupFilePickerProvider.overrideWithValue(picker),
          desktopControllerProvider.overrideWithValue(controller),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
    await openCloseBehavior(tester);

    // 点击分段即写库 + 实时应用桌面层。
    await tester.tap(find.text('最小化到托盘'));
    await tester.pumpAndSettle();

    expect(controller.applyCalls, 1);
    expect(find.text('已切换为最小化到托盘'), findsOneWidget);
  });
}

/// 假文件选择器：记录调用，返回空（取消），避免触碰平台对话框。
class FakeBackupFilePicker implements BackupFilePicker {
  int saveCalls = 0;
  int openCalls = 0;

  @override
  Future<File?> saveBackupFile() async {
    saveCalls++;
    return null;
  }

  @override
  Future<File?> openBackupFile() async {
    openCalls++;
    return null;
  }
}

/// 记录 applyCloseBehavior 调用次数的 DesktopController 替身。
///
/// 继承真实控制器以保留类型，仅 override 公开方法记录调用，避免在测试中
/// 触碰 windowManager / trayManager 平台 API。设置仓库复用真实实现，
/// 保证构造合法且不触碰平台。
class _RecordingDesktopController extends DesktopController {
  _RecordingDesktopController(SettingsRepository settings)
      : super(
          stateStore: WindowStateStore(),
          settingsRepository: settings,
        );

  int applyCalls = 0;

  @override
  Future<void> applyCloseBehavior() async {
    applyCalls++;
  }

  @override
  Future<void> initialize() async {
    // 测试中不初始化平台能力。
  }
}
