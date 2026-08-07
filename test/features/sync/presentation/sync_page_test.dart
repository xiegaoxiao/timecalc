import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/features/backup/data/backup_service.dart';
import 'package:timecalc/features/backup/data/credential_store.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/sync/data/webdav_sync_service.dart';
import 'package:timecalc/features/sync/data/webdav_sync_service_provider.dart';
import 'package:timecalc/features/sync/presentation/sync_page.dart';

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

/// SyncPage widget 测试（M9 + 记住密码/连通性测试）。
///
/// 覆盖：
/// - 初始状态：开关关闭、WebDAV 留空、尚未同步过；
/// - 仅保存：开关 + WebDAV 账号持久化，密码写入凭据存储；
/// - 保存并测试连接：完整填写 → 连接成功 → 配置已保存 + 密码写入；
/// - 测试连接密码留空：复用已保存密码测通；
/// - 清除已保存密码：凭据删除 + 标记重置；
/// - 改地址未填密码：重置「已保存」标记（新地址无可用密码）；
/// - 立即同步（未启用/已启用）：跳过提示 / 推送成功反馈。
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late BackupService backup;
  late _FakeCredentialStore credentials;

  /// 默认 mock：MKCOL/PUT 成功、PROPFIND 返回空列表、远端无 meta。
  MockClient okClient() => MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        if (req.method == 'PUT') return http.Response('', 201);
        if (req.method == 'PROPFIND') {
          return http.Response.bytes(
            utf8.encode('<D:multistatus xmlns:D="DAV:"/>'),
            207,
            headers: {'content-type': 'application/xml'},
          );
        }
        return http.Response('', 404);
      });

  Future<void> pumpPage(WidgetTester tester, {MockClient? client}) async {
    // 页面较长，放大视口避免按钮落在默认 600px 视口外。
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          webDavCredentialStoreProvider.overrideWithValue(credentials),
          webDavSyncServiceProvider.overrideWithValue(
            WebDavSyncService(
              settingsRepository: settings,
              backupService: backup,
              credentialStore: credentials,
              schemaVersion: db.schemaVersion,
              httpClient: client ?? okClient(),
            ),
          ),
        ],
        child: const MaterialApp(home: SyncPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
    backup = BackupService(db);
    credentials = _FakeCredentialStore();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('初始状态：开关关闭、WebDAV 留空、尚未同步过', (tester) async {
    await pumpPage(tester);
    expect(find.text('启用 WebDAV 同步'), findsOneWidget);
    final switchTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '启用 WebDAV 同步'),
    );
    expect(switchTile.value, isFalse);
    expect(find.text('尚未同步过'), findsOneWidget);
    // 未保存密码时无「清除」入口。
    expect(find.text('清除已保存密码'), findsNothing);
  });

  testWidgets('开关点击即写库：无需点保存（自动同步，review 修复）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(SwitchListTile, '启用 WebDAV 同步'));
    await tester.pumpAndSettle();

    // 点击即写库（无「仅保存」按钮）。
    expect(find.textContaining('已启用自动同步'), findsOneWidget);
    expect((await settings.get()).webdavSyncEnabled, isTrue);
  });

  testWidgets('保存并测试连接：完整填写 → 连接成功 → 配置已保存', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav',
    );
    await tester.enterText(find.widgetWithText(TextField, '用户名'), 'alice');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'secret');
    await tester.tap(find.text('保存并测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('连接成功，WebDAV 配置已保存'), findsOneWidget);
    final saved = await settings.get();
    expect(saved.webdavUrl, 'https://dav.example.com/dav');
    expect(saved.webdavPasswordSaved, isTrue);
    expect(credentials.store['https://dav.example.com/dav'], 'secret');
  });

  testWidgets('测试连接密码留空：复用已保存密码测通', (tester) async {
    // 预置已保存密码。
    await credentials.save('https://dav.example.com/dav', 'remembered');
    await settings.updateWebDavConfig(
      url: 'https://dav.example.com/dav',
      username: 'alice',
    );
    await settings.updateWebDavPasswordSaved(true);
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://dav.example.com/dav',
    );
    await tester.enterText(find.widgetWithText(TextField, '用户名'), 'alice');
    await tester.tap(find.text('保存并测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('连接成功'), findsOneWidget);
  });

  testWidgets('清除已保存密码：凭据删除 + 标记重置，提示重新填写', (tester) async {
    await credentials.save('https://dav.example.com/dav', 'secret');
    await settings.updateWebDavConfig(
      url: 'https://dav.example.com/dav',
      username: 'alice',
    );
    await settings.updateWebDavPasswordSaved(true);
    await pumpPage(tester);

    // 已记住状态可见。
    expect(find.textContaining('密码已记住'), findsOneWidget);
    await tester.tap(find.text('清除已保存密码'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已清除已保存的密码'), findsOneWidget);
    expect(credentials.store, isEmpty);
    expect((await settings.get()).webdavPasswordSaved, isFalse);
    // 清除后「已记住」行消失。
    expect(find.textContaining('密码已记住'), findsNothing);
  });

  testWidgets('改地址未填密码：重置「已保存」标记（新地址无可用密码）', (tester) async {
    await credentials.save('https://dav.example.com/dav', 'secret');
    await settings.updateWebDavConfig(
      url: 'https://dav.example.com/dav',
      username: 'alice',
    );
    await settings.updateWebDavPasswordSaved(true);
    await pumpPage(tester);

    // 改成新地址，不填密码，走「保存并测试连接」：地址变更但新地址无密码，
    // 测试连接会失败（mock 的 read 对新地址返回 null → 提示填密码）。
    await tester.enterText(
      find.widgetWithText(TextField, '服务器地址'),
      'https://new.example.com/dav',
    );
    await tester.tap(find.text('保存并测试连接'));
    await tester.pumpAndSettle();

    // 新地址无已保存密码 → 提示先填密码，未写库。
    expect(find.textContaining('请填写密码'), findsOneWidget);
    expect((await settings.get()).webdavUrl, 'https://dav.example.com/dav');
    expect(credentials.store['https://dav.example.com/dav'], 'secret'); // 旧密码仍在
  });

  testWidgets('立即同步（未启用）：展示跳过原因', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.widgetWithText(FilledButton, '立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未同步：WebDAV 同步未开启'), findsOneWidget);
  });

  testWidgets('立即同步（已启用）：推送成功并显示上次同步时间', (tester) async {
    await settings.updateSyncEnabled(true);
    await settings.updateWebDavConfig(
      url: 'https://dav.example.com/dav',
      username: 'alice',
    );
    await credentials.save('https://dav.example.com/dav', 'secret');
    await settings.updateWebDavPasswordSaved(true);
    await pumpPage(tester);

    // 推送含真实磁盘 I/O（导出 zip），需在 runAsync 中完成。
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '立即同步'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('已推送本地数据到远端'), findsOneWidget);
    final saved = await settings.get();
    expect(saved.lastPushedSeq, isNotNull);
    expect(saved.lastSyncedAt, isNotNull);
  });
}
