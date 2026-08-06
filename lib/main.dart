import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/database/database.dart';
import 'core/database/database_provider.dart';
import 'core/desktop/desktop_controller.dart';
import 'core/desktop/desktop_providers.dart';
import 'core/desktop/window_state_store.dart';
import 'features/settings/data/settings_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面能力（FR-8）：window_manager 需在 runApp 前初始化，恢复窗口
  // 位置/尺寸/显示器归属；托盘与关闭行为随之建立。平台不可用时静默降级。
  await windowManager.ensureInitialized();

  // 共享数据库连接：桌面控制器读取关闭行为（schema v6），
  // 应用各页经 databaseProvider 使用同一连接。
  final db = AppDatabase.open();

  final controller = await _createDesktopController(db);

  runApp(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      desktopControllerProvider.overrideWithValue(controller),
    ],
    child: const TimeCalcApp(),
  ));
}

/// 创建并初始化桌面控制器；失败时返回 null（桌面能力禁用，应用仍可用）。
Future<DesktopController?> _createDesktopController(AppDatabase db) async {
  try {
    final controller = DesktopController(
      stateStore: WindowStateStore(),
      settingsRepository: SettingsRepository(db),
    );
    await controller.initialize();
    return controller;
  } catch (_) {
    return null;
  }
}
