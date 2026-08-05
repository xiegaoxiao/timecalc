import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../data/recurrence_repository.dart';

/// 重复任务数据访问 Provider。
final recurrenceRepositoryProvider = Provider<RecurrenceRepository>((ref) {
  return RecurrenceRepository(ref.watch(databaseProvider));
});

/// 目标下重复任务模板列表。
final recurrenceTemplatesProvider =
    FutureProvider.family<List<RecurrenceTemplate>, int>((ref, goalId) {
  return ref.watch(recurrenceRepositoryProvider).byGoal(goalId);
});

/// 单个重复模板（任务条目标注/编辑规则用）。
final recurrenceTemplateProvider =
    FutureProvider.family<RecurrenceTemplate?, int>((ref, templateId) {
  return ref.watch(recurrenceRepositoryProvider).byId(templateId);
});

/// 应用启动时的滚动生成任务（FR-4.3：窗口临近时生成缺失实例）。
///
/// 由 AppShell 首帧 watch 一次触发；无 active 模板时为空操作。
final recurrenceBootstrapProvider = FutureProvider<int>((ref) {
  return ref.watch(recurrenceRepositoryProvider).generateDue();
});
