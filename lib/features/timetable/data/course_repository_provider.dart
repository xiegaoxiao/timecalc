import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/clock_provider.dart';
import '../data/course_repository.dart';

/// 课程数据访问 Provider。
final courseRepositoryProvider = Provider<CourseRepository>((ref) {
  return CourseRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  );
});

/// 课表全部课程（按星期/节次排序）。
///
/// 课表页与课程表单共用：课程总量是「一学期几十门」的量级，整表读取比分页
/// 或按周过滤更简单，也让「本周之外还有哪些课」这类提示无需二次查询。
/// family 无参，任何课程写操作后 `ref.invalidate(courseListProvider)` 即可。
final courseListProvider = FutureProvider<List<Course>>((ref) {
  return ref.watch(courseRepositoryProvider).all();
});
