import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/clock_provider.dart';
import 'checklist_item_repository.dart';

/// 检查项数据访问 Provider。
final checklistItemRepositoryProvider = Provider<ChecklistItemRepository>((ref) {
  return ChecklistItemRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  );
});

/// 任务下的检查项列表（family：按 taskId）。
final checklistItemsProvider =
    FutureProvider.family<List<ChecklistItem>, int>((ref, taskId) {
  return ref.watch(checklistItemRepositoryProvider).byTask(taskId);
});
