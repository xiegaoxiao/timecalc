import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/calendar_io/data/ics_export_service.dart';
import 'package:timecalc/features/calendar_io/data/ics_file_picker.dart';
import 'package:timecalc/features/calendar_io/domain/ics_codec.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/milestone_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// 假文件选择器：返回固定路径（或 null 模拟取消）。
class _FakeIcsFilePicker implements IcsFilePicker {
  _FakeIcsFilePicker(this.file);

  final File? file;
  int calls = 0;
  String? suggestedName;

  @override
  Future<File?> saveIcsFile({String? suggestedName}) async {
    calls++;
    this.suggestedName = suggestedName;
    return file;
  }
}

/// 日历导出服务测试：读库 → 生成 .ics → 写盘。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late TaskRepository tasks;
  late MilestoneRepository milestones;
  late Directory tempDir;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    tasks = TaskRepository(db);
    milestones = MilestoneRepository(db);
    tempDir = Directory.systemTemp.createTempSync('timecalc-ics-export-test');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('导出未归档任务与全部里程碑为可解析的 .ics 文件', () async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(
      goalId: goal.id,
      title: '高数：三重积分',
      plannedDate: '2026-08-06',
      startTime: '08:30',
      estimatedMinutes: 180,
    );
    await tasks.create(
      goalId: goal.id,
      title: '复盘',
      plannedDate: '2026-08-07',
    );
    await milestones.create(
      goalId: goal.id,
      title: '强化阶段',
      date: '2026-08-20',
    );

    final file = File('${tempDir.path}${Platform.pathSeparator}out.ics');
    final picker = _FakeIcsFilePicker(file);
    final service = IcsExportService(
      tasks: tasks,
      milestones: milestones,
      picker: picker,
    );

    final result = await service.export(calendarName: 'TimeCalc 计划');

    expect(picker.calls, 1);
    expect(result, isNotNull);
    expect(result!.eventCount, 3);
    expect(result.taskCount, 2);
    expect(result.milestoneCount, 1);
    expect(result.path, file.path);

    // 落盘内容可被自家解析器读回（含时刻与全天两类事件）。
    final parsed = const IcsCodec().parse(await file.readAsString());
    expect(parsed.name, 'TimeCalc 计划');
    expect(parsed.events.map((e) => e.summary).toSet(), {
      '高数：三重积分',
      '复盘',
      '强化阶段',
    });
    final timed = parsed.events.firstWhere((e) => e.summary == '高数：三重积分');
    expect(timed.startTime, '08:30');
    expect(timed.durationMinutes, 180);
  });

  test('归档任务不进日历', () async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    await tasks.create(goalId: goal.id, title: '已完成', plannedDate: '2026-08-06');
    await tasks.archiveAllActive(goal.id);

    final file = File('${tempDir.path}${Platform.pathSeparator}out.ics');
    final service = IcsExportService(
      tasks: tasks,
      milestones: milestones,
      picker: _FakeIcsFilePicker(file),
    );

    final result = await service.export();
    expect(result!.eventCount, 0);
    expect(await file.readAsString(), contains('BEGIN:VCALENDAR'));
  });

  test('用户取消选择路径时不写文件', () async {
    final picker = _FakeIcsFilePicker(null);
    final service = IcsExportService(
      tasks: tasks,
      milestones: milestones,
      picker: picker,
    );

    expect(await service.export(), isNull);
    expect(picker.calls, 1);
  });
}
