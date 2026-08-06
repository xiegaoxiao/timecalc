import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/app_version.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/errors/diagnostics_service.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 诊断信息服务测试（PRD §8：导出诊断信息）。
///
/// 验证：
/// - 导出文件包含应用版本、schema 版本、各表行数与错误日志；
/// - 错误捕获写入内存日志（供对话框「导出诊断信息」读取）；
/// - 无数据库连接时（启动失败场景）导出跳过数据段落且不抛异常。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('导出诊断文件包含版本/schema/行数与错误日志', () async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    final service = DiagnosticsService(db);
    service.capture('测试错误', StackTrace.current);

    final file = File(
      '${Directory.systemTemp.createTempSync('diag').path}${Platform.pathSeparator}diag.txt',
    );
    await service.exportDiagnostics(file);

    final content = await file.readAsString();
    expect(content, contains('TimeCalc 诊断信息'));
    expect(content, contains('应用版本：$kAppVersion'));
    expect(content, contains('数据库 schema 版本：8'));
    expect(content, contains('goals: 1'));
    expect(content, contains('tasks: 1'));
    expect(content, contains('milestones: 0'));
    expect(content, contains('测试错误'));
  });

  test('错误捕获写入内存日志，供对话框导出', () {
    final service = DiagnosticsService(db);
    expect(service.recentErrors, isEmpty);
    service.capture('数据库写入失败');
    service.capture('另一个错误');
    expect(service.recentErrors, hasLength(2));
    expect(service.recentErrors.first, contains('数据库写入失败'));
  });

  test('无数据库连接时导出不抛异常（启动失败场景）', () async {
    final service = DiagnosticsService(); // db 为 null
    final file = File(
      '${Directory.systemTemp.createTempSync('diag2').path}${Platform.pathSeparator}diag.txt',
    );
    await service.exportDiagnostics(file);
    final content = await file.readAsString();
    expect(content, contains('数据库不可用'));
    expect(content, contains('（数据库未打开）'));
  });
}
