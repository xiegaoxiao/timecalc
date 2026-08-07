import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:timecalc/features/backup/data/auto_backup_service.dart';
import 'package:timecalc/features/backup/data/auto_backup_service_provider.dart';
import 'package:timecalc/features/backup/data/backup_folder_picker.dart';
import 'package:timecalc/features/backup/data/backup_service.dart';
import 'package:timecalc/features/backup/data/credential_store.dart';
import 'package:timecalc/features/backup/presentation/backup_page.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';

/// 假目录选择器。
class FakeBackupFolderPicker implements BackupFolderPicker {
  FakeBackupFolderPicker(this.paths);

  final List<String?> paths;
  int calls = 0;

  @override
  Future<String?> pickFolder() async {
    if (calls >= paths.length) return null;
    return paths[calls++];
  }
}

/// 内存凭据存储假实现。
class _FakeCredentialStore implements WebDavCredentialStore {
  final Map<String, String> store = {};

  @override
  Future<void> save(String url, String password) async => store[url] = password;

  @override
  Future<String?> read(String url) async => store[url];

  @override
  Future<void> delete(String url) async => store.remove(url);
}

/// BackupPage widget 测试（M8 FR-9.4；M11 自动备份并入本页）。
///
/// 覆盖：
/// - 初始状态：自动备份开关关闭、本地目录未选择；
/// - 选择目录 → 显示路径 + 点击即写库（无保存按钮）；
/// - 开关点击即写库（无需再点保存）+ 开启后立即触发一次检查反馈；
/// - 立即备份 → force 执行成功 → SnackBar 反馈。
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late BackupService backup;
  late _FakeCredentialStore credentials;
  late FakeBackupFolderPicker picker;

  Future<void> pumpPage(WidgetTester tester) async {
    // 页面较长（自动备份区 + 手动区），放大视口避免按钮落在默认
    // 600px 视口外（ListView 惰性构建，视口外 tap 不中）。
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backupFolderPickerProvider.overrideWithValue(picker),
          webDavCredentialStoreProvider.overrideWithValue(credentials),
          autoBackupServiceProvider.overrideWithValue(
            AutoBackupService(
              settingsRepository: settings,
              backupService: backup,
              credentialStore: credentials,
              httpClient: MockClient((_) async => http.Response('', 201)),
            ),
          ),
        ],
        child: const MaterialApp(home: BackupPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
    backup = BackupService(db);
    credentials = _FakeCredentialStore();
    picker = FakeBackupFolderPicker(['C:\\Backups']);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('初始状态：自动备份开关关闭、目录未选择', (tester) async {
    await pumpPage(tester);
    expect(find.text('启用每日自动备份'), findsOneWidget);
    expect(find.text('未选择（本地目的地不启用）'), findsOneWidget);
    expect(
      find.widgetWithText(SwitchListTile, '启用每日自动备份'),
      findsOneWidget,
    );
    final switchTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '启用每日自动备份'),
    );
    expect(switchTile.value, isFalse);
    // 手动区入口存在。
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('从备份恢复'), findsOneWidget);
    expect(find.text('从备份位置恢复'), findsOneWidget);
  });

  testWidgets('选择目录后显示路径并点击即写库', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('选择目录…'));
    await tester.pumpAndSettle();
    expect(find.text('C:\\Backups'), findsOneWidget);
    expect(picker.calls, 1);

    // 点击即写库（无保存按钮）。
    final saved = await settings.get();
    expect(saved.localBackupFolder, 'C:\\Backups');
  });

  testWidgets('立即备份：配置本地目录后执行成功并显示反馈', (tester) async {
    // 预置本地目录（临时目录，可写）。
    final tempDir = Directory.systemTemp.createTempSync('timecalc-auto-ui');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    await settings.updateAutoBackupEnabled(true);
    await settings.updateLocalBackupFolder(tempDir.path);
    await pumpPage(tester);

    // run() 含真实磁盘 I/O（导出 zip 到临时目录），需在 runAsync 中完成；
    // 期间 CircularProgressIndicator 持续动画，不能直接 pumpAndSettle。
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '立即备份'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('自动备份完成'), findsOneWidget);
  });

  testWidgets('开关点击即写库：无需再点保存（review 修复）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(SwitchListTile, '启用每日自动备份'));
    await tester.pumpAndSettle();
    // 推进时间让「正在检查…」SnackBar 消失，结果反馈（跳过原因）显示。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // 未点任何保存按钮，开关已落库。
    expect((await settings.get()).autoBackupEnabled, isTrue);
    // 未配置目录 → 立即检查反馈跳过原因（明确而非静默）。
    expect(find.textContaining('已启用'), findsOneWidget);
    expect(find.textContaining('未配置备份目的地'), findsOneWidget);
  });

  testWidgets('开启后立即触发一次检查：配置本地目录则直接完成备份', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('timecalc-auto-ui');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    await settings.updateLocalBackupFolder(tempDir.path);
    await pumpPage(tester);

    // 开关点击 → 写库 + 立即 run()（含磁盘 I/O，需 runAsync）。
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(SwitchListTile, '启用每日自动备份'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    // 推进时间让「正在检查…」消失，完成反馈显示。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect((await settings.get()).autoBackupEnabled, isTrue);
    expect(find.textContaining('自动备份完成'), findsOneWidget);
  });
}
