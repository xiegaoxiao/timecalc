import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 上次输入的预估时长（分钟）记忆。
///
/// 同类任务（如真题套卷 180 分钟）通常时长一致，记忆上次输入
/// 让批量/单个添加都少填一次字段。仅内存态，不持久化。
final lastMinutesProvider =
    StateProvider<int?>((ref) => null);
