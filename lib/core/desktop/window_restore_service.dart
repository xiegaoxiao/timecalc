import 'dart:ui';

/// 显示器描述（逻辑像素）。
class DisplayInfo {
  const DisplayInfo({
    required this.id,
    required this.bounds,
    required this.workArea,
  });

  final String id;

  /// 显示器完整区域（逻辑像素）。
  final Rect bounds;

  /// 显示器工作区（排除任务栏，逻辑像素）；null 时回退用 [bounds]。
  final Rect workArea;
}

/// 保存的窗口状态（来自 [WindowStateStore]）。
class SavedWindowState {
  const SavedWindowState({
    this.x,
    this.y,
    this.width,
    this.height,
    this.maximized = false,
    this.displayId,
  });

  final double? x;
  final double? y;
  final double? width;
  final double? height;
  final bool maximized;
  final String? displayId;

  bool get hasGeometry => x != null && y != null && width != null && height != null;
}

/// 恢复后的窗口几何信息。
class RestoredWindowState {
  const RestoredWindowState({
    required this.position,
    required this.size,
    required this.maximized,
  });

  final Offset position;
  final Size size;
  final bool maximized;
}

/// 窗口位置/多屏恢复规则（FR-8.3）。
///
/// 纯 Dart 服务，不依赖平台 API：
/// - 保存的显示器仍可用：窗口恢复到原显示器上的原位置/尺寸；
/// - 保存的显示器不可用（插拔/换屏）：回退到主屏可见区域；
/// - 从未保存过状态：使用默认位置与尺寸（主屏居中）。
class WindowRestoreService {
  const WindowRestoreService();

  /// 计算恢复后的窗口几何。
  ///
  /// [displays] 为当前全部显示器，[primaryId] 为主显示器 id。
  /// 返回结果保证窗口完整落在目标显示器的可见区域内。
  RestoredWindowState resolve({
    required SavedWindowState saved,
    required List<DisplayInfo> displays,
    required String primaryId,
    required Size defaultSize,
  }) {
    if (displays.isEmpty) {
      // 没有任何显示器信息：使用默认位置与尺寸。
      return RestoredWindowState(
        position: Offset.zero,
        size: defaultSize,
        maximized: false,
      );
    }
    final primary = _displayById(displays, primaryId) ?? displays.first;

    // 目标显示器：保存的显示器仍可用则用它，否则主屏。
    final target =
        _displayById(displays, saved.displayId ?? '') ?? primary;

    if (!saved.hasGeometry) {
      return RestoredWindowState(
        position: _centerIn(target.workArea, defaultSize),
        size: defaultSize,
        maximized: false,
      );
    }

    // 保存的尺寸可能有下界缺失（损坏的 window_state.json）：钳制到
    // 最小可用窗口，避免以 0/负尺寸「恢复」窗口导致不可见（P2-9）。
    final size = Size(
      _clampWidth(saved.width!),
      _clampHeight(saved.height!),
    );
    final position = Offset(saved.x!, saved.y!);
    final restored = _fitToVisibleArea(
      position: position,
      size: size,
      workArea: target.workArea,
    );
    return RestoredWindowState(
      position: restored.position,
      size: restored.size,
      maximized: saved.maximized && restored.size == size,
    );
  }

  /// 窗口最小尺寸（与桌面约定一致，防止损坏配置恢复出不可见窗口）。
  static const double _minWidth = 400;
  static const double _minHeight = 300;

  static double _clampWidth(double w) => w < _minWidth ? _minWidth : w;

  static double _clampHeight(double h) => h < _minHeight ? _minHeight : h;

  static DisplayInfo? _displayById(List<DisplayInfo> displays, String id) {
    for (final display in displays) {
      if (display.id == id) return display;
    }
    return null;
  }

  /// 把窗口几何约束到显示器可见区域：尽量保持原位置与尺寸，超出则平移
  /// 或收缩，保证窗口有足够部分可见。
  static RestoredWindowState _fitToVisibleArea({
    required Offset position,
    required Size size,
    required Rect workArea,
  }) {
    const minVisible = 100.0; // 窗口至少露出 100 逻辑像素

    // 窗口尺寸大于工作区时收缩到工作区。
    final effectiveSize = Size(
      size.width > workArea.width ? workArea.width : size.width,
      size.height > workArea.height ? workArea.height : size.height,
    );

    var left = position.dx;
    var top = position.dy;

    // 横向：窗口右缘至少露出 minVisible。
    if (left < workArea.left - (effectiveSize.width - minVisible)) {
      left = workArea.left;
    }
    if (left > workArea.right - minVisible) {
      left = workArea.right - effectiveSize.width;
    }

    // 纵向同理。
    if (top < workArea.top - (effectiveSize.height - minVisible)) {
      top = workArea.top;
    }
    if (top > workArea.bottom - minVisible) {
      top = workArea.bottom - effectiveSize.height;
    }

    return RestoredWindowState(
      position: Offset(left, top),
      size: effectiveSize,
      maximized: false,
    );
  }

  static Offset _centerIn(Rect workArea, Size size) {
    final left = workArea.left + (workArea.width - size.width) / 2;
    final top = workArea.top + (workArea.height - size.height) / 2;
    return Offset(left, top);
  }
}
