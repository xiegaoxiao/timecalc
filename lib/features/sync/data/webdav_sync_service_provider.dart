import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_provider.dart';
import '../../backup/data/backup_service_provider.dart';
import '../../backup/data/credential_store.dart';
import '../../settings/data/settings_repository_provider.dart';
import 'webdav_sync_service.dart';

/// WebDAV 整库文件同步服务 Provider（M9）。
///
/// 与 [autoBackupServiceProvider] 同款约定：http.Client 默认创建；
/// 测试 override 该 provider 传入 MockClient + 假凭据存储。UI（同步页
/// 「立即同步」/状态展示）与调度接线共用同一实例。
final webDavSyncServiceProvider = Provider<WebDavSyncService>((ref) {
  final db = ref.watch(databaseProvider);
  return WebDavSyncService(
    settingsRepository: ref.watch(settingsRepositoryProvider),
    backupService: ref.watch(backupServiceProvider),
    credentialStore: ref.watch(webDavCredentialStoreProvider),
    schemaVersion: db.schemaVersion,
  );
});
