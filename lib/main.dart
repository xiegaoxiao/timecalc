import 'dart:async';

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
import 'features/goals/data/goal_repository_provider.dart';
import 'features/settings/data/settings_repository.dart';
import 'features/settings/data/settings_repository_provider.dart';
import 'features/sync/data/database_change_watcher.dart';
import 'features/sync/data/webdav_sync_service.dart';
import 'features/sync/data/webdav_sync_service_provider.dart';
import 'features/tasks/data/task_repository_provider.dart';

/// WebDAV 整库文件同步运行中周期拉取间隔（M9）。
///
/// 除启动拉取/变更推送/退出推送/手动外，每 5 分钟复查一次远端，补足
/// 另一设备在本机运行期间的变更。
const Duration kSyncPeriodicInterval = Duration(minutes: 5);

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

  // WebDAV 整库文件同步（M9）：拉取恢复后全量刷新各页 Provider。
  final syncService = WebDavSyncService(
    settingsRepository: SettingsRepository(db),
    backupService: BackupService(db),
    credentialStore: SecureCredentialStore(),
    schemaVersion: db.schemaVersion,
    onDataRestored: () async {
      final container = _container;
      if (container != null) _invalidateDataProviders(container);
    },
  );

  final controller = await _createDesktopController(
    db,
    onQuit: () => _pushSyncOnQuit(syncService),
  );

  // 每日自动备份调度（FR-9.4，M8）：启动即检查一次 + 每小时复查。
  // 应用运行期间语义（进程只在窗口/托盘存活时存在）；失败经全局
  // ScaffoldMessenger 弹 SnackBar（未挂载时静默，下一次复查继续）。
  _startAutoBackupScheduler(db);

  _container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      desktopControllerProvider.overrideWithValue(controller),
      diagnosticsServiceProvider.overrideWithValue(diagnostics),
      // 同步页「立即同步」复用同一实例：共享 onDataRestored（拉取后全量
      // 刷新 UI）与互斥锁，避免出现第二个独立同步实例。
      webDavSyncServiceProvider.overrideWithValue(syncService),
    ],
  );
  runApp(UncontrolledProviderScope(
    container: _container!,
    child: const TimeCalcApp(),
  ));

  // 同步接线（M9）：
  // - 启动拉取一次（runApp 后，ScaffoldMessenger key 已挂载可提示）；
  // - 运行中每 5 分钟复查远端（补足另一设备运行期间的变更）；
  // - 业务表变更防抖 3s 后推送（settings 表不监听，防推送写状态回环）。
  unawaited(syncService.syncOnce());
  Timer.periodic(kSyncPeriodicInterval, (_) => unawaited(syncService.syncOnce()));
  DatabaseChangeWatcher(
    db,
    onChanged: () => unawaited(syncService.pushIfNeeded()),
  );
}

/// 全局 ProviderContainer：同步拉取恢复后全量刷新各页缓存（恢复罕见，
/// 全量刷新可接受）。用与 [invalidateAppData] 相同的公共集合 + 同步相关。
ProviderContainer? _container;

/// 对容器级 provider 集合做整族失效（WidgetRef 版本的 invalidateAppData
/// 见 app_refresh.dart；这里直接作用于容器）。
void _invalidateDataProviders(ProviderContainer container) {
  container.invalidate(goalListProvider);
  container.invalidate(taskListProvider);
  container.invalidate(tasksByDateProvider);
  container.invalidate(tasksByMonthProvider);
  container.invalidate(unfinishedBeforeProvider);
  container.invalidate(completedTasksProvider);
  container.invalidate(allTodoTasksProvider);
  container.invalidate(settingsProvider);
}

/// 退出推送（带超时）：启动拉取/周期/变更之外的兜底，覆盖未推送的本地
/// 变更。失败不阻断退出（同步是尽力而为，退出必须及时）。
Future<void> _pushSyncOnQuit(WebDavSyncService syncService) async {
  try {
    await syncService.pushIfNeeded().timeout(const Duration(seconds: 5));
  } catch (_) {
    // 超时/失败忽略：不阻塞应用退出。
  }
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
///
/// [onQuit] 在真正退出（关闭窗口 exit 分支 / 托盘「退出」）前调用一次
/// （M9 退出推送；minimizeToTray 分支不退出，不触发）。
Future<DesktopController?> _createDesktopController(
  AppDatabase db, {
  Future<void> Function()? onQuit,
}) async {
  try {
    final controller = DesktopController(
      stateStore: WindowStateStore(),
      settingsRepository: SettingsRepository(db),
      onQuit: onQuit,
    );
    await controller.initialize();
    return controller;
  } catch (_) {
    return null;
  }
}
