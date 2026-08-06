import 'package:flutter/material.dart';

import 'db_error_dialog.dart';

/// 数据库写入守卫（PRD §8：数据库异常时停止继续写入并提示）。
///
/// drift 的每个 Repository 写入均在事务内完成（NFR-2），失败自动回滚，
/// 不会留下半条写入；本守卫负责异常上报到 UI：弹「数据保存失败」对话框，
/// 引导用户从备份恢复或导出诊断信息。
///
/// 用法：把原 `await repo.xxx(...)` 包进 [runDbAction] 的 [action] 中；
/// 返回 true 表示写入成功，false 表示发生异常（对话框已弹出，调用方
/// 应跳过后续「保存成功」类提示与导航）。
Future<bool> runDbAction(
  BuildContext context, {
  required Future<void> Function() action,
}) async {
  try {
    await action();
    return true;
  } catch (error) {
    if (!context.mounted) return false;
    await showDbErrorDialog(context, error: error);
    return false;
  }
}
