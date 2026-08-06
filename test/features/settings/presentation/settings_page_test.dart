import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/backup/data/backup_file_picker.dart';

/// 设置页 Widget 测试（FR-8.1 关闭行为 / FR-9 备份与恢复入口）。
///
/// 固定时钟 2026-08-05，验证：
/// - 关闭行为分段选择与保存写库（FR-8.1）
/// - 备份与恢复入口存在（FR-9.1）
/// - 文件选择器以假实现注入，不触碰平台对话框
void main() {
  late AppDatabase db;
  late DateTime fixedNow;
  late FakeBackupFilePicker picker;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
          backupFilePickerProvider.overrideWithValue(picker),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fixedNow = DateTime(2026, 8, 5, 12);
    picker = FakeBackupFilePicker();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('设置页展示关闭行为与备份恢复入口（FR-8.1 / FR-9.1）', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    expect(find.text('关闭行为'), findsOneWidget);
    expect(find.text('直接退出'), findsOneWidget);
    expect(find.text('最小化到托盘'), findsOneWidget);

    // 备份区在列表下方，滚动后再断言。
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('从备份恢复'), findsOneWidget);
  });

  testWidgets('切换关闭行为为「最小化到托盘」并保存写库（FR-8.1）', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    // 关闭行为区在计划偏好区下方，先滚动到可见再操作。
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最小化到托盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    // 写库成功（SnackBar 提示）。
    expect(find.text('关闭行为已保存'), findsOneWidget);
    final settings = await db.select(db.settings).getSingle();
    expect(settings.closeBehavior, 'minimize_to_tray');
  });
}

/// 假文件选择器：记录调用，返回空（取消），避免触碰平台对话框。
class FakeBackupFilePicker implements BackupFilePicker {
  int saveCalls = 0;
  int openCalls = 0;

  @override
  Future<File?> saveBackupFile() async {
    saveCalls++;
    return null;
  }

  @override
  Future<File?> openBackupFile() async {
    openCalls++;
    return null;
  }
}
