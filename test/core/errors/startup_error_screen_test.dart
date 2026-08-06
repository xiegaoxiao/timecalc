import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/errors/diagnostics_service.dart';
import 'package:timecalc/core/errors/startup_error_screen.dart';

/// 启动错误屏测试（PRD §8：数据库无法打开时的兜底界面）。
///
/// 验证内容可渲染：说明、数据库路径、从备份恢复指引与导出诊断入口；
/// 导出诊断使用假选择器，不触碰平台对话框。
void main() {
  testWidgets('启动错误屏展示说明、路径与恢复指引', (tester) async {
    await tester.pumpWidget(
      StartupErrorScope(
        error: StateError('unable to open database file'),
        dbPath: 'C:\\Users\\demo\\Documents\\timecalc.sqlite',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据无法打开'), findsOneWidget);
    expect(find.textContaining('本地数据库打开失败'), findsOneWidget);
    expect(
      find.textContaining('C:\\Users\\demo\\Documents\\timecalc.sqlite'),
      findsOneWidget,
    );
    expect(find.textContaining('从之前的 TimeCalc 备份'), findsOneWidget);
    expect(find.text('导出诊断信息'), findsOneWidget);
  });

  testWidgets('启动错误屏导出诊断走假选择器并提示成功', (tester) async {
    final picker = _FakeDiagnosticsPicker();
    await tester.pumpWidget(
      StartupErrorScope(
        error: StateError('boom'),
        picker: picker,
      ),
    );
    await tester.pumpAndSettle();

    // 导出包含真实文件 IO：整个点击链路放到 runAsync 的真实异步区执行，
    // 否则 fake async 下 IO 完成事件不会到达，SnackBar 不会出现。
    await tester.runAsync(() async {
      await tester.tap(find.text('导出诊断信息'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(find.textContaining('诊断信息已导出'), findsOneWidget);
  });
}

class _FakeDiagnosticsPicker implements DiagnosticsFilePicker {
  int calls = 0;

  @override
  Future<File?> saveDiagnosticsFile() async {
    calls++;
    return File('${Directory.systemTemp.path}${Platform.pathSeparator}diag.txt');
  }
}
