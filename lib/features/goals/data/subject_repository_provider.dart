import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/clock_provider.dart';
import '../data/subject_repository.dart';

/// 科目数据访问 Provider。
final subjectRepositoryProvider = Provider<SubjectRepository>((ref) {
  return SubjectRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  );
});

/// 目标下科目列表异步状态。
final subjectListProvider =
    FutureProvider.family<List<Subject>, int>((ref, goalId) {
  return ref.watch(subjectRepositoryProvider).byGoal(goalId);
});
