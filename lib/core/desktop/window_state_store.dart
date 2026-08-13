import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'window_restore_service.dart';

/// 保存的窗口状态（FR-8.3）。
///
/// 序列化到 JSON 文件（`window_state.json`，位于应用支持目录）。
/// 按 FR-9.5，窗口状态属于桌面层状态，不进入业务数据备份。
class WindowState {
  const WindowState({
    this.x,
    this.y,
    this.width,
    this.height,
    this.maximized = false,
    this.displayId,
    this.trayFirstHintShown = false,
  });

  final double? x;
  final double? y;
  final double? width;
  final double? height;
  final bool maximized;

  /// 上次窗口所在显示器 id（screen_retriever 的 Display.id）。
  final String? displayId;

  /// 首次最小化到托盘时的说明是否已展示（FR-8.1「首次触发时说明当前选择」）。
  final bool trayFirstHintShown;

  /// 转换为纯几何模型（供窗口恢复规则计算）。
  SavedWindowState toSavedWindowState() {
    return SavedWindowState(
      x: x,
      y: y,
      width: width,
      height: height,
      maximized: maximized,
      displayId: displayId,
    );
  }

  WindowState copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    bool? maximized,
    String? displayId,
    bool? trayFirstHintShown,
  }) {
    return WindowState(
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      maximized: maximized ?? this.maximized,
      displayId: displayId ?? this.displayId,
      trayFirstHintShown: trayFirstHintShown ?? this.trayFirstHintShown,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'maximized': maximized,
      'displayId': displayId,
      'trayFirstHintShown': trayFirstHintShown,
    };
  }

  factory WindowState.fromJson(Map<String, Object?> json) {
    return WindowState(
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      width: (json['width'] as num?)?.toDouble(),
      height: (json['height'] as num?)?.toDouble(),
      maximized: json['maximized'] as bool? ?? false,
      displayId: json['displayId'] as String?,
      trayFirstHintShown: json['trayFirstHintShown'] as bool? ?? false,
    );
  }
}

/// 窗口状态持久化（FR-8.3 / FR-9.5）。
///
/// 读写独立 JSON 文件，损坏时返回默认状态（容错，不影响应用启动）。
class WindowStateStore {
  /// 使用注入的目录（测试可控）；null 时用 path_provider 支持目录。
  WindowStateStore({Future<Directory>? directory})
      : _directoryOverride = directory;

  final Future<Directory>? _directoryOverride;

  static const _fileName = 'window_state.json';

  Future<Directory> _directory() async {
    final override = _directoryOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return support;
  }

  Future<File> _file() async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取窗口状态；文件不存在或损坏时返回默认状态。
  Future<WindowState> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const WindowState();
      final raw = await file.readAsString();
      final json = jsonDecode(raw);
      if (json is! Map) return const WindowState();
      return WindowState.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return const WindowState();
    }
  }

  /// 写入窗口状态（覆盖式，幂等）。
  ///
  /// 原子写（L21）：先写临时文件再 rename 覆盖，避免中途崩溃留下截断的
  /// JSON（读侧虽已容错自愈，但截断写会丢失上次完整状态）。
  Future<void> write(WindowState state) async {
    final dir = await _directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()));
    await tmp.rename(file.path);
  }
}
