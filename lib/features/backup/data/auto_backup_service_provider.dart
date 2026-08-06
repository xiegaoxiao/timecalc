import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/data/settings_repository_provider.dart';
import '../data/auto_backup_service.dart';
import '../data/backup_service_provider.dart';
import '../data/credential_store.dart';

/// 自动备份服务 Provider。
///
/// http.Client 默认创建；测试 override 该 provider 传入 MockClient +
/// 假凭据存储。UI（「立即备份」/状态展示）与调度器共用同一实例。
final autoBackupServiceProvider = Provider<AutoBackupService>((ref) {
  return AutoBackupService(
    settingsRepository: ref.watch(settingsRepositoryProvider),
    backupService: ref.watch(backupServiceProvider),
    credentialStore: ref.watch(webDavCredentialStoreProvider),
  );
});
