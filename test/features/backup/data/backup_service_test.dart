import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/tables.dart';
import 'package:timecalc/features/backup/data/backup_manifest.dart';
import 'package:timecalc/features/backup/data/backup_service.dart';
import 'package:timecalc/features/goals/data/goal_repository.dart';
import 'package:timecalc/features/goals/data/milestone_repository.dart';
import 'package:timecalc/features/goals/data/subject_repository.dart';
import 'package:timecalc/features/tasks/data/checklist_item_repository.dart';
import 'package:timecalc/features/tasks/data/task_repository.dart';

/// BackupService 内存数据库测试（FR-9.1 / FR-9.2 / FR-9.3，NFR-2）。
///
/// 覆盖：
/// - 导出 → 修改数据 → 恢复 → 数据一致（FR-9 验收演练）；
/// - 合并恢复：去重与追加，不动当前设置；
/// - 覆盖恢复：先创建安全副本，再原子替换，失败回滚原库可用；
/// - 损坏/版本不匹配文件被拒且原库不变。
void main() {
  late AppDatabase db;
  late GoalRepository goals;
  late SubjectRepository subjects;
  late TaskRepository tasks;
  late MilestoneRepository milestones;
  late ChecklistItemRepository checklist;
  late BackupService backup;
  late Directory tempDir;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    goals = GoalRepository(db);
    subjects = SubjectRepository(db);
    tasks = TaskRepository(db);
    milestones = MilestoneRepository(db);
    checklist = ChecklistItemRepository(db);
    backup = BackupService(db);
    tempDir = Directory.systemTemp.createTempSync('timecalc-backup-test');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File tempFile(String name) => File('${tempDir.path}${Platform.pathSeparator}$name');

  /// 造一份含目标/科目/任务/模板/里程碑的基础数据。
  Future<void> seedBaseData() async {
    final goal = await goals.create(title: '考研', deadlineDate: '2026-12-31');
    final subject = await subjects.create(
      goalId: goal.id,
      name: '数学',
      color: '#112233',
    );
    final created = await tasks.create(
      goalId: goal.id,
      subjectId: subject.id,
      title: '完成第一章',
      plannedDate: '2026-08-05',
      estimatedMinutes: 120,
    );
    await tasks.setDone(created.id, true);
    // 里程碑（FR-2，schema v7）：进入业务备份。
    await milestones.create(
      goalId: goal.id,
      title: '完成一轮复习',
      date: '2026-09-30',
    );
    // 检查项（FR-4.1，schema v8）：挂到已完成任务上，进入业务备份。
    await checklist.create(taskId: created.id, title: '背诵并默写');
  }

  /// 目标下的未归档任务。
  Future<List<Task>> tasksFor(int goalId) => tasks.byGoal(goalId);

  group('导出与恢复演练（FR-9 验收）', () {
    test('导出 → 修改数据 → 覆盖恢复 → 数据一致', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);
      expect(await file.exists(), isTrue);

      // 修改当前数据：删除目标（连带任务）。
      final goal = (await goals.watchAll()).single;
      await goals.deleteWithCascade(goal.id);

      // 覆盖恢复前自动创建安全副本。
      final safety = await backup.restoreBackup(
        file,
        mode: RestoreMode.overwrite,
      );
      expect(safety, isNotNull);
      expect(await safety!.exists(), isTrue);

      // 数据与备份一致。
      final restoredGoals = await goals.watchAll();
      expect(restoredGoals.single.title, '考研');
      final restoredTasks = await tasks.byGoal(restoredGoals.single.id);
      expect(restoredTasks.single.title, '完成第一章');
      expect(restoredTasks.single.status, 'done');
      expect(restoredTasks.single.estimatedMinutes, 120);
      // 里程碑随备份覆盖恢复。
      final restoredMilestones = await milestones.byGoal(restoredGoals.single.id);
      expect(restoredMilestones.single.title, '完成一轮复习');
      expect(restoredMilestones.single.date, '2026-09-30');
      expect(restoredMilestones.single.status, MilestoneStatus.todo);
      // 检查项随备份覆盖恢复（FR-4.1，schema v8）。
      final restoredItems = await checklist.byTask(restoredTasks.single.id);
      expect(restoredItems.single.title, '背诵并默写');
      expect(restoredItems.single.done, isFalse);
    });

    test('导出 → 合并恢复 → 备份数据追加且当前数据保留', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 当前新增一个不同的目标。
      await goals.create(title: '论文', deadlineDate: '2026-09-30');

      await backup.restoreBackup(file, mode: RestoreMode.merge);

      final allGoals = await goals.watchAll();
      expect(allGoals.map((g) => g.title).toSet(), {'考研', '论文'});
      // 备份中的考研目标与其任务都在（任务为追加语义，不做内容去重）。
      final goalById = {for (final g in allGoals) g.title: g};
      final tasks = await tasksFor(goalById['考研']!.id);
      expect(tasks.map((t) => t.title), contains('完成第一章'));
    });

    test('合并恢复：备份中已存在的目标按（标题,截止日,状态）去重不重复插入', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 再次合并同一份备份：目标不重复，任务按追加语义再写一份。
      await backup.restoreBackup(file, mode: RestoreMode.merge);

      final allGoals = await goals.watchAll();
      expect(allGoals, hasLength(1));
      final tasks = await tasksFor(allGoals.single.id);
      expect(tasks, hasLength(2));
    });

    test('合并恢复：备份中的里程碑追加到映射后的目标下（FR-2/FR-9.1）', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 备份到另一份空库（合并模式）：里程碑随目标映射写入新目标 id。
      final db2 = AppDatabase(NativeDatabase.memory());
      final backup2 = BackupService(db2);
      final milestones2 = MilestoneRepository(db2);
      try {
        await backup2.restoreBackup(file, mode: RestoreMode.merge);

        final goal = (await db2.select(db2.goals).get()).single;
        final restored = await milestones2.byGoal(goal.id);
        expect(restored.single.title, '完成一轮复习');
        expect(restored.single.date, '2026-09-30');
      } finally {
        await db2.close();
      }
    });

    test('合并恢复：检查项随任务 id 映射追加到新任务下（FR-4.1/FR-9.1）', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 备份到另一份空库（合并模式）：任务获得新 id，检查项须映射到新任务。
      final db2 = AppDatabase(NativeDatabase.memory());
      final backup2 = BackupService(db2);
      final tasks2 = TaskRepository(db2);
      final checklist2 = ChecklistItemRepository(db2);
      try {
        await backup2.restoreBackup(file, mode: RestoreMode.merge);

        final goal = (await db2.select(db2.goals).get()).single;
        final restoredTask = (await tasks2.byGoal(goal.id)).single;
        final items = await checklist2.byTask(restoredTask.id);
        expect(items.single.title, '背诵并默写');
        expect(items.single.done, isFalse);
      } finally {
        await db2.close();
      }
    });
  });

  group('覆盖恢复（FR-9.3）', () {
    test('覆盖恢复前自动创建当前数据安全副本（FR-9.3）', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 造一点「当前」独有的数据，备份里没有。
      await goals.create(title: '当前独有', deadlineDate: '2026-10-01');

      final safety = await backup.restoreBackup(file, mode: RestoreMode.overwrite);
      expect(safety, isNotNull);
      expect(await safety!.exists(), isTrue);

      // 安全副本包含「当前独有」目标（导出的当前快照）。
      final safetyBackup = BackupService(db);
      final safetyManifest = await safetyBackup.readBackupManifest(safety);
      expect(safetyManifest.goalCount, 2);
    });

    test('覆盖恢复失败时原库保持可用（NFR-2）', () async {
      await seedBaseData();
      // 构造一个校验失败的备份：版本不匹配。
      final badFile = tempFile('bad-version.timecalc');
      await badFile.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(ArchiveFile.string(
              'manifest.json',
              '{"format":"timecalc-backup","version":999,"type":"full",'
              '"exportedAtUtc":"2026-01-01T00:00:00.000Z","appSchemaVersion":6,'
              '"appVersion":"1.2.0","counts":{"goals":0,"subjects":0,"tasks":0,'
              '"recurrenceTemplates":0}}',
            )),
        ),
      );

      await expectLater(
        backup.restoreBackup(badFile, mode: RestoreMode.overwrite),
        throwsA(isA<BackupException>()),
      );

      // 原库未被破坏。
      final allGoals = await goals.watchAll();
      expect(allGoals.single.title, '考研');
      final tasks = await tasksFor(allGoals.single.id);
      expect(tasks.single.title, '完成第一章');
    });
  });

  group('读取与校验（FR-9.2 / NFR-2）', () {
    test('readBackupManifest 返回备份时间与计数供恢复前展示', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      final manifest = await backup.readBackupManifest(file);
      expect(manifest.format, BackupFormat.format);
      expect(manifest.version, BackupFormat.version);
      expect(manifest.goalCount, 1);
      expect(manifest.taskCount, 1);
      expect(manifest.subjectCount, 1);
      expect(manifest.milestoneCount, 1);
      expect(manifest.checklistItemCount, 1);
      expect(manifest.validate(), isNull);
    });

    test('损坏文件被拒绝且不触碰数据库', () async {
      await seedBaseData();
      final bad = tempFile('corrupt.timecalc');
      await bad.writeAsString('不是 zip 文件');

      await expectLater(
        backup.readBackupManifest(bad),
        throwsA(isA<BackupException>()),
      );

      // 数据库未被改动。
      final allGoals = await goals.watchAll();
      expect(allGoals.single.title, '考研');
    });

    test('manifest 计数与数据不一致时拒绝恢复', () async {
      await seedBaseData();
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 篡改 manifest：声明 taskCount 为 99（实际 1）。
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final manifestEntry = archive.findFile('manifest.json')!;
      final manifestJson = String.fromCharCodes(manifestEntry.content as List<int>)
          .replaceFirst('"tasks":1', '"tasks":99');
      final tampered = Archive()
        ..addFile(ArchiveFile.string('manifest.json', manifestJson));
      for (final entry in archive) {
        if (entry.name == 'manifest.json') continue;
        tampered.addFile(ArchiveFile.bytes(
          entry.name,
          entry.content as List<int>,
        ));
      }
      final tamperedFile = tempFile('tampered.timecalc');
      await tamperedFile.writeAsBytes(ZipEncoder().encodeBytes(tampered));

      await expectLater(
        backup.restoreBackup(tamperedFile, mode: RestoreMode.merge),
        throwsA(isA<BackupException>()),
      );
      // 原库仍可用。
      final allGoals = await goals.watchAll();
      expect(allGoals.single.title, '考研');
    });

    test('数据数组含非对象元素时拒绝恢复且不触碰数据库', () async {
      await seedBaseData();
      // 导出后篡改 tasks.json：数组元素改为非对象（数字）。保持元素个数为 1
      // 与 manifest 计数一致，确保走到「元素类型校验」而非「计数不一致」。
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final tampered = Archive();
      for (final entry in archive) {
        if (entry.name == 'data/tasks.json') {
          tampered.addFile(ArchiveFile.string('data/tasks.json', '[42]'));
        } else {
          tampered.addFile(ArchiveFile.bytes(
            entry.name,
            entry.content as List<int>,
          ));
        }
      }
      final tamperedFile = tempFile('bad-element.timecalc');
      await tamperedFile.writeAsBytes(ZipEncoder().encodeBytes(tampered));

      await expectLater(
        backup.restoreBackup(tamperedFile, mode: RestoreMode.overwrite),
        throwsA(isA<BackupException>()),
      );
      // 原库未被破坏（此前类型错误元素会抛 TypeError 静默失败）。
      final allGoals = await goals.watchAll();
      expect(allGoals.single.title, '考研');
      final restoredTasks = await tasksFor(allGoals.single.id);
      expect(restoredTasks.single.title, '完成第一章');
    });

    test('数据文件顶层不是数组时拒绝恢复（损坏清单也拒绝）', () async {
      await seedBaseData();
      // 篡改 goals.json：顶层为对象而非数组。
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final tampered = Archive();
      for (final entry in archive) {
        if (entry.name == 'data/goals.json') {
          tampered.addFile(ArchiveFile.string(
            'data/goals.json',
            '{"title":"不是数组"}',
          ));
        } else {
          tampered.addFile(ArchiveFile.bytes(
            entry.name,
            entry.content as List<int>,
          ));
        }
      }
      final tamperedFile = tempFile('bad-shape.timecalc');
      await tamperedFile.writeAsBytes(ZipEncoder().encodeBytes(tampered));

      await expectLater(
        backup.restoreBackup(tamperedFile, mode: RestoreMode.overwrite),
        throwsA(isA<BackupException>()),
      );
      final allGoals = await goals.watchAll();
      expect(allGoals.single.title, '考研');
    });
  });

  group('设置备份（FR-9.5）', () {
    test('备份包含计划偏好，不包含窗口/关闭行为等桌面状态', () async {
      await seedBaseData();
      // 修改计划偏好与关闭行为。
      await db.into(db.settings).insertOnConflictUpdate(
            SettingsCompanion.insert(
              id: const Value(1),
              dailyAvailableMinutes: const Value(90),
              availableWeekdays: const Value('1,3,5'),
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );

      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 解包检查 settings.json：只含计划偏好，不含 close_behavior。
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final settingsEntry = archive.findFile('data/settings.json')!;
      final settingsJson = String.fromCharCodes(
        settingsEntry.content as List<int>,
      );
      expect(settingsJson, contains('dailyAvailableMinutes'));
      expect(settingsJson, contains('availableWeekdays'));
      expect(settingsJson, isNot(contains('close_behavior')));
    });

    test('覆盖恢复时设置随备份恢复（计划偏好）', () async {
      await seedBaseData();
      // 当前设置为 90 分钟。
      await db.into(db.settings).insertOnConflictUpdate(
            SettingsCompanion.insert(
              id: const Value(1),
              dailyAvailableMinutes: const Value(90),
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 覆盖恢复：设置恢复为备份中的 90 分钟。
      await backup.restoreBackup(file, mode: RestoreMode.overwrite);
      final settings = await db.select(db.settings).getSingle();
      expect(settings.dailyAvailableMinutes, 90);
    });

    test('覆盖恢复后关闭行为 close_behavior 被保留（P1-3 回归）', () async {
      await seedBaseData();
      // 当前关闭行为设为「最小化到托盘」；备份文件不含该字段（FR-9.5）。
      await db.into(db.settings).insertOnConflictUpdate(
            SettingsCompanion.insert(
              id: const Value(1),
              closeBehavior: const Value(CloseBehavior.minimizeToTray),
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      final file = tempFile('backup.timecalc');
      await backup.exportBackup(file);

      // 覆盖恢复：业务数据被替换，但桌面层关闭行为不被重置为默认 exit。
      await backup.restoreBackup(file, mode: RestoreMode.overwrite);
      final settings = await db.select(db.settings).getSingle();
      expect(settings.closeBehavior, CloseBehavior.minimizeToTray);
    });
  });
}
