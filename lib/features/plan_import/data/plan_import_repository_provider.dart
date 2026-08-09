import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_provider.dart';
import 'plan_import_repository.dart';

/// 完整计划导入数据访问 Provider。
final planImportRepositoryProvider = Provider<PlanImportRepository>((ref) {
  return PlanImportRepository(ref.watch(databaseProvider));
});
