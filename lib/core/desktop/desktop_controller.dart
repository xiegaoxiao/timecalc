import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/database/tables.dart';
import '../../features/settings/data/settings_repository.dart';
import 'window_restore_service.dart';
import 'window_state_store.dart';

/// 桌面能力控制器（FR-8.1 / FR-8.2 / FR-8.3）。
///
/// 职责：
/// - 启动时恢复窗口位置/尺寸/最大化状态与显示器归属（FR-8.3）；
/// - 监听窗口移动/缩放/最大化事件并防抖保存状态（FR-8.3）；
/// - 关闭按钮行为：exit 正常退出；minimize_to_tray 时拦截关闭、最小化到
///   托盘，并在首次触发时说明当前选择（FR-8.1）；
/// - 托盘图标与菜单（显示主窗口 / 退出，FR-8.2）；
/// - 真正退出前调用 [onQuit] 一次（M9 退出推送；minimizeToTray 分支不
///   退出，不触发）。
///
/// 窗口状态经 [WindowStateStore] 持久化在独立 JSON 文件，不进入业务
/// 数据备份（FR-9.5）。所有平台调用封装在 [DesktopController]，widget
/// 测试通过 provider override 为 null 不触碰平台。
class DesktopController with WindowListener implements TrayListener {
  DesktopController({
    required this.stateStore,
    required SettingsRepository settingsRepository,
    String? trayIconAssetPath,
    this.onQuit,
  })  : _settings = settingsRepository,
        _trayIconAssetPath = trayIconAssetPath ?? defaultTrayIconAsset;

  static const String defaultTrayIconAsset = 'assets/icons/tray_icon.png';

  final WindowStateStore stateStore;
  final SettingsRepository _settings;
  final String _trayIconAssetPath;

  /// 真正退出前回调（M9 退出推送，带超时的尽力而为；失败不阻断退出）。
  final Future<void> Function()? onQuit;

  static const WindowRestoreService _restoreService = WindowRestoreService();

  /// 防抖计时：窗口事件频繁触发时合并写入。
  Timer? _saveDebounce;

  /// 启动时恢复窗口几何并建立事件监听。
  ///
  /// 在 `runApp` 之前调用（main.dart）。测试环境（非 Windows 或未初始化
  /// windowManager）时静默跳过。
  Future<void> initialize() async {
    try {
      final saved = await stateStore.read();
      final displays = await _queryDisplays();
      final primary = await _queryPrimaryDisplay();

      final restored = _restoreService.resolve(
        saved: saved.toSavedWindowState(),
        displays: displays,
        primaryId: primary?.id ?? '',
        defaultSize: const Size(1280, 720),
      );
      if (restored.position.dx >= 0 && restored.position.dy >= 0) {
        await windowManager.setPosition(restored.position);
      }
      await windowManager.setSize(restored.size);
      if (restored.maximized) {
        await windowManager.maximize();
      }

      windowManager.addListener(this);
      trayManager.addListener(this);

      await _applyCloseBehavior();
      await _setupTray();
    } catch (_) {
      // 平台不可用（测试/非桌面）时静默降级：窗口保持默认，桌面能力禁用。
    }
  }

  /// 重新应用关闭行为（FR-8.1：设置页变更后实时生效）。
  ///
  /// 读取最新设置并据此开关 [WindowManager.setPreventClose]。平台不可用
  /// 时静默降级（与 [initialize] 一致）。供设置页保存后调用，使「退出 ↔
  /// 最小化到托盘」切换无需重启即生效。
  Future<void> applyCloseBehavior() async {
    try {
      await _applyCloseBehavior();
    } catch (_) {
      // 平台不可用时静默降级，不影响设置保存。
    }
  }

  /// 根据设置应用关闭行为（FR-8.1）。
  ///
  /// exit：允许关闭（默认）；minimize_to_tray：拦截关闭事件并在首次触发
  /// 时说明当前选择。
  Future<void> _applyCloseBehavior() async {
    final settings = await _settings.get();
    final behavior = settings.closeBehavior;
    if (behavior == CloseBehavior.minimizeToTray) {
      await windowManager.setPreventClose(true);
    } else {
      await windowManager.setPreventClose(false);
    }
  }

  /// 托盘图标与菜单（FR-8.2）。
  Future<void> _setupTray() async {
    try {
      await trayManager.setIcon(_trayIconAssetPath);
      await trayManager.setToolTip('TimeCalc 时间计算器');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
              key: 'show',
              label: '显示主窗口',
              onClick: (_) => showMainWindow(),
            ),
            MenuItem.separator(),
            MenuItem(
              key: 'quit',
              label: '退出',
              onClick: (_) async {
                await _quitApp();
              },
            ),
          ],
        ),
      );
    } catch (_) {
      // 托盘不可用时忽略（非阻断）。
    }
  }

  /// 从托盘恢复主窗口（FR-8.2：显示主窗口）。
  ///
  /// 首次关闭到托盘后恢复时，说明当前选择（FR-8.1：首次触发时说明）。
  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    await _showPendingFirstTrayHint();
  }

  /// 保存当前窗口几何到状态存储（防抖）。
  Future<void> _saveWindowState() async {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final position = await windowManager.getPosition();
        final size = await windowManager.getSize();
        final maximized = await windowManager.isMaximized();
        final displays = await _queryDisplays();
        final state = await stateStore.read();
        // 显示器归属按窗口真实尺寸的中心点判断（与保存的几何一致）。
        final currentDisplay = _displayContaining(position, size, displays);
        await stateStore.write(
          state.copyWith(
            x: position.dx,
            y: position.dy,
            width: size.width,
            height: size.height,
            maximized: maximized,
            displayId: currentDisplay?.id ?? state.displayId,
          ),
        );
      } catch (_) {
        // 保存失败不影响应用（下次启动回到默认位置）。
      }
    });
  }

  /// 首次关闭到托盘时置为待提示（窗口已隐藏，延后到恢复时说明）。
  bool _pendingFirstTrayHint = false;

  /// 首次关闭到托盘后，在窗口恢复时说明当前选择（FR-8.1）。
  Future<void> _showPendingFirstTrayHint() async {
    if (!_pendingFirstTrayHint) return;
    _pendingFirstTrayHint = false;
    final state = await stateStore.read();
    if (state.trayFirstHintShown) return;
    await stateStore.write(state.copyWith(trayFirstHintShown: true));

    final messenger = _scaffoldMessengerKey.currentContext;
    if (messenger == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(messenger).showSnackBar(
        const SnackBar(
          content: Text('已最小化到托盘，可从托盘菜单恢复或退出'),
          duration: Duration(seconds: 4),
        ),
      );
    });
  }

  /// 全局 ScaffoldMessenger key（由 app.dart 挂载，供托盘恢复提示使用）。
  static final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static GlobalKey<ScaffoldMessengerState> get scaffoldMessengerKey =>
      _scaffoldMessengerKey;

  // ---- WindowListener ----

  @override
  void onWindowClose() async {
    try {
      final settings = await _settings.get();
      if (settings.closeBehavior == CloseBehavior.minimizeToTray) {
        // 记录首次关闭待提示（窗口隐藏后延后到恢复时说明）。
        final state = await stateStore.read();
        if (!state.trayFirstHintShown) {
          _pendingFirstTrayHint = true;
        }
        await windowManager.hide();
      } else {
        await _quitApp();
      }
    } catch (_) {
      await windowManager.destroy();
    }
  }

  /// 真正退出：先执行 onQuit（M9 退出推送，尽力而为），再销毁窗口。
  ///
  /// 同步/网络失败或超时都不阻断退出——退出必须及时，推送是可丢的兜底。
  Future<void> _quitApp() async {
    try {
      await onQuit?.call();
    } catch (_) {
      // 忽略：不阻塞退出。
    }
    await windowManager.destroy();
  }

  @override
  void onWindowMoved() {
    _saveWindowState();
  }

  @override
  void onWindowResized() {
    _saveWindowState();
  }

  @override
  void onWindowMaximize() {
    _saveWindowState();
  }

  @override
  void onWindowUnmaximize() {
    _saveWindowState();
  }

  @override
  void onWindowRestore() {
    _saveWindowState();
  }

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    // 单击图标：不做操作（菜单交互为主）。
  }

  @override
  void onTrayIconMouseUp() {
    // 无额外处理。
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键弹出菜单由托盘管理，无额外处理。
  }

  @override
  void onTrayIconRightMouseUp() {
    // 无额外处理。
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 菜单项 onClick 已处理。
  }

  // ---- 工具 ----

  static Future<List<DisplayInfo>> _queryDisplays() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      return [
        for (final d in displays)
          DisplayInfo(
            id: d.id,
            bounds: Rect.fromLTWH(
              d.visiblePosition?.dx ?? 0,
              d.visiblePosition?.dy ?? 0,
              d.size.width,
              d.size.height,
            ),
            workArea: d.visibleSize == null
                ? Rect.fromLTWH(
                    d.visiblePosition?.dx ?? 0,
                    d.visiblePosition?.dy ?? 0,
                    d.size.width,
                    d.size.height,
                  )
                : Rect.fromLTWH(
                    d.visiblePosition?.dx ?? 0,
                    d.visiblePosition?.dy ?? 0,
                    d.visibleSize!.width,
                    d.visibleSize!.height,
                  ),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<DisplayInfo?> _queryPrimaryDisplay() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      return DisplayInfo(
        id: display.id,
        bounds: Rect.fromLTWH(
          display.visiblePosition?.dx ?? 0,
          display.visiblePosition?.dy ?? 0,
          display.size.width,
          display.size.height,
        ),
        workArea: Rect.fromLTWH(
          display.visiblePosition?.dx ?? 0,
          display.visiblePosition?.dy ?? 0,
          display.visibleSize?.width ?? display.size.width,
          display.visibleSize?.height ?? display.size.height,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 窗口中心点所在的显示器（用于归属判断）。
  static DisplayInfo? _displayContaining(
    Offset position,
    Size size,
    List<DisplayInfo> displays,
  ) {
    final center = position + Offset(size.width / 2, size.height / 2);
    for (final display in displays) {
      if (display.bounds.contains(center)) return display;
    }
    return null;
  }

  void dispose() {
    _saveDebounce?.cancel();
  }
}
