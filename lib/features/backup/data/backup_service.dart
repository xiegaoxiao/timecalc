import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';

import '../../../../core/app_version.dart';
import '../../../../core/database/database.dart';
import 'backup_codec.dart';
import 'backup_manifest.dart';

/// 备份/恢复异常：校验或执行失败，携带用户可读的原因。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份数据包（解包并校验后的结果，供恢复执行）。
class BackupPayload {
  const BackupPayload({
    required this.manifest,
    required this.goals,
    required this.subjects,
    required this.tasks,
    required this.templates,
    required this.milestones,
    required this.checklistItems,
    required this.settings,
  });

  final BackupManifest manifest;
  final List<Map<String, Object?>> goals;
  final List<Map<String, Object?>> subjects;
  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> templates;
  final List<Map<String, Object?>> milestones;
  final List<Map<String, Object?>> checklistItems;
  final List<Map<String, Object?>> settings;
}

/// 手动备份/恢复服务（FR-9.1 / FR-9.2 / FR-9.3，NFR-2）。
///
/// 备份文件为 zip（扩展名 `.timecalc`），内部结构：
/// - `manifest.json`：格式/版本/类型/导出时间/计数；
/// - `data/goals.json`、`data/subjects.json`、`data/tasks.json`、
///   `data/recurrence_templates.json`、`data/milestones.json`、
///   `data/checklist_items.json`、`data/settings.json`（配置目录）。
///
/// 恢复流程（NFR-2：先校验后写入，失败保持原库可用）：
/// 1. 解包并校验格式、版本、类型、计数与数组长度一致；
/// 2. 合并模式：单事务内以新 ID 追加，目标/科目按键去重，不动当前设置；
/// 3. 覆盖模式：先自动导出当前数据到安全副本（FR-9.3），再单事务清空
///    业务表并写入备份数据（settings 一并恢复）；失败回滚。
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  static const _codec = BackupCodec();

  static const _manifestPath = 'manifest.json';
  static const _dataDir = 'data/';
  static const _defaultFileName = 'timecalc-backup';

  /// 导出全部业务数据为带版本号的备份文件（FR-9.1）。
  ///
  /// 在单个事务内读取全部业务表（快照一致），打包 zip 写入 [targetFile]。
  Future<void> exportBackup(File targetFile) async {
    final snapshot = await _db.transaction(() async {
      final goals = await _db.select(_db.goals).get();
      final subjects = await _db.select(_db.subjects).get();
      final tasks = await _db.select(_db.tasks).get();
      final templates = await _db.select(_db.recurrenceTemplates).get();
      final milestones = await _db.select(_db.milestones).get();
      final checklistItems = await _db.select(_db.checklistItems).get();
      final settings = await _db.select(_db.settings).get();
      return (
        goals: goals,
        subjects: subjects,
        tasks: tasks,
        templates: templates,
        milestones: milestones,
        checklistItems: checklistItems,
        settings: settings,
      );
    });

    final manifest = BackupManifest(
      format: BackupFormat.format,
      version: BackupFormat.version,
      type: BackupType.full,
      exportedAtUtc: DateTime.now().toUtc(),
      appSchemaVersion: _db.schemaVersion,
      appVersion: kAppVersion,
      goalCount: snapshot.goals.length,
      subjectCount: snapshot.subjects.length,
      taskCount: snapshot.tasks.length,
      recurrenceTemplateCount: snapshot.templates.length,
      milestoneCount: snapshot.milestones.length,
      checklistItemCount: snapshot.checklistItems.length,
    );

    final archive = Archive()
      ..addFile(ArchiveFile.string(
        _manifestPath,
        jsonEncode(manifest.toJson()),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('goals')}',
        jsonEncode(snapshot.goals.map(_codec.goalToJson).toList()),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('subjects')}',
        jsonEncode(snapshot.subjects.map(_codec.subjectToJson).toList()),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('tasks')}',
        jsonEncode(snapshot.tasks.map(_codec.taskToJson).toList()),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('recurrence_templates')}',
        jsonEncode(snapshot.templates.map(_codec.templateToJson).toList()),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('milestones')}',
        jsonEncode(snapshot.milestones.map(_codec.milestoneToJson).toList()),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('checklist_items')}',
        jsonEncode(
          snapshot.checklistItems.map(_codec.checklistItemToJson).toList(),
        ),
      ))
      ..addFile(ArchiveFile.string(
        '$_dataDir${_jsonFileName('settings')}',
        jsonEncode(snapshot.settings.map(_codec.settingsToJson).toList()),
      ));

    final bytes = ZipEncoder().encodeBytes(archive);
    await targetFile.writeAsBytes(bytes);
  }

  /// 读取并校验备份文件清单（FR-9.2 恢复前展示摘要）。
  ///
  /// 只读操作，不触碰当前数据库。格式/版本/类型不合法时抛 [BackupException]。
  Future<BackupManifest> readBackupManifest(File file) async {
    final payload = await _unpack(file);
    return payload.manifest;
  }

  /// 恢复备份（FR-9.2 / FR-9.3）。
  ///
  /// [merge] 为 true 时执行「合并」，否则执行「覆盖」。返回覆盖模式
  /// 创建的安全副本文件路径（合并模式返回 null，供 UI 提示用户）。
  Future<File?> restoreBackup(File file, {required RestoreMode mode}) async {
    try {
      // 第一步：完整校验（格式/版本/类型/计数/解析），校验失败不写任何数据。
      final payload = await _unpack(file);
      final validationError = payload.manifest.validate();
      if (validationError != null) {
        throw BackupException(validationError);
      }
      // schema 版本守卫（M13）：备份由**更新版本**应用创建时拒绝恢复，
      // 避免旧应用以缺列/未知字段语义读坏数据（同步路径已有同款守卫，
      // 手动恢复此前缺失）。等版本或更旧版本的备份允许恢复。
      if (payload.manifest.appSchemaVersion > _db.schemaVersion) {
        throw BackupException(
          '备份由更新版本的应用创建（schema ${payload.manifest.appSchemaVersion}），'
          '请先升级应用再恢复',
        );
      }

      switch (mode) {
        case RestoreMode.merge:
          await _mergeRestore(payload);
          return null;
        case RestoreMode.overwrite:
          // FR-9.3：覆盖前自动创建当前数据的安全副本。
          final safety = await exportSafetyCopy();
          await _overwriteRestore(payload);
          return safety;
      }
    } on BackupException {
      rethrow;
    } on Error catch (error) {
      // 数据段字段类型损坏（如 title 非字符串）时 codec 强转会抛
      // TypeError（Error 而非 Exception），UI 的 `on Exception` 捕不到，
      // 会造成恢复静默失败。统一转为 BackupException（事务已回滚，
      // 原库保持可用，NFR-2）。
      throw BackupException('备份数据内容不正确（$error）');
    }
  }

  /// 创建当前数据的安全副本（FR-9.3），返回副本文件。
  ///
  /// 副本保存到系统临时目录，命名 `safety-<时间戳>.timecalc`。
  /// 每次创建前清扫 7 天前的 `timecalc-safety-*` 目录（M11）：覆盖恢复/
  /// 同步拉取/重置数据都会在此留副本，若不清理会随使用持续累积。
  Future<File> exportSafetyCopy() async {
    await _sweepStaleSafetyDirs();
    final dir = await Directory.systemTemp.createTemp('timecalc-safety');
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final file = File('${dir.path}${Platform.pathSeparator}safety-$stamp.timecalc');
    await exportBackup(file);
    return file;
  }

  /// 清扫系统临时目录中 7 天前创建的 `timecalc-safety-*` 目录。
  ///
  /// 尽力而为：目录已被删除/无权访问时静默跳过（不阻断安全副本创建）。
  static Future<void> _sweepStaleSafetyDirs() async {
    try {
      final temp = Directory.systemTemp;
      await for (final entity in temp.list()) {
        if (entity is! Directory) continue;
        if (!entity.uri.pathSegments.last.startsWith('timecalc-safety')) continue;
        try {
          final stat = await entity.stat();
          final age = DateTime.now().difference(stat.modified);
          if (age > const Duration(days: 7)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {
          // 单个目录清理失败不影响其余。
        }
      }
    } catch (_) {
      // 系统临时目录不可枚举时跳过（尽力而为）。
    }
  }

  /// 重置全部业务数据（设置页「重置数据」，FR-9 数据管理扩展）。
  ///
  /// 重置前先自动创建当前数据的安全副本（FR-9.3 同款语义），随后在单个
  /// 事务内按子表→父表清空全部业务表（checklist_items → tasks →
  /// recurrence_templates → milestones → subjects → goals），返回副本路径
  /// 供 UI 提示。
  ///
  /// [includeSettings] 为 true 时额外删除 settings 单行——完全恢复出厂，
  /// 设置由 [SettingsRepository.get] 惰性重建默认值（同步/自动备份关闭、
  /// 主题跟随系统、计划偏好默认），WebDAV 远端副本保留为安全网，不会被
  /// 空库覆盖、也不会被旧数据拉回；为 false 时仅清空业务数据，设置与
  /// 运行时配置（含同步开关）保持不变。
  Future<File> resetData({required bool includeSettings}) async {
    final safety = await exportSafetyCopy();
    await _db.transaction(() async {
      await _db.delete(_db.checklistItems).go();
      await _db.delete(_db.tasks).go();
      await _db.delete(_db.recurrenceTemplates).go();
      await _db.delete(_db.milestones).go();
      await _db.delete(_db.subjects).go();
      await _db.delete(_db.goals).go();
      if (includeSettings) {
        await _db.delete(_db.settings).go();
      }
    });
    return safety;
  }

  /// 合并模式：单事务追加备份数据。
  ///
  /// - 目标按 (title, deadlineDate, status) 去重：已存在则复用，任务挂到
  ///   已有目标；否则插入并建立旧 ID → 新 ID 映射。
  /// - 科目按 (goalId, name) 去重（goalId 已映射到当前库）。
  /// - 任务与重复模板追加写入，外键经映射转换。
  /// - 计划偏好不合并（当前设置保持不变）。
  Future<void> _mergeRestore(BackupPayload payload) async {
    await _db.transaction(() async {
      // 已有目标按去重键索引。
      final existingGoals = await _db.select(_db.goals).get();
      final goalKeyToId = <String, int>{
        for (final g in existingGoals) _goalKey(g.title, g.deadlineDate, g.status): g.id,
      };
      final oldGoalToNew = <int, int>{};

      for (final json in payload.goals) {
        final title = json['title'] as String;
        final deadline = json['deadlineDate'] as String;
        final status = json['status'] as String? ?? 'active';
        final existingId = goalKeyToId[_goalKey(title, deadline, status)];
        final goalId = existingId ??
            await _db.into(_db.goals).insert(_codec.goalFromJson(json));
        oldGoalToNew[json['id'] as int] = goalId;
        goalKeyToId[_goalKey(title, deadline, status)] = goalId;
      }

      // 科目：按 (新 goalId, name) 去重。
      final existingSubjects = await _db.select(_db.subjects).get();
      final subjectKeyToId = <String, int>{
        for (final s in existingSubjects) _subjectKey(s.goalId, s.name): s.id,
      };
      final oldSubjectToNew = <int, int>{};
      for (final json in payload.subjects) {
        final newGoalId = oldGoalToNew[json['goalId'] as int];
        if (newGoalId == null) continue; // 目标不在备份目标列表，跳过该科目。
        final name = json['name'] as String;
        final existingId = subjectKeyToId[_subjectKey(newGoalId, name)];
        final subjectId = existingId ??
            await _db.into(_db.subjects).insert(
                  _codec.subjectFromJson(json, goalId: newGoalId),
                );
        oldSubjectToNew[json['id'] as int] = subjectId;
        subjectKeyToId[_subjectKey(newGoalId, name)] = subjectId;
      }

      // 里程碑：追加（FR-2，schema v7），goalId 经目标映射转换。
      for (final json in payload.milestones) {
        final newGoalId = oldGoalToNew[json['goalId'] as int];
        if (newGoalId == null) continue; // 目标不在备份目标列表，跳过该里程碑。
        await _db.into(_db.milestones).insert(
              _codec.milestoneFromJson(json, goalId: newGoalId),
            );
      }

      // 重复模板：追加，外键映射。
      final oldTemplateToNew = <int, int>{};
      for (final json in payload.templates) {
        final newGoalId = oldGoalToNew[json['goalId'] as int];
        if (newGoalId == null) continue;
        final newSubjectId = json['subjectId'] == null
            ? null
            : oldSubjectToNew[json['subjectId'] as int];
        final templateId = await _db.into(_db.recurrenceTemplates).insert(
              _codec.templateFromJson(
                json,
                goalId: newGoalId,
                subjectId: newSubjectId,
              ),
            );
        oldTemplateToNew[json['id'] as int] = templateId;
      }

      // 任务：追加（含归档任务），外键映射。同时记录旧 id → 新 id 映射，
      // 供检查项（taskId 外键）转换。
      final oldTaskToNew = <int, int>{};
      for (final json in payload.tasks) {
        final newGoalId = oldGoalToNew[json['goalId'] as int];
        if (newGoalId == null) continue;
        final newSubjectId = json['subjectId'] == null
            ? null
            : oldSubjectToNew[json['subjectId'] as int];
        final templateId = json['recurrenceTemplateId'] == null
            ? null
            : oldTemplateToNew[json['recurrenceTemplateId'] as int];
        final taskId = await _db.into(_db.tasks).insert(
              _codec.taskFromJson(
                json,
                goalId: newGoalId,
                subjectId: newSubjectId,
                recurrenceTemplateId: templateId,
              ),
            );
        oldTaskToNew[json['id'] as int] = taskId;
      }

      // 检查项：追加（FR-4.1，schema v8），taskId 经任务映射转换。
      for (final json in payload.checklistItems) {
        final newTaskId = oldTaskToNew[json['taskId'] as int];
        if (newTaskId == null) continue; // 任务不在备份任务列表，跳过该检查项。
        await _db.into(_db.checklistItems).insert(
              _codec.checklistItemFromJson(json, taskId: newTaskId),
            );
      }
    });
  }

  /// 覆盖模式：单事务清空业务表并写入备份数据（settings 一并恢复）。
  ///
  /// 清空按子表→父表顺序（checklist_items → tasks → recurrence_templates →
  /// milestones → subjects → goals），写入按父表→子表顺序并保留原 ID，
  /// 保证外键一致。
  Future<void> _overwriteRestore(BackupPayload payload) async {
    await _db.transaction(() async {
      await _db.delete(_db.checklistItems).go();
      await _db.delete(_db.tasks).go();
      await _db.delete(_db.recurrenceTemplates).go();
      await _db.delete(_db.milestones).go();
      await _db.delete(_db.subjects).go();
      await _db.delete(_db.goals).go();

      for (final json in payload.goals) {
        await _db.into(_db.goals).insert(
              _codec.goalFromJson(json, keepId: true),
              mode: InsertMode.insertOrReplace,
            );
      }
      for (final json in payload.milestones) {
        final goalId = json['goalId'] as int;
        await _db.into(_db.milestones).insert(
              _codec.milestoneFromJson(json, goalId: goalId, keepId: true),
              mode: InsertMode.insertOrReplace,
            );
      }
      for (final json in payload.subjects) {
        final goalId = json['goalId'] as int;
        await _db.into(_db.subjects).insert(
              _codec.subjectFromJson(json, goalId: goalId, keepId: true),
              mode: InsertMode.insertOrReplace,
            );
      }
      for (final json in payload.templates) {
        final goalId = json['goalId'] as int;
        final subjectId = json['subjectId'] as int?;
        await _db.into(_db.recurrenceTemplates).insert(
              _codec.templateFromJson(
                json,
                goalId: goalId,
                subjectId: subjectId,
                keepId: true,
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
      for (final json in payload.tasks) {
        final goalId = json['goalId'] as int;
        final subjectId = json['subjectId'] as int?;
        final templateId = json['recurrenceTemplateId'] as int?;
        await _db.into(_db.tasks).insert(
              _codec.taskFromJson(
                json,
                goalId: goalId,
                subjectId: subjectId,
                recurrenceTemplateId: templateId,
                keepId: true,
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
      // 检查项（FR-4.1，schema v8）：覆盖模式保留原 ID，taskId 原样还原。
      for (final json in payload.checklistItems) {
        final taskId = json['taskId'] as int;
        await _db.into(_db.checklistItems).insert(
              _codec.checklistItemFromJson(json, taskId: taskId, keepId: true),
              mode: InsertMode.insertOrReplace,
            );
      }

      // 计划偏好：覆盖模式下随备份一并恢复（FR-9.2 覆盖语义）。
      if (payload.settings.isNotEmpty) {
        // 运行时配置不进备份文件（FR-9.5：关闭行为、自动备份配置；
        // 2026-08 移除 WebDAV/同步后不再有相应运行时字段），备份 JSON 中
        // 无这些字段。覆盖清空 settings 行会把它们重置为默认值，故在恢复
        // 前读取当前值并保留——桌面/备份行为不该被「数据恢复」意外改变。
        final previous = await _db.select(_db.settings).getSingleOrNull();
        final previousCloseBehavior = previous?.closeBehavior;
        final previousAutoBackupEnabled = previous?.autoBackupEnabled;
        final previousLocalBackupFolder = previous?.localBackupFolder;
        final previousLastAutoBackupAt = previous?.lastAutoBackupAt;
        final previousThemeMode = previous?.themeMode;
        await _db.delete(_db.settings).go();
        await _db.into(_db.settings).insert(
              _codec.settingsFromJson(
                payload.settings.first,
                // 若备份 JSON 里恰好携带了这些运行时字段（手工构造），
                // 优先用它，否则保留恢复前的当前值。
                closeBehavior: payload.settings.first['closeBehavior'] as String? ??
                    previousCloseBehavior,
                autoBackupEnabled: payload.settings.first['autoBackupEnabled'] as bool? ??
                    previousAutoBackupEnabled,
                localBackupFolder: payload.settings.first['localBackupFolder'] as String? ??
                    previousLocalBackupFolder,
                lastAutoBackupAt: payload.settings.first['lastAutoBackupAt'] == null
                    ? previousLastAutoBackupAt
                    : DateTime.tryParse(
                        payload.settings.first['lastAutoBackupAt'] as String,
                      ),
                themeMode: payload.settings.first['themeMode'] as String? ??
                    previousThemeMode,
              ),
            );
      } else {
        // L7：备份 settings 段为空（手工构造/异常备份）时，不删除当前
        // settings 行——避免计划偏好被静默重置为默认值。
        final existing = await _db.select(_db.settings).getSingleOrNull();
        if (existing != null) {
          await _db.into(_db.settings).insert(
                _codec.settingsFromJson(
                  {
                    'dailyAvailableMinutes': existing.dailyAvailableMinutes,
                    'availableWeekdays': existing.availableWeekdays,
                  },
                  closeBehavior: existing.closeBehavior,
                  autoBackupEnabled: existing.autoBackupEnabled,
                  localBackupFolder: existing.localBackupFolder,
                  lastAutoBackupAt: existing.lastAutoBackupAt,
                  themeMode: existing.themeMode,
                ),
                mode: InsertMode.insertOrReplace,
              );
        }
      }
    });
  }

  /// 解包备份文件：读 manifest 与全部数据 JSON，校验计数与数组长度。
  Future<BackupPayload> _unpack(File file) async {
    if (!await file.exists()) {
      throw const BackupException('备份文件不存在');
    }
    final bytes = await file.readAsBytes();

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw const BackupException('文件损坏或不是 TimeCalc 备份文件');
    }

    final manifestFile = archive.findFile(_manifestPath);
    if (manifestFile == null) {
      throw const BackupException('备份文件缺少清单（manifest.json）');
    }
    // manifest 顶层结构校验：损坏/非对象清单统一报 BackupException
    // （此前 `as Map` 在极端损坏时抛 TypeError，UI 的 on Exception 捕不到）。
    final Object? decodedManifest;
    try {
      decodedManifest = jsonDecode(_decodeUtf8(manifestFile.content as List<int>));
    } catch (_) {
      throw const BackupException('备份文件清单不是有效 JSON');
    }
    if (decodedManifest is! Map<String, Object?>) {
      throw const BackupException('备份文件清单格式不正确');
    }
    final manifest = BackupManifest.fromJson(decodedManifest);

    List<Map<String, Object?>> readJson(String name) {
      final entry = archive.findFile('$_dataDir$name');
      if (entry == null) throw BackupException('备份文件缺少 data/$name');
      return _readObjectList(
        _decodeDataJson(entry.content as List<int>, name),
        name,
      );
    }

    List<Map<String, Object?>> readJsonOptional(String name) {
      final entry = archive.findFile('$_dataDir$name');
      if (entry == null) return const [];
      return _readObjectList(
        _decodeDataJson(entry.content as List<int>, name),
        name,
      );
    }

    final goals = readJson(_jsonFileName('goals'));
    final subjects = readJson(_jsonFileName('subjects'));
    final tasks = readJson(_jsonFileName('tasks'));
    final templates = readJson(_jsonFileName('recurrence_templates'));
    // 旧版本备份不含 milestones.json / checklist_items.json：缺失时按空
    // 处理，计数随 manifest 的对应字段（缺失为 0）保持一致。
    final milestones = readJsonOptional(_jsonFileName('milestones'));
    final checklistItems = readJsonOptional(_jsonFileName('checklist_items'));
    final settings = readJson(_jsonFileName('settings'));

    // 计数校验：manifest 声明的数量必须与实际数组长度一致（NFR-2）。
    if (goals.length != manifest.goalCount ||
        subjects.length != manifest.subjectCount ||
        tasks.length != manifest.taskCount ||
        templates.length != manifest.recurrenceTemplateCount ||
        milestones.length != manifest.milestoneCount ||
        checklistItems.length != manifest.checklistItemCount) {
      throw const BackupException('备份文件内容与清单不一致，已拒绝恢复');
    }

    return BackupPayload(
      manifest: manifest,
      goals: goals,
      subjects: subjects,
      tasks: tasks,
      templates: templates,
      milestones: milestones,
      checklistItems: checklistItems,
      settings: settings,
    );
  }

  /// 默认备份文件名（不含路径）。
  static String defaultFileName() {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return '$_defaultFileName-$stamp.timecalc';
  }

  static String _jsonFileName(String table) => '$table.json';

  /// 把备份数据 JSON 解码结果校验为对象数组。
  ///
  /// 逐元素显式校验（而非惰性 `.cast`）：非数组或数组内混入非对象元素时
  /// 立即抛 [BackupException]——惰性 cast 只在后续迭代时才抛 TypeError
  /// （Error，UI 的 `on Exception` 捕不到），会造成恢复静默失败无反馈。
  static List<Map<String, Object?>> _readObjectList(
    Object? decoded,
    String name,
  ) {
    if (decoded is! List) {
      throw BackupException('备份文件 data/$name 格式不正确（应为数组）');
    }
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map<String, Object?>) {
        throw BackupException(
          '备份文件 data/$name 格式不正确（第 ${i + 1} 项不是对象）',
        );
      }
      out.add(item);
    }
    return out;
  }

  /// 解码单个数据段 JSON；非法 JSON 转 [BackupException]（而非裸
  /// FormatException，UI 提示一致可读）。
  static Object? _decodeDataJson(List<int> bytes, String name) {
    try {
      return jsonDecode(_decodeUtf8(bytes));
    } catch (_) {
      throw BackupException('备份文件 data/$name 不是有效 JSON');
    }
  }

  static String _goalKey(String title, String deadline, String status) =>
      '$title|$deadline|$status';

  static String _subjectKey(int goalId, String name) => '$goalId|$name';

  static String _decodeUtf8(List<int> bytes) => utf8.decode(bytes);
}
