import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/database/database.dart';
import '../../backup/data/backup_manifest.dart';
import '../../backup/data/backup_service.dart';
import '../../backup/data/credential_store.dart';
import '../../backup/data/webdav_client.dart';
import '../../settings/data/settings_repository.dart';

/// WebDAV 整库文件同步的远端布局（M9）。
///
/// 同步目录与自动备份目录（`webdav_auto/`）隔离：
/// - [syncSnapshotFile]：完整快照（`BackupService.exportBackup` 产物，zip，
///   排除运行时配置）；远端只有这一份最新快照，后写者胜；
/// - [syncMetaFile]：小元数据（seq/时间/schema 版本），用于免下载大文件
///   比较新旧。
const String syncFolder = 'webdav_sync';
const String syncSnapshotFile = 'timecalc-sync.latest.timecalc';
const String syncMetaFile = 'timecalc-sync.meta.json';
const String syncMetaFormat = 'timecalc-sync';
const int syncMetaVersion = 1;

/// 同步执行结果（调度、UI 与测试共用）。
class SyncResult {
  const SyncResult({
    required this.skipped,
    required this.pulled,
    required this.pushed,
    this.skipReason,
    this.error,
    this.safetyCopyPath,
    this.localChangesOverwritten = false,
  });

  /// 是否跳过（未启用 / 未配置 WebDAV 账号 / 同步互斥中）。
  final bool skipped;

  /// 是否发生了「拉取远端快照覆盖本地」。
  final bool pulled;

  /// 是否发生了「推送本地快照到远端」。
  final bool pushed;

  /// 跳过原因（skipped 为 true 时给用户可读文案）。
  final String? skipReason;

  /// 失败原因（拉取/推送失败时）。
  final String? error;

  /// 拉取覆盖前自动创建的安全副本路径（供 UI 提示，可恢复极端场景）。
  final String? safetyCopyPath;

  /// 本次拉取覆盖前，本地存在尚未推送的变更（分叉：本设备离线期间也
  /// 有编辑，远端又更新过）。提示用户：本地未推送的改动已被远端覆盖，
  /// 如需找回可从安全副本恢复。
  final bool localChangesOverwritten;

  bool get hasError => !skipped && error != null;
}

/// WebDAV 整库文件同步（M9）。
///
/// 以「整库快照」为同步单元（PRD §11 本地优先的演进：业务实体全带
/// id/时间戳/schema 版本，同步复用备份快照格式）：
/// - 远端只保留一份最新快照 + meta，**后写者胜**；
/// - [syncOnce]：远端 seq 较新 → 拉取覆盖本地（覆盖前自动安全副本，
///   复用 FR-9.3；运行时配置 close_behavior/自动备份/同步自身各设备保留）；
///   随后始终推送本地快照（seq 递增）；
/// - 拉取恢复期间置 [_restoring] 守卫，避免恢复引发的表更新再次触发推送
///   形成回环；
/// - 覆盖恢复把同步配置列一并保留（backup_codec/settings 保留分支），
///   拉取不会关闭或重置本设备的同步状态。
///
/// 复用 [BackupService] 的导出/覆盖恢复全链路与 [WebDavClient] 的
/// 上传/下载；不引入新依赖（S0 无新增）。异常统一转可读文案，不泄漏
/// URL 与凭据（NFR-3）。
class WebDavSyncService {
  WebDavSyncService({
    required this.settingsRepository,
    required this.backupService,
    required this.credentialStore,
    required this.schemaVersion,
    http.Client? httpClient,
    this.onDataRestored,
  }) : _httpClient = httpClient ?? http.Client();
  final SettingsRepository settingsRepository;
  final BackupService backupService;
  final WebDavCredentialStore credentialStore;

  /// 本地数据库 schema 版本：用于守卫「远端快照由更高版本生成时不覆盖」。
  final int schemaVersion;
  final http.Client _httpClient;

  /// 拉取恢复完成后回调（供 main 全量 invalidate Provider 刷新 UI）。
  final Future<void> Function()? onDataRestored;

  /// 互斥锁：同一时刻只允许一个同步在跑（周期拉取/变更推送/手动并发时
  /// 合并，避免 seq 竞态）。
  bool _running = false;

  /// 拉取恢复进行中的守卫（防止恢复写入触发变更推送回环）。
  bool _restoring = false;

  /// 本地存在「尚未推送的变更」标记（本会话内，M9 分叉检测）。
  ///
  /// 由 [pushIfNeeded]（本地变更监听触发）置位；「启动拉取/周期复查/手动
  /// 立即同步」不置位（它们是主动同步，不代表本地有未推送编辑）。拉取
  /// 覆盖本地成功或推送成功（本地数据已与远端对齐）后清除。
  bool _hasLocalChanges = false;

  /// 本地变更计数：`pushIfNeeded` 每置位一次 +1。同步结束后仅当计数未变
  /// 才清除脏标记，避免「同步进行中又来了新变更」被并发误清（L30）。
  int _changeCount = 0;

  /// 拉取恢复期间的变更监听抑制窗口（M9/S2 防回环）。
  ///
  /// 拉取恢复会向业务表写入大量行，触发 DatabaseChangeWatcher 的 3s 防抖
  /// 推送；若不抑制，恢复结束后的那次推送会把「刚拉取到的数据」原样推回
  /// 远端（seq +1），另一台设备再拉再推，形成双设备乒乓。恢复开始时把
  /// 抑制窗口设到「恢复耗时 + 防抖 + 余量」之后，窗口内的 watcher 触发
  /// 一律跳过（也不置脏标记）。窗口内的真实用户编辑同样被跳过——概率极低
  /// 且下次编辑/启动仍会推送，可接受。
  DateTime? _suppressWatchUntil;

  /// 启动时标记本地有未推送的变更（覆盖「应用崩溃于上次推送前」的窗口）：
  /// 使启动后的首次同步无条件推送一次本地快照。
  void markLocalDirty() {
    _hasLocalChanges = true;
    _changeCount++;
  }

  /// 执行一次完整同步：先拉取（远端较新时覆盖本地），再推送本地快照。
  ///
  /// 未启用或 WebDAV 账号缺失时跳过（与自动备份同款「跳过 ≠ 失败」语义）。
  Future<SyncResult> syncOnce() async {
    if (_running) {
      return const SyncResult(
        skipped: true,
        pulled: false,
        pushed: false,
        skipReason: '同步正在进行中',
      );
    }
    _running = true;
    try {
      return await _syncOnce();
    } finally {
      _running = false;
    }
  }

  /// 变更监听/退出时的「推送」入口：与 [syncOnce] 同一算法（远端较新仍
  /// 先拉取，避免用过期本地数据覆盖更新的远端）。
  ///
  /// 与 [syncOnce] 的唯一区别：先置「本地有未推送变更」标记——本入口只由
  /// 本地数据写入触发，用于拉取覆盖本地时向用户提示分叉风险。
  ///
  /// 拉取恢复引发的业务表写入也会触发本入口；恢复期间（[_suppressWatchUntil]
  /// 窗口内）跳过且**不置脏标记**，防止「拉取 → 回推 → seq+1 → 另一设备
  /// 再拉再推」的双设备乒乓（M9/S2）。
  Future<SyncResult> pushIfNeeded() {
    final until = _suppressWatchUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      return Future.value(
        const SyncResult(
          skipped: true,
          pulled: false,
          pushed: false,
          skipReason: '同步恢复中，变更推送已抑制',
        ),
      );
    }
    _hasLocalChanges = true;
    _changeCount++;
    return syncOnce();
  }

  /// 测试 WebDAV 连接（只读探测，仿 AutoBackupService.testWebDavConnection）。
  ///
  /// 用传入的地址/用户名/密码构建客户端，在同步目录上「建目录 + 列目录」
  /// 一次验证：成功说明地址/用户名/密码可用且目录可写；失败抛可读异常
  /// （[WebDavAuthException] 401 / [WebDavException]）。供「保存并测试连接」
  /// 使用（密码尚未落库时也能测，测通后才保存）。
  Future<void> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final client = WebDavClient(
      client: _httpClient,
      baseUrl: url,
      username: username,
      password: password,
    );
    await client.ensureFolder(syncFolder);
    await client.list(syncFolder);
  }

  Future<SyncResult> _syncOnce() async {
    final settings = await settingsRepository.get();
    if (!settings.webdavSyncEnabled) {
      return const SyncResult(
        skipped: true,
        pulled: false,
        pushed: false,
        skipReason: 'WebDAV 同步未开启',
      );
    }

    final client = await _buildClient(settings);
    if (client == null) {
      return const SyncResult(
        skipped: true,
        pulled: false,
        pushed: false,
        skipReason: '未配置 WebDAV 账号（请先在「同步」页填写地址与用户名）',
      );
    }

    final SyncMeta? remoteMeta;
    try {
      remoteMeta = await _readRemoteMeta(client);
    } on WebDavException catch (e) {
      // meta 存在但损坏/格式不兼容：转为可读失败结果，不抛未处理异常
      // （M13，也避免被上层当作「无 meta」盲推覆盖远端）。
      return SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
        error: e.message,
      );
    }
    if (remoteMeta == null) {
      // 远端没有 meta（首次启用或远端被清空）：始终推送一次本地快照建立
      // 基线（同时覆盖「应用崩溃于上次推送前」的未推送变更）。
      return await _push(client, localSeq: settings.lastPushedSeq, remoteSeq: 0);
    }

    // 拉取守卫：远端快照由更高 schema 版本生成时拒绝覆盖（避免降级读坏）。
    if (remoteMeta.appSchemaVersion > schemaVersion) {
      return SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
        error: '远端数据由更新版本的应用创建（schema ${remoteMeta.appSchemaVersion}），'
            '请先升级应用再同步',
      );
    }

    final localSeq = settings.lastPushedSeq ?? 0;
    // 快照同步开始时的变更计数：结束清脏标记时校验「期间没有新变更」。
    final changeCountAtStart = _changeCount;
    // 分叉检测：拉取覆盖前本地已有未推送变更（离线编辑 + 远端更新）。
    final conflictDetected = _hasLocalChanges;

    if (remoteMeta.seq > localSeq) {
      // 远端较新：拉取覆盖本地（覆盖前自动安全副本）。
      final pullResult = await _pull(client, remoteMeta);
      if (pullResult.hasError) return pullResult;
      // 拉取成功：本地已与远端对齐。**不再回推**——否则「拉取→回推→
      // seq+1→另一设备再拉再推」形成双设备乒乓（S2），seq 无界增长。
      if (_changeCount == changeCountAtStart) {
        _hasLocalChanges = false;
      }
      return SyncResult(
        skipped: false,
        pulled: true,
        pushed: false,
        safetyCopyPath: pullResult.safetyCopyPath,
        localChangesOverwritten: conflictDetected,
      );
    }

    // 远端不快于本地：仅当「有待推送的本地变更」或「本地 seq 领先远端
    // （远端被清空/回退）」时才推送；空闲时跳过整库导出上传（S3）。
    final shouldPush = _hasLocalChanges || localSeq > remoteMeta.seq;
    if (!shouldPush) {
      return const SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
      );
    }
    final pushResult = await _push(
      client,
      localSeq: localSeq,
      remoteSeq: remoteMeta.seq,
    );
    if (pushResult.hasError) {
      return SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
        error: pushResult.error,
      );
    }
    // 推送成功：本地最新数据已上送远端；期间无新变更才清除脏标记。
    if (_changeCount == changeCountAtStart) {
      _hasLocalChanges = false;
    }
    return const SyncResult(
      skipped: false,
      pulled: false,
      pushed: true,
    );
  }

  Future<WebDavClient?> _buildClient(Setting settings) async {
    final url = settings.webdavUrl;
    final username = settings.webdavUsername;
    if (url == null ||
        url.trim().isEmpty ||
        username == null ||
        username.trim().isEmpty) {
      return null;
    }
    final String password;
    try {
      final saved = await credentialStore.read(url);
      if (saved == null || saved.isEmpty) return null;
      password = saved;
    } on Exception catch (e) {
      // L27：secure_storage 平台异常不冒泡为未处理异步错误，转可读文案。
      throw WebDavException('读取保存的密码失败：$e');
    }
    return WebDavClient(
      client: _httpClient,
      baseUrl: url,
      username: username,
      password: password,
    );
  }

  /// 读取远端 meta（404 = 不存在 → null）。
  ///
  /// meta **存在但解析失败/格式不兼容**时抛异常（而非返回 null）：
  /// 返回 null 会被上层当作「远端无 meta」而盲推覆盖本地快照——若远端是
  /// 更新格式或新版本应用写入的数据，覆盖会绕过 schema 版本守卫（M13）。
  Future<SyncMeta?> _readRemoteMeta(WebDavClient client) async {
    try {
      final bytes = await client.download('$syncFolder/$syncMetaFile');
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const WebDavException(
          '远端同步元数据损坏（JSON 解析失败），已停止同步以避免覆盖远端数据',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const WebDavException(
          '远端同步元数据格式不正确，已停止同步以避免覆盖远端数据',
        );
      }
      final meta = SyncMeta.fromJson(decoded);
      if (meta == null) {
        throw const WebDavException(
          '远端同步元数据版本不兼容，已停止同步以避免覆盖远端数据',
        );
      }
      return meta;
    } on WebDavException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 拉取远端快照覆盖本地；返回本次拉取结果（成功时 pulled=true）。
  ///
  /// 覆盖前自动安全副本（FR-9.3）；覆盖恢复保留运行时配置（含同步开关与
  /// seq），拉取不会关闭同步。拉取成功把「已吸收远端 seq」写回，避免下次
  /// 周期又重复拉取。
  Future<SyncResult> _pull(WebDavClient client, SyncMeta meta) async {
    if (_restoring) {
      return const SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
        error: '同步互斥：正在恢复数据',
      );
    }
    _restoring = true;
    final tempDir = await Directory.systemTemp.createTemp('timecalc-sync');
    final tempFile = File(
      '${tempDir.path}${Platform.pathSeparator}$syncSnapshotFile',
    );
    try {
      final bytes = await client.download('$syncFolder/$syncSnapshotFile');
      await tempFile.writeAsBytes(bytes);
      // 下载成功、即将恢复写入时才设抑制窗口（防「恢复 → 回推」乒乓，
      // 见 pushIfNeeded）；失败路径不残留——否则下载失败后 15s 内本地
      // 真实变更会被静默跳过（review 反馈）。
      _suppressWatchUntil =
          DateTime.now().add(const Duration(seconds: 15));
      final safety = await backupService.restoreBackup(
        tempFile,
        mode: RestoreMode.overwrite,
      );
      await settingsRepository.updateSyncState(
        seq: meta.seq,
        at: DateTime.now().toUtc(),
      );
      if (onDataRestored != null) await onDataRestored!();
      return SyncResult(
        skipped: false,
        pulled: true,
        pushed: false,
        safetyCopyPath: safety?.path,
      );
    } on Exception catch (e) {
      return SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
        error: '拉取失败：$e',
      );
    } finally {
      _restoring = false;
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }

  /// 导出本地快照并上传（快照 + meta），更新本设备同步状态。
  Future<SyncResult> _push(
    WebDavClient client, {
    required int? localSeq,
    required int remoteSeq,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('timecalc-sync');
    final tempFile = File(
      '${tempDir.path}${Platform.pathSeparator}$syncSnapshotFile',
    );
    try {
      await backupService.exportBackup(tempFile);
      final bytes = await tempFile.readAsBytes();
      final now = DateTime.now().toUtc();
      final nextSeq = (localSeq ?? 0) > remoteSeq
          ? (localSeq ?? 0) + 1
          : remoteSeq + 1;
      final meta = SyncMeta(
        format: syncMetaFormat,
        version: syncMetaVersion,
        seq: nextSeq,
        syncedAtUtc: now,
        appSchemaVersion: schemaVersion,
      );

      await client.ensureFolder(syncFolder);
      await client.upload('$syncFolder/$syncSnapshotFile', bytes);
      await client.upload(
        '$syncFolder/$syncMetaFile',
        utf8.encode(jsonEncode(meta.toJson())),
      );
      await settingsRepository.updateSyncState(seq: nextSeq, at: now);
      return SyncResult(skipped: false, pulled: false, pushed: true);
    } on Exception catch (e) {
      return SyncResult(
        skipped: false,
        pulled: false,
        pushed: false,
        error: '推送失败：$e',
      );
    } finally {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }
}

/// 同步远端元数据（免下载大快照即可比较新旧）。
class SyncMeta {
  const SyncMeta({
    required this.format,
    required this.version,
    required this.seq,
    required this.syncedAtUtc,
    required this.appSchemaVersion,
  });

  final String format;
  final int version;
  final int seq;
  final DateTime syncedAtUtc;
  final int appSchemaVersion;

  static SyncMeta? fromJson(Map<String, dynamic> json) {
    if (json['format'] != syncMetaFormat || json['version'] != syncMetaVersion) {
      return null;
    }
    final seq = json['seq'] as int?;
    final schema = json['appSchemaVersion'] as int?;
    final at = DateTime.tryParse(json['syncedAtUtc'] as String? ?? '');
    if (seq == null || schema == null || at == null) return null;
    return SyncMeta(
      format: syncMetaFormat,
      version: syncMetaVersion,
      seq: seq,
      syncedAtUtc: at,
      appSchemaVersion: schema,
    );
  }

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': version,
        'seq': seq,
        'syncedAtUtc': syncedAtUtc.toIso8601String(),
        'appSchemaVersion': appSchemaVersion,
      };
}
