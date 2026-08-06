import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/desktop/window_restore_service.dart';

/// WindowRestoreService 单元测试（FR-8.3）。
///
/// 覆盖：
/// - 保存的显示器仍可用：恢复原位置/尺寸；
/// - 保存的显示器不可用（插拔/换屏）：回退主屏可见区域；
/// - 从未保存过状态：主屏居中默认尺寸；
/// - 位置超出可见区域时约束到工作区；
/// - 尺寸大于工作区时收缩。
void main() {
  const service = WindowRestoreService();

  final primary = DisplayInfo(
    id: 'primary',
    bounds: const Rect.fromLTWH(0, 0, 1920, 1080),
    workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
  );
  final secondary = DisplayInfo(
    id: 'secondary',
    bounds: const Rect.fromLTWH(1920, 0, 1920, 1080),
    workArea: const Rect.fromLTWH(1920, 0, 1920, 1040),
  );
  const defaultSize = Size(1280, 720);

  test('从未保存状态：主屏工作区居中，默认尺寸', () {
    final restored = service.resolve(
      saved: const SavedWindowState(),
      displays: [primary, secondary],
      primaryId: 'primary',
      defaultSize: defaultSize,
    );
    expect(restored.size, defaultSize);
    // 居中：left = (1920-1280)/2 = 320，top = (1040-720)/2 = 160。
    expect(restored.position.dx, 320);
    expect(restored.position.dy, 160);
    expect(restored.maximized, isFalse);
  });

  test('保存的显示器仍可用：恢复原位置/尺寸/最大化状态', () {
    final restored = service.resolve(
      saved: const SavedWindowState(
        x: 2000,
        y: 200,
        width: 1000,
        height: 700,
        maximized: true,
        displayId: 'secondary',
      ),
      displays: [primary, secondary],
      primaryId: 'primary',
      defaultSize: defaultSize,
    );
    expect(restored.position, const Offset(2000, 200));
    expect(restored.size, const Size(1000, 700));
    expect(restored.maximized, isTrue);
  });

  test('保存的显示器不可用（已拔掉）：回退到主屏，位置约束在可见区域', () {
    final restored = service.resolve(
      saved: const SavedWindowState(
        x: 5000,
        y: 5000,
        width: 1000,
        height: 700,
        displayId: 'removed-display',
      ),
      displays: [primary, secondary],
      primaryId: 'primary',
      defaultSize: defaultSize,
    );
    // 原位置远超主屏：右缘约束到主屏工作区右缘。
    expect(restored.position.dx, greaterThanOrEqualTo(0));
    expect(restored.position.dx + restored.size.width,
        lessThanOrEqualTo(primary.workArea.right));
    expect(restored.position.dy, greaterThanOrEqualTo(0));
    expect(restored.position.dy + restored.size.height,
        lessThanOrEqualTo(primary.workArea.bottom));
    // 不再最大化（尺寸被裁剪过或位置调整，仍保留非最大化）。
    expect(restored.maximized, isFalse);
  });

  test('位置仅剩极少可见时平移到工作区（至少露出最小可见部分）', () {
    final restored = service.resolve(
      saved: const SavedWindowState(
        x: 1900,
        y: 1030,
        width: 400,
        height: 300,
        displayId: 'primary',
      ),
      displays: [primary],
      primaryId: 'primary',
      defaultSize: defaultSize,
    );
    // 原右缘 2300 超出 1920，可见仅 20px < 100：平移到 1920-400=1520。
    expect(restored.position.dx, 1520);
    // 原下缘 1330 超出 1040，可见仅 10px < 100：平移到 1040-300=740。
    expect(restored.position.dy, 740);
  });

  test('窗口尺寸大于工作区：收缩到工作区并放在工作区左上', () {
    final restored = service.resolve(
      saved: const SavedWindowState(
        x: 100,
        y: 100,
        width: 2500,
        height: 2000,
        displayId: 'primary',
      ),
      displays: [primary],
      primaryId: 'primary',
      defaultSize: defaultSize,
    );
    // 收缩到工作区尺寸，原位置保持在工作区内。
    expect(restored.size, const Size(1920, 1040));
    expect(restored.position.dx, greaterThanOrEqualTo(0));
    expect(restored.position.dy, greaterThanOrEqualTo(0));
    expect(restored.maximized, isFalse);
  });

  test('没有任何显示器信息：使用默认尺寸与原点', () {
    final restored = service.resolve(
      saved: const SavedWindowState(x: 50, y: 50, width: 800, height: 600),
      displays: const [],
      primaryId: '',
      defaultSize: defaultSize,
    );
    expect(restored.size, defaultSize);
    expect(restored.position, Offset.zero);
    expect(restored.maximized, isFalse);
  });

  test('主显示器 id 未知时回退到第一个显示器', () {
    final restored = service.resolve(
      saved: const SavedWindowState(),
      displays: [secondary],
      primaryId: 'unknown-primary',
      defaultSize: defaultSize,
    );
    // 以第一个显示器（secondary）工作区居中。
    expect(restored.position.dx, 1920 + (1920 - 1280) / 2);
    expect(restored.position.dy, (1040 - 720) / 2);
  });
}
