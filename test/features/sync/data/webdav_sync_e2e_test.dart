import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/backup/data/backup_service.dart';
import 'package:timecalc/features/backup/data/credential_store.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/sync/data/webdav_sync_service.dart';

/// 内存版 WebDAV 服务器（真实 HTTP 网络层，loopback）。
///
/// 实现同步所需的子集：MKCOL（建目录，认证根返回 403）、PUT（上传）、
/// GET（下载，404 幂等）、PROPFIND（depth:1 列目录）、DELETE（删除）。
/// 存储全部在内存中，模拟「远端 WebDAV 云盘」。
class _MemoryWebDavServer {
  final Map<String, Map<String, List<int>>> _dirs = {};
  late HttpServer _server;

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
    return _server.port;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final segs = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    try {
      if (req.method == 'MKCOL') {
        if (segs.length == 1) {
          req.response.statusCode = 403; // 认证根，客户端本不发送
        } else {
          _dirs[segs.last] ??= {};
          req.response.statusCode = 201;
        }
      } else if (req.method == 'PUT') {
        final dir = segs[segs.length - 2];
        final name = segs.last;
        final bytes =
            await req.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        _dirs[dir] ??= {};
        _dirs[dir]![name] = bytes;
        req.response.statusCode = 201;
      } else if (req.method == 'GET') {
        final bytes = _dirs[segs[segs.length - 2]]?[segs.last];
        if (bytes == null) {
          req.response.statusCode = 404;
        } else {
          req.response.statusCode = 200;
          req.response.add(bytes);
        }
      } else if (req.method == 'PROPFIND') {
        final dir = segs.last;
        final files = _dirs[dir] ?? {};
        final hrefBase = '/${segs.join('/')}';
        final buf = StringBuffer(
          '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">',
        );
        buf.write('<D:response><D:href>$hrefBase/</D:href>'
            '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
            '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
        files.forEach((name, bytes) {
          buf.write('<D:response><D:href>$hrefBase/$name</D:href>'
              '<D:propstat><D:prop><D:getcontentlength>${bytes.length}</D:getcontentlength>'
              '<D:getlastmodified>Thu, 06 Aug 2026 12:00:00 GMT</D:getlastmodified></D:prop>'
              '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
        });
        buf.write('</D:multistatus>');
        req.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        req.response.statusCode = 207;
        req.response.add(utf8.encode(buf.toString()));
      } else if (req.method == 'DELETE') {
        final removed = _dirs[segs[segs.length - 2]]?.remove(segs.last) != null;
        req.response.statusCode = removed ? 204 : 404;
      } else {
        req.response.statusCode = 501;
      }
    } catch (_) {
      req.response.statusCode = 500;
    }
    await req.response.close();
  }
}

/// 内存凭据存储（与单测同款，设备级独立实例）。
class _MemoryCredentialStore implements WebDavCredentialStore {
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

/// 一台「设备」：真实磁盘库 + 同步服务，配置指向本地 WebDAV。
class _Device {
  _Device._(this.db, this.sync);

  final AppDatabase db;
  final WebDavSyncService sync;

  static Future<_Device> create({
    required Directory dir,
    required String name,
    required String baseUrl,
  }) async {
    final dbFile = File('${dir.path}${Platform.pathSeparator}$name.db');
    final db = AppDatabase(NativeDatabase(dbFile));
    final credentials = _MemoryCredentialStore();
    final sync = WebDavSyncService(
      settingsRepository: SettingsRepository(db),
      backupService: BackupService(db),
      credentialStore: credentials,
      schemaVersion: db.schemaVersion,
    );
    await sync.settingsRepository.updateSyncEnabled(true);
    await sync.settingsRepository.updateWebDavConfig(
      url: baseUrl,
      username: 'alice',
    );
    await credentials.save(baseUrl, 'secret');
    await sync.settingsRepository.updateWebDavPasswordSaved(true);
    return _Device._(db, sync);
  }
}

/// WebDAV 同步端到端集成测试（M9「真同步」验证）。
///
/// 区别于 mock 单测：这里用**真实 HTTP 网络层**（dart:io HttpServer 充当
/// WebDAV 服务器）+ **真实磁盘数据库**（两台设备各自独立 .db 文件）跑完整
/// 同步流程，验证数据真的双向流转：
/// 1. 设备 A 写入数据并推送 → 远端有 A 的快照；
/// 2. 设备 B（空库）同步 → 拉取 A 的数据（真实覆盖）；
/// 3. 设备 B 新增数据并推送；
/// 4. 设备 A 再次同步 → 拉取 B 的增量（A 原有数据保留）；
/// 5. 两设备最终收敛一致。
void main() {
  late _MemoryWebDavServer server;
  late Directory tempDir;
  late String baseUrl;

  setUp(() async {
    server = _MemoryWebDavServer();
    final port = await server.start();
    baseUrl = 'http://127.0.0.1:$port/dav';
    tempDir = Directory.systemTemp.createTempSync('timecalc-sync-e2e');
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<int> seedGoal(AppDatabase db, String goalTitle, String taskTitle) async {
    final goalId = await db.into(db.goals).insert(
          GoalsCompanion.insert(
            title: goalTitle,
            deadlineDate: '2026-12-31',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await db.into(db.tasks).insert(
          TasksCompanion.insert(
            goalId: goalId,
            title: taskTitle,
            plannedDate: '2026-08-05',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    return goalId;
  }

  Future<Set<String>> goalTitles(AppDatabase db) async =>
      (await db.select(db.goals).get()).map((g) => g.title).toSet();

  Future<Set<String>> taskTitles(AppDatabase db) async =>
      (await db.select(db.tasks).get()).map((t) => t.title).toSet();

  test('设备 A → 设备 B → 设备 A 双向同步，数据真实流转并收敛', () async {
    final a = await _Device.create(dir: tempDir, name: 'device-a', baseUrl: baseUrl);
    final b = await _Device.create(dir: tempDir, name: 'device-b', baseUrl: baseUrl);

    // 1) A 写入本地数据并首次推送（远端无记录 → 只推不拉）。
    await seedGoal(a.db, 'A 的目标', 'A 的任务');
    final pushA = await a.sync.syncOnce();
    expect(pushA.pulled, isFalse);
    expect(pushA.pushed, isTrue, reason: '远端无记录，A 应推送');

    // 2) B（空库）同步：远端 seq 更高 → 应真实拉取 A 的数据到 B。
    final pullB = await b.sync.syncOnce();
    expect(pullB.pulled, isTrue, reason: '远端 seq 高于 B，B 应拉取');
    expect(pullB.safetyCopyPath, isNotNull, reason: '拉取覆盖前应创建安全副本');
    expect(await goalTitles(b.db), {'A 的目标'});
    expect(await taskTitles(b.db), {'A 的任务'});

    // 3) B 新增数据并推送（模拟「本地变更待推送」：B 刚拉取完处于抑制
    //    窗口内，watcher 入口 pushIfNeeded 会跳过；用 markLocalDirty +
    //    syncOnce 等价于「有变更、立即同步」。S2/S3 起无变更不盲目上传）。
    await seedGoal(b.db, 'B 的目标', 'B 的任务');
    b.sync.markLocalDirty();
    final pushB = await b.sync.syncOnce();
    expect(pushB.pushed, isTrue, reason: 'B 有新增，应推送');

    // 4) A 再次同步：远端包含 B 的更新 → 应拉取增量，且 A 原有数据保留。
    final pullA = await a.sync.syncOnce();
    expect(pullA.pulled, isTrue, reason: '远端 seq 高于 A，A 应拉取');
    expect(await goalTitles(a.db), {'A 的目标', 'B 的目标'});
    expect(await taskTitles(a.db), {'A 的任务', 'B 的任务'});

    // 5) 两设备最终数据一致（各自完成拉取/推送后收敛）。
    expect(await goalTitles(b.db), await goalTitles(a.db));
    expect(await taskTitles(b.db), await taskTitles(a.db));

    await a.db.close();
    await b.db.close();
  });

  test('设备 B 删除的数据在设备 A 同步后真实消失（覆盖语义）', () async {
    final a = await _Device.create(dir: tempDir, name: 'device-a', baseUrl: baseUrl);
    final b = await _Device.create(dir: tempDir, name: 'device-b', baseUrl: baseUrl);

    // A 推送两个目标。
    final goal1 = await seedGoal(a.db, '目标一', '任务一');
    await seedGoal(a.db, '目标二', '任务二');
    await a.sync.syncOnce();
    expect((await a.sync.settingsRepository.get()).lastPushedSeq, 1);

    // B 拉取全部数据。
    await b.sync.syncOnce();
    expect(await goalTitles(b.db), {'目标一', '目标二'});

    // B 删除「目标一」并推送（覆盖语义：清空 + 重导，删除必须传播）。
    // 同测试 1 第 3 步：拉取后的抑制窗口内用 markLocalDirty + syncOnce
    // 模拟「有本地变更、立即同步」。
    await (b.db.delete(b.db.tasks)..where((t) => t.goalId.equals(goal1))).go();
    await (b.db.delete(b.db.goals)..where((g) => g.id.equals(goal1))).go();
    b.sync.markLocalDirty();
    await b.sync.syncOnce();

    // A 再次同步：远端已无「目标一」→ A 应真实覆盖，目标一消失。
    final result = await a.sync.syncOnce();
    expect(result.pulled, isTrue, reason: '远端 seq 高于 A，A 应拉取');
    expect(await goalTitles(a.db), {'目标二'});
    expect(await taskTitles(a.db), {'任务二'});

    await a.db.close();
    await b.db.close();
  });
}
