import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/desktop/window_state_store.dart';

/// WindowStateStore 单元测试（FR-8.3 / FR-9.5）。
///
/// 覆盖：
/// - 写入→读取往返一致（含托盘首次提示标志）；
/// - 文件不存在/损坏时返回默认状态（容错，不影响启动）。
void main() {
  late Directory tempDir;
  late WindowStateStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('timecalc-window-state');
    store = WindowStateStore(directory: Future.value(tempDir));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('写入后读取往返一致', () async {
    final state = const WindowState(
      x: 100,
      y: 200,
      width: 1280,
      height: 720,
      maximized: true,
      displayId: 'primary',
      trayFirstHintShown: true,
    );
    await store.write(state);

    final read = await store.read();
    expect(read.x, 100);
    expect(read.y, 200);
    expect(read.width, 1280);
    expect(read.height, 720);
    expect(read.maximized, isTrue);
    expect(read.displayId, 'primary');
    expect(read.trayFirstHintShown, isTrue);
  });

  test('默认状态全为 null/false（首次启动）', () async {
    final state = await store.read();
    expect(state.x, isNull);
    expect(state.maximized, isFalse);
    expect(state.displayId, isNull);
    expect(state.trayFirstHintShown, isFalse);
  });

  test('copyWith 更新部分字段保留其余', () async {
    final base = const WindowState(x: 100, y: 100);
    final updated = base.copyWith(width: 800, trayFirstHintShown: true);
    expect(updated.x, 100);
    expect(updated.width, 800);
    expect(updated.trayFirstHintShown, isTrue);
  });

  test('损坏的 JSON 文件返回默认状态（容错）', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}window_state.json');
    await file.writeAsString('这不是 JSON{{{');

    final state = await store.read();
    expect(state.x, isNull);
    expect(state.maximized, isFalse);
  });
}
