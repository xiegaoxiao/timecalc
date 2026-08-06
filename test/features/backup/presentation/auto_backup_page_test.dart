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
import 'package:timecalc/features/backup/presentation/auto_backup_page.dart';
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

/// AutoBackupPage widget 测试（M8，FR-9.4）。
///
/// 覆盖：
/// - 初始状态：开关关闭、本地目录未选择、WebDAV 留空；
/// - 选择目录 → 显示路径；保存 → 持久化到 settings；
/// - 保存并测试连接：完整填写 → 连接成功 → 密码写入凭据存储；
/// - 立即备份 → force 执行成功 → SnackBar 反馈。
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late BackupService backup;
  late _FakeCredentialStore credentials;
  late FakeBackupFolderPicker picker;

  Future<void> pumpPage(WidgetTester tester) async {
    // 页面较长（开关卡 + 本地卡 + WebDAV 卡 + 立即备份卡），放大视口
    // 避免按钮落在 600px 默认视口外（ListView 惰性构建，视口外 tap 不中）。
    tester.view.physicalSize = const Size(900, 2000);
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
        child: const MaterialApp(home: AutoBackupPage()),
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

  testWidgets('初始状态：开关关闭、目录未选择、WebDAV 留空', (tester) async {
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
  });

  testWidgets('选择目录后显示路径并持久化', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('选择目录…'));
    await tester.pumpAndSettle();
    expect(find.text('C:\\Backups'), findsOneWidget);
    expect(picker.calls, 1);

    await tester.tap(find.text('仅保存'));
    await tester.pumpAndSettle();

    final saved = await settings.get();
    expect(saved.localBackupFolder, 'C:\\Backups');
  });

  testWidgets('保存并测试连接：WebDAV 完整填写后连接成功并保存密码', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav',
    );
    await tester.enterText(find.widgetWithText(TextField, '用户名'), 'alice');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'secret');
    await tester.tap(find.text('保存并测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('连接成功'), findsOneWidget);

    final saved = await settings.get();
    expect(saved.webdavUrl, 'https://dav.example.com/dav');
    expect(saved.webdavUsername, 'alice');
    expect(saved.webdavPasswordSaved, isTrue);
    expect(credentials.store['https://dav.example.com/dav'], 'secret');
  });

  testWidgets('WebDAV 填写不完整时提示，不发起连接', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav',
    );
    await tester.tap(find.text('保存并测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请完整填写'), findsOneWidget);
    expect(credentials.store, isEmpty);
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
}
