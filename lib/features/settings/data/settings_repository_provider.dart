import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/clock_provider.dart';
import '../data/settings_repository.dart';

/// 计划偏好数据访问 Provider。
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  );
});

/// 计划偏好异步状态（单行设置表）。
final settingsProvider = FutureProvider<Setting>((ref) {
  return ref.watch(settingsRepositoryProvider).get();
});
