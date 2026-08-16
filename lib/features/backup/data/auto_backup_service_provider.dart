import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/data/settings_repository_provider.dart';
import '../data/auto_backup_service.dart';
import '../data/backup_service_provider.dart';

/// 自动备份服务 Provider。
///
/// UI（「立即备份」/状态展示）与调度器共用同一实例。
/// 2026-08：移除 WebDAV 后不再需要 http.Client 与凭据存储注入。
final autoBackupServiceProvider = Provider<AutoBackupService>((ref) {
  return AutoBackupService(
    settingsRepository: ref.watch(settingsRepositoryProvider),
    backupService: ref.watch(backupServiceProvider),
  );
});
