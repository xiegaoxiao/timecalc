import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/backup/data/backup_service.dart';
import 'package:timecalc/features/backup/data/credential_store.dart';
import 'package:timecalc/features/backup/data/webdav_client.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/sync/data/webdav_sync_service.dart';

/// 内存凭据存储假实现（与 auto_backup_service_test 同款，测试间不共享）。
class _FakeCredentialStore implements WebDavCredentialStore {
  final Map<String, String> _passwords = {};

  @override
  Future<void> save(String url, String password) async {
    _passwords[url] = password;
  }

  @override
  Future<String?> read(String url) async => _passwords[url];

  @override
  Future<void> delete(String url) async {
    _passwords.remove(url);
  }
}

/// WebDavSyncService 测试（M9）。
///
/// 覆盖：
/// - 未启用 / WebDAV 账号缺失 → 跳过；
/// - 首次推送：写快照 + meta，seq 递增，更新 lastPushedSeq；
/// - 远端较新 → 拉取覆盖本地（远端任务出现、同步开关保持、seq 吸收）；
/// - 远端不快 → 只推不拉；
/// - schema 版本守卫：远端由更高版本生成 → 中止；
/// - 拉取后不再重复拉取（lastPushedSeq 已吸收远端 seq）。
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late BackupService backup;
  late _FakeCredentialStore credentials;
  late Directory tempDir;

  Future<void> seedGoal(String title) async {
    await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: title,
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
  }

  /// 用另一内存库导出「远端」快照字节。
  Future<List<int>> remoteSnapshotBytes(String remoteGoalTitle) async {
    // 测试内另开独立内存库构造远端快照（drift 多库告警仅 debug 显示，
    // 两个内存库互不干扰，可忽略）。
    final remoteDb = AppDatabase(NativeDatabase.memory());
    final remoteBackup = BackupService(remoteDb);
    await remoteDb.into(remoteDb.goals).insert(
          GoalsCompanion.insert(
            title: remoteGoalTitle,
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    final file = File('${tempDir.path}/remote-snapshot.timecalc');
    await remoteBackup.exportBackup(file);
    final bytes = await file.readAsBytes();
    await remoteDb.close();
    return bytes;
  }

  /// 构建 mock WebDAV：GET meta / GET 快照 / MKCOL / PUT。
  ///
  /// [remoteMeta] 为 null 时 meta 请求返回 404（远端无同步记录）。
  WebDavSyncService service({
    required MockClient client,
  }) =>
      WebDavSyncService(
        settingsRepository: settings,
        backupService: backup,
        credentialStore: credentials,
        schemaVersion: db.schemaVersion,
        httpClient: client,
      );

  Map<String, dynamic> meta(int seq, {int appSchemaVersion = 11}) => {
        'format': 'timecalc-sync',
        'version': 1,
        'seq': seq,
        'syncedAtUtc': '2026-08-07T03:00:00.000Z',
        'appSchemaVersion': appSchemaVersion,
      };

  /// 常规请求处理器：远端 meta（seq=3）+ 快照 + 上传成功。
  MockClient okRemote({int remoteSeq = 3, required List<int> snapshot}) {
    return MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'MKCOL') return http.Response('', 201);
      if (req.method == 'PUT') return http.Response('', 201);
      if (req.method == 'GET' &&
          path.endsWith('/webdav_sync/timecalc-sync.meta.json')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode(meta(remoteSeq))),
          200,
        );
      }
      if (req.method == 'GET' &&
          path.endsWith('/webdav_sync/timecalc-sync.latest.timecalc')) {
        return http.Response.bytes(snapshot, 200);
      }
      return http.Response('', 404);
    });
  }

  /// 启用同步并配置 WebDAV 账号（凭据写入内存假存储）。
  Future<void> enableSync() async {
    await settings.updateSyncEnabled(true);
    await settings.updateWebDavConfig(
      url: 'https://dav.example.com/dav',
      username: 'alice',
    );
    await credentials.save('https://dav.example.com/dav', 'secret');
    await settings.updateWebDavPasswordSaved(true);
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
    backup = BackupService(db);
    credentials = _FakeCredentialStore();
    tempDir = Directory.systemTemp.createTempSync('timecalc-sync-test');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('未启用同步时跳过', () async {
    final result = await service(client: okRemote(snapshot: [])).syncOnce();
    expect(result.skipped, isTrue);
    expect(result.skipReason, contains('未开启'));
  });

  test('已启用但 WebDAV 账号缺失时跳过', () async {
    await settings.updateSyncEnabled(true);
    // 未配置 url/用户名，也不保存密码。
    final result = await service(client: okRemote(snapshot: [])).syncOnce();
    expect(result.skipped, isTrue);
    expect(result.skipReason, contains('未配置 WebDAV 账号'));
  });

  test('首次推送：写快照 + meta，seq 从 1 起，更新 lastPushedSeq', () async {
    await enableSync();
    await seedGoal('本地目标');

    // 远端无 meta（404）。
    final requests = <String>[];
    final client = MockClient((req) async {
      requests.add('${req.method} ${req.url.path}');
      if (req.method == 'MKCOL') return http.Response('', 201);
      if (req.method == 'PUT') return http.Response('', 201);
      return http.Response('', 404);
    });

    final result = await service(client: client).syncOnce();

    expect(result.skipped, isFalse);
    expect(result.pulled, isFalse);
    expect(result.pushed, isTrue);
    // 上传了快照与 meta（含 ensureFolder）。
    expect(
      requests.where((r) => r.startsWith('PUT')).toSet(),
      containsAll([
        'PUT /dav/webdav_sync/timecalc-sync.latest.timecalc',
        'PUT /dav/webdav_sync/timecalc-sync.meta.json',
      ]),
    );
    // seq 从 1 起，本设备记录同步状态。
    final s = await settings.get();
    expect(s.lastPushedSeq, 1);
    expect(s.lastSyncedAt, isNotNull);
    // 同步开关保持开启。
    expect(s.webdavSyncEnabled, isTrue);
  });

  test('远端较新时拉取覆盖本地，远端数据出现且同步开关保持（M9 核心）', () async {
    await enableSync();
    await seedGoal('本地目标（将被覆盖）');

    final snapshot = await remoteSnapshotBytes('远端目标');
    final result = await service(client: okRemote(snapshot: snapshot)).syncOnce();

    expect(result.skipped, isFalse);
    expect(result.pulled, isTrue);
    expect(result.safetyCopyPath, isNotNull); // FR-9.3 安全副本

    // 远端数据已覆盖本地。
    final goals = await db.select(db.goals).get();
    expect(goals.map((g) => g.title), ['远端目标']);
    expect(goals.map((g) => g.title), isNot(contains('本地目标')));

    // 拉取后推送（nextSeq = remoteSeq + 1 = 4），本设备状态更新。
    final s = await settings.get();
    expect(s.lastPushedSeq, 4);
    expect(s.webdavSyncEnabled, isTrue); // 同步开关不被拉取重置
    expect(s.webdavUrl, 'https://dav.example.com/dav'); // WebDAV 账号保留
  });

  test('远端不快时只推不拉（本地 seq 更高）', () async {
    await enableSync();
    await seedGoal('本地目标');
    await settings.updateSyncState(seq: 5, at: DateTime.utc(2026, 8, 7, 1));

    final snapshot = await remoteSnapshotBytes('远端目标');
    final result = await service(client: okRemote(remoteSeq: 3, snapshot: snapshot)).syncOnce();

    expect(result.skipped, isFalse);
    expect(result.pulled, isFalse); // remoteSeq(3) <= localSeq(5)：不拉取
    expect(result.pushed, isTrue);
    // 本地数据未被动过。
    final goals = await db.select(db.goals).get();
    expect(goals.map((g) => g.title), ['本地目标']);
    // nextSeq = max(5, 3) + 1 = 6。
    expect((await settings.get()).lastPushedSeq, 6);
  });

  test('远端由更高 schema 版本生成时中止（不拉取不推送）', () async {
    await enableSync();
    await seedGoal('本地目标');

    final client = MockClient((req) async {
      if (req.method == 'GET' &&
          req.url.path.endsWith('/webdav_sync/timecalc-sync.meta.json')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode(meta(9, appSchemaVersion: 99))),
          200,
        );
      }
      return http.Response('', 404);
    });

    final result = await service(client: client).syncOnce();

    expect(result.skipped, isFalse);
    expect(result.error, contains('更新版本'));
    // 未拉取也未推送，本地数据与 seq 保持不变。
    final goals = await db.select(db.goals).get();
    expect(goals.map((g) => g.title), ['本地目标']);
    expect((await settings.get()).lastPushedSeq, isNull);
  });

  test('拉取成功后 seq 已吸收，再次同步不重复拉取（幂等）', () async {
    await enableSync();
    await seedGoal('本地目标');

    final snapshot = await remoteSnapshotBytes('远端目标');
    final service = WebDavSyncService(
      settingsRepository: settings,
      backupService: backup,
      credentialStore: credentials,
      schemaVersion: db.schemaVersion,
      httpClient: okRemote(snapshot: snapshot),
    );

    await service.syncOnce();
    // 第二次：本地 seq(4) >= 远端 seq(3)，只推不拉。
    final second = await service.syncOnce();
    expect(second.pulled, isFalse);
    expect(second.pushed, isTrue);
    expect((await settings.get()).lastPushedSeq, 5);
  });

  test('并发调用时互斥（一次同步进行中，另一次跳过）', () async {
    await enableSync();
    await seedGoal('本地目标');

    var release = false;
    final client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'MKCOL') return http.Response('', 201);
      if (req.method == 'GET' && path.endsWith('timecalc-sync.meta.json')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode(meta(0))),
          200,
        );
      }
      if (req.method == 'PUT') {
        // 阻塞第一个同步的推送，制造并发窗口。
        while (!release) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return http.Response('', 201);
      }
      return http.Response('', 404);
    });

    final service = WebDavSyncService(
      settingsRepository: settings,
      backupService: backup,
      credentialStore: credentials,
      schemaVersion: db.schemaVersion,
      httpClient: client,
    );

    final first = service.syncOnce();
    // 第一个仍在跑（推送被阻塞），第二个应跳过。
    final second = await service.syncOnce();
    expect(second.skipped, isTrue);
    expect(second.skipReason, contains('正在进行'));

    release = true;
    final firstResult = await first;
    expect(firstResult.pushed, isTrue);
  });

  test('testConnection：建目录 + 列目录成功（只读探测）', () async {
    final requested = <String>[];
    final client = MockClient((req) async {
      requested.add('${req.method} ${req.url.path}');
      if (req.method == 'MKCOL') return http.Response('', 201);
      if (req.method == 'PROPFIND') {
        return http.Response.bytes(
          utf8.encode('<D:multistatus xmlns:D="DAV:"/>'),
          207,
          headers: {'content-type': 'application/xml'},
        );
      }
      return http.Response('', 404);
    });

    final service = WebDavSyncService(
      settingsRepository: settings,
      backupService: backup,
      credentialStore: credentials,
      schemaVersion: db.schemaVersion,
      httpClient: client,
    );
    await service.testConnection(
      url: 'https://dav.example.com/dav',
      username: 'alice',
      password: 'secret',
    );

    // ensureFolder（webdav_sync）+ PROPFIND 列目录。
    expect(requested, contains('MKCOL /dav/webdav_sync'));
    expect(requested, contains('PROPFIND /dav/webdav_sync'));
  });

  test('testConnection：401 抛 WebDavAuthException（可读认证提示）', () async {
    final client = MockClient((req) async {
      if (req.method == 'MKCOL') return http.Response('', 201);
      return http.Response('', 401);
    });
    final service = WebDavSyncService(
      settingsRepository: settings,
      backupService: backup,
      credentialStore: credentials,
      schemaVersion: db.schemaVersion,
      httpClient: client,
    );
    await expectLater(
      service.testConnection(
        url: 'https://dav.example.com/dav',
        username: 'alice',
        password: 'wrong',
      ),
      throwsA(isA<WebDavAuthException>()),
    );
  });

  test('testConnection：403 抛可读异常（无权限）', () async {
    final client = MockClient((req) async {
      if (req.method == 'MKCOL') return http.Response('', 201);
      return http.Response('', 403);
    });
    final service = WebDavSyncService(
      settingsRepository: settings,
      backupService: backup,
      credentialStore: credentials,
      schemaVersion: db.schemaVersion,
      httpClient: client,
    );
    await expectLater(
      service.testConnection(
        url: 'https://dav.example.com/dav',
        username: 'alice',
        password: 'secret',
      ),
      throwsA(isA<WebDavException>()),
    );
  });
}
