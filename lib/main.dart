import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/database/database.dart';
import 'core/database/database_provider.dart';
import 'core/desktop/desktop_controller.dart';
import 'core/desktop/desktop_providers.dart';
import 'core/desktop/window_state_store.dart';
import 'core/errors/diagnostics_service.dart';
import 'core/errors/global_error_handlers.dart';
import 'core/errors/startup_error_screen.dart';
import 'features/backup/data/auto_backup_scheduler.dart';
import 'features/backup/data/auto_backup_service.dart';
import 'features/backup/data/backup_service.dart';
import 'features/backup/data/credential_store.dart';
import 'features/settings/data/settings_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面能力（FR-8）：window_manager 需在 runApp 前初始化，恢复窗口
  // 位置/尺寸/显示器归属；托盘与关闭行为随之建立。平台不可用时静默降级。
  await windowManager.ensureInitialized();

  // 诊断服务：全局错误处理器与「导出诊断信息」共用同一实例与日志。
  // 数据库打开前先安装处理器，开库失败时诊断导出仍可用（跳过数据段落）。
  final diagnostics = DiagnosticsService();
  installGlobalErrorHandlers(diagnostics);

  // 共享数据库连接：桌面控制器读取关闭行为（schema v6），
  // 应用各页经 databaseProvider 使用同一连接。
  final AppDatabase db;
  try {
    db = AppDatabase.open();
  } catch (error) {
    // 数据库无法打开（PRD §8）：运行启动错误屏，提示恢复或导出诊断，
    // 不裸崩溃。正常桌面能力（托盘/窗口恢复）在无库时不可用，忽略。
    diagnostics.capture(error);
    runApp(StartupErrorScope(error: error));
    return;
  }
  diagnostics.attachDatabase(db);

  final controller = await _createDesktopController(db);

  // 每日自动备份调度（FR-9.4，M8）：启动即检查一次 + 每小时复查。
  // 应用运行期间语义（进程只在窗口/托盘存活时存在）；失败经全局
  // ScaffoldMessenger 弹 SnackBar（未挂载时静默，下一次复查继续）。
  _startAutoBackupScheduler(db);

  runApp(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      desktopControllerProvider.overrideWithValue(controller),
      diagnosticsServiceProvider.overrideWithValue(diagnostics),
    ],
    child: const TimeCalcApp(),
  ));
}

/// 创建并启动自动备份调度器（幂等）。
void _startAutoBackupScheduler(AppDatabase db) {
  final scheduler = AutoBackupScheduler(
    service: AutoBackupService(
      settingsRepository: SettingsRepository(db),
      backupService: BackupService(db),
      credentialStore: SecureCredentialStore(),
    ),
    onFailure: (message) async {
      final messenger = DesktopController.scaffoldMessengerKey.currentContext;
      if (messenger == null) return;
      // SnackBar 在下一帧展示：runApp 前启动的首查失败时 key 尚未挂载，
      // 此处静默跳过（调度器自身已按日去重）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(messenger).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 6),
          ),
        );
      });
    },
  );
  scheduler.start();
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
