import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

/// 应用数据库 Provider。
///
/// 数据事实保存在 Drift；Riverpod 只负责提供连接。
/// 测试中可 override 为内存数据库（见 Repository 测试）。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
  ref.onDispose(db.close);
  return db;
});
