import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/data/settings_repository_provider.dart';
import 'desktop_controller.dart';
import 'window_state_store.dart';

/// 窗口状态存储 Provider（测试中可 override 临时目录）。
final windowStateStoreProvider = Provider<WindowStateStore>((ref) {
  return WindowStateStore();
});

/// 桌面能力控制器 Provider。
///
/// 默认在 main.dart 中初始化并注入真实实现；widget 测试中 override 为 null，
/// 避免触碰平台 API（托盘/窗口/显示器）。
final desktopControllerProvider = Provider<DesktopController?>((ref) {
  return DesktopController(
    stateStore: ref.watch(windowStateStoreProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
});
