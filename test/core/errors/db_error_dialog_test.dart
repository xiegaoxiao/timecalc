import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/errors/diagnostics_service.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository_provider.dart';

import '../../shared/nav_helper.dart';

/// 数据库写入异常对话框测试（PRD §8：停止继续写入，提示恢复或导出诊断）。
///
/// override 一个 `setDone` 必抛异常的 TaskRepository → 在「计划」页选日面板
/// 点完成（该处为即时写入路径）→ 断言「数据保存失败」对话框出现、任务状态
/// 未变（未写入）、导出诊断/前往恢复入口存在。
/// （今天页勾选已改走 5 秒撤回批次，不立即写库，故错误守卫在此验证。）
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late _FailingTaskRepository tasks;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          taskRepositoryProvider.overrideWithValue(tasks),
          clockProvider.overrideWithValue(() => fixedNow),
          // 导出诊断选择器/服务以假实现注入，不触碰平台对话框。
          diagnosticsFilePickerProvider.overrideWithValue(_FakeDiagnosticsPicker()),
          diagnosticsServiceProvider.overrideWithValue(DiagnosticsService(db)),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = _FailingTaskRepository(db);
    fixedNow = DateTime(2026, 8, 5, 12);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('任务完成写入失败：弹出「数据保存失败」，未写入，提供恢复/诊断入口', (tester) async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '背单词',
      plannedDate: '2026-08-05',
      estimatedMinutes: 90,
    );

    await pumpApp(tester);

    // 「计划」页选日面板的勾选为即时写入路径：点完成 → setDone 抛异常 →
    // 弹数据库错误对话框。（今天页已改走 5 秒撤回批次，不在此路径上。）
    await tapNavDestination(tester, '计划');
    final checkbox = find.byType(Checkbox);
    await tester.ensureVisible(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    expect(find.text('数据保存失败'), findsOneWidget);
    expect(find.textContaining('本次写入未生效'), findsOneWidget);
    expect(find.text('导出诊断信息'), findsOneWidget);
    expect(find.text('前往备份恢复'), findsOneWidget);

    // 任务状态未变（事务未提交，无半条写入，NFR-2）。
    final fetched = await db.select(db.tasks).getSingle();
    expect(fetched.status, 'todo');

    // 关闭对话框后应用仍可用（回到今天页）。
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('数据保存失败'), findsNothing);
    await tapNavDestination(tester, '今天');
    expect(find.text('背单词'), findsOneWidget);
  });
}

/// setDone 必抛异常的 TaskRepository（模拟数据库写入失败）。
class _FailingTaskRepository extends TaskRepository {
  _FailingTaskRepository(super.db);

  @override
  Future<void> setDone(int id, bool done) async {
    throw StateError('模拟数据库写入失败');
  }
}

/// 记录导出调用的假文件选择器：返回固定路径，不触碰平台对话框。
class _FakeDiagnosticsPicker implements DiagnosticsFilePicker {
  int calls = 0;

  @override
  Future<File?> saveDiagnosticsFile() async {
    calls++;
    return File('${Directory.systemTemp.path}${Platform.pathSeparator}diag.txt');
  }
}
