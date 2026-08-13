import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/recurrence_service.dart';
import '../domain/recurrence/recurrence_rule.dart';
import '../domain/recurrence/recurrence_registry.dart';

/// 更新规则的应用范围（FR-4.4）。
enum RecurrenceApplyTo {
  /// 仅修改模板规则，不触碰已生成的实例。
  template,

  /// 删除今天之后未完成的未来实例并按新规则重新生成；已完成实例保留。
  future,
}

/// 重复任务数据访问层（FR-4，模板 + 实例模型）。
///
/// - 模板保存规则（ruleType + ruleJson），实例为具体日期的任务
///   （Tasks.recurrenceTemplateId 指向模板）；
/// - 仅预生成未来 30 天实例，窗口临近时由 [generateDue] 滚动生成（FR-4.3）；
/// - 规则解释委托 RecurrenceService（可扩展引擎）。
class RecurrenceRepository {
  RecurrenceRepository(this._db);

  final AppDatabase _db;

  static final _registry = RecurrenceRuleRegistry();

  /// 编码墓碑日期集合为 JSON 数组文本（升序去重）；空集合返回 null。
  ///
  /// 供 TaskRepository 删除实例时写入模板的 deletedInstanceDates 字段。
  static String? encodeTombstones(Set<String> dates) {
    if (dates.isEmpty) return null;
    final sorted = dates.toList()..sort();
    return jsonEncode(sorted);
  }

  /// 解码墓碑日期集合；null/空/非法 JSON 返回空集合（宽容处理脏数据）。
  static Set<String> decodeTombstones(String? encoded) {
    if (encoded == null || encoded.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return <String>{};
      return <String>{
        for (final item in decoded)
          if (item is String && _dateFormat.hasMatch(item)) item,
      };
    } catch (_) {
      return <String>{};
    }
  }

  static final RegExp _dateFormat = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// 校验并解析规则 JSON；非法抛 ArgumentError（对话框已先校验，兜底防御）。
  Map<String, dynamic> _validatedJson(RecurrenceRule rule) {
    final json = rule.jsonMap;
    final error = rule.validateWith(_registry);
    if (error != null) {
      throw ArgumentError('无效的重复规则：$error');
    }
    return json;
  }

  /// 创建重复任务模板并生成初始实例（today ~ today+30，单事务，NFR-2）。
  ///
  /// 返回创建的模板。实例的 completedAt/archivedAt 为 null。
  /// [today] 可注入固定日期（默认系统当前日期），供测试确定窗口。
  Future<RecurrenceTemplate> create({
    required int goalId,
    int? subjectId,
    required String title,
    int? estimatedMinutes,
    required RecurrenceRule rule,
    required String startDate,
    String? endDate,
    DateTime? today,
  }) async {
    _validatedJson(rule);
    final service = RecurrenceService();
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      final todayStr = _format(today ?? DateTime.now());
      final generatedThrough = _minDate(_plusDays(todayStr, 30), endDate);
      final templateId = await _db.into(_db.recurrenceTemplates).insert(
            RecurrenceTemplatesCompanion.insert(
              goalId: goalId,
              subjectId: Value(subjectId),
              title: title,
              estimatedMinutes: Value(estimatedMinutes),
              ruleType: rule.ruleType,
              ruleJson: rule.ruleJson,
              startDate: startDate,
              endDate: Value(endDate),
              generatedThroughDate: generatedThrough,
              createdAt: now,
              updatedAt: now,
            ),
          );
      // 生成初始窗口内的实例。
      final dates = service.occurrences(
        ruleType: rule.ruleType,
        json: rule.jsonMap,
        startDate: startDate,
        to: generatedThrough,
      );
      for (final date in dates) {
        await _insertInstance(
          goalId: goalId,
          subjectId: subjectId,
          title: title,
          estimatedMinutes: estimatedMinutes,
          templateId: templateId,
          date: date,
        );
      }
      return (await byId(templateId))!;
    });
  }

  Future<RecurrenceTemplate?> byId(int id) {
    return (_db.select(_db.recurrenceTemplates)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 目标下全部模板（含已停用）。
  Future<List<RecurrenceTemplate>> byGoal(int goalId) {
    final query = _db.select(_db.recurrenceTemplates)
      ..where((t) => t.goalId.equals(goalId))
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.get();
  }

  /// 滚动生成缺失实例（FR-4.3）。
  ///
  /// 对 active 模板：从 generatedThroughDate 的次日生成到
  /// min(today+30, endDate)，同模板同日期已存在未归档实例则跳过；更新
  /// generatedThroughDate。幂等；[goalId] 为空时处理全部模板（应用启动调用）。
  ///
  /// 性能：先筛出真正需要生成的模板，再对这批模板发**一条** `IN` 查询取
  /// 全部未归档实例、按模板分组去重——替代旧版每模板一次全量实例查询的
  /// N+1（启动路径，模板多时逐条往返明显）。
  Future<int> generateDue({int? goalId, DateTime? today}) {
    final service = RecurrenceService();
    return _db.transaction(() async {
      final todayStr = _format(today ?? DateTime.now());
      var generated = 0;
      final templates = await _activeTemplates(goalId);

      // 第一遍：仅收集需要滚动生成的模板（跳过窗口未推进的），避免对
      // 无需生成的模板也发起实例查询。
      final toGenerate = <RecurrenceTemplate>[];
      for (final template in templates) {
        final target = _minDate(_plusDays(todayStr, 30), template.endDate);
        if (_dateLess(template.generatedThroughDate, target)) {
          toGenerate.add(template);
        }
      }

      // 第二遍：单条 IN 查询取这些模板的全部未归档实例，按模板分组。
      final existingByTemplate = <int, Set<String>>{};
      if (toGenerate.isNotEmpty) {
        final existing = await (_db.select(_db.tasks)
              ..where(
                (t) =>
                    t.recurrenceTemplateId.isIn(
                      toGenerate.map((t) => t.id),
                    ) &
                    t.archivedAt.isNull(),
              ))
            .get();
        for (final task in existing) {
          final templateId = task.recurrenceTemplateId;
          if (templateId == null) continue;
          existingByTemplate
              .putIfAbsent(templateId, () => <String>{})
              .add(task.plannedDate);
        }
      }

      for (final template in toGenerate) {
        final rule = RecurrenceRule(
          ruleType: template.ruleType,
          ruleJson: template.ruleJson,
        );
        // 生成前校验规则（M16）：registry 对未知/非法类型静默返回空列表，
        // 若不校验就推进 generatedThroughDate，脏数据模板将**永久跳过生成**
        // （未来实例静默丢失）。非法规则跳过本模板、不推进窗口。
        final ruleError = rule.validateWith(_registry);
        if (ruleError != null) {
          continue;
        }
        final target = _minDate(_plusDays(todayStr, 30), template.endDate);
        final existingDates = existingByTemplate[template.id] ?? <String>{};
        // 用户删除过的实例日期（墓碑）：滚动生成时跳过，防止被删实例复活。
        final tombstoneDates = decodeTombstones(template.deletedInstanceDates);

        final dates = service.occurrences(
          ruleType: template.ruleType,
          json: rule.jsonMap,
          startDate: template.startDate,
          from: _plusDays(template.generatedThroughDate, 1),
          to: target,
        );
        for (final date in dates) {
          if (tombstoneDates.contains(date)) continue;
          if (existingDates.contains(date)) continue;
          await _insertInstance(
            goalId: template.goalId,
            subjectId: template.subjectId,
            title: template.title,
            estimatedMinutes: template.estimatedMinutes,
            templateId: template.id,
            date: date,
          );
          existingDates.add(date);
          generated++;
        }

        await (_db.update(_db.recurrenceTemplates)
              ..where((t) => t.id.equals(template.id)))
            .write(
              RecurrenceTemplatesCompanion(
                generatedThroughDate: Value(target),
                updatedAt: Value(DateTime.now().toUtc()),
              ),
            );
      }
      return generated;
    });
  }

  /// 停止重复（FR-4.5）：active=false，不再生成新实例；历史实例保留。
  Future<void> stop(int templateId) {
    return _db.transaction(() async {
      await (_db.update(_db.recurrenceTemplates)
            ..where((t) => t.id.equals(templateId)))
          .write(
            RecurrenceTemplatesCompanion(
              active: const Value(false),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );
    });
  }

  /// 修改重复规则（FR-4.4）。
  ///
  /// 模板的规则、结束日期与基础信息（[title]/[subjectId]/[estimatedMinutes]/
  /// [startDate]）总是更新（null 表示不修改）。按 [applyTo]：
  /// - [RecurrenceApplyTo.future]：删除该模板「今天之后未完成」的实例
  ///   （已完成实例保留，不覆盖 FR-4.4），再按新规则重新生成未来实例；
  /// - [RecurrenceApplyTo.template]：仅更新模板规则，已有实例不动。
  Future<void> updateRule({
    required int templateId,
    required RecurrenceRule rule,
    String? endDate,
    required RecurrenceApplyTo applyTo,
    DateTime? today,
    String? title,
    Value<int?>? subjectId,
    Value<int?>? estimatedMinutes,
    String? startDate,
  }) async {
    _validatedJson(rule);
    final service = RecurrenceService();
    return _db.transaction(() async {
      final template = await byId(templateId);
      if (template == null) return;
      final todayStr = _format(today ?? DateTime.now());
      // 起始日期可随编辑更新；重生成时使用新的起始日。
      final effectiveStartDate = startDate ?? template.startDate;

      if (applyTo == RecurrenceApplyTo.future) {
        // 删除今天之后未完成的实例（已完成保留）。
        await (_db.delete(_db.tasks)
              ..where((t) =>
                  t.recurrenceTemplateId.equals(templateId) &
                  t.plannedDate.isBiggerThanValue(todayStr) &
                  t.status.equals(TaskStatus.todo)))
            .go();
      }

      // 更新模板规则、结束日期与基础信息，并重置生成窗口（未来实例按新规则生成）。
      final target = _minDate(_plusDays(todayStr, 30), endDate);
      await (_db.update(_db.recurrenceTemplates)
            ..where((t) => t.id.equals(templateId)))
          .write(
            RecurrenceTemplatesCompanion(
              ruleType: Value(rule.ruleType),
              ruleJson: Value(rule.ruleJson),
              endDate: Value(endDate),
              title: title == null ? const Value.absent() : Value(title),
              subjectId: subjectId ?? const Value.absent(),
              estimatedMinutes: estimatedMinutes ?? const Value.absent(),
              startDate:
                  startDate == null ? const Value.absent() : Value(startDate),
              // future 应用时已按新规则从 today 生成到 target：直接把
              // generatedThroughDate 推进到 target，后续 generateDue 不再
              // 对同一窗口重复重算（此前写 today-1 每次都要靠 existing
              // 日期跳过，属重复劳动）。template 应用（不动实例）保持原窗口。
              generatedThroughDate: Value(
                applyTo == RecurrenceApplyTo.future
                    ? target
                    : template.generatedThroughDate,
              ),
              active: const Value(true),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );

      if (applyTo == RecurrenceApplyTo.future) {
        // 按新规则重新生成未来实例（含今天），使用更新后的基础信息。
        final dates = service.occurrences(
          ruleType: rule.ruleType,
          json: rule.jsonMap,
          startDate: effectiveStartDate,
          from: todayStr,
          to: target,
        );
        final existing = await (_db.select(_db.tasks)
              ..where((t) => t.recurrenceTemplateId.equals(templateId)))
            .get();
        final existingDates =
            existing.where((t) => t.archivedAt == null).map((t) => t.plannedDate).toSet();
        // 用户删除过的实例日期（墓碑）：重生成时跳过，防止被删实例复活。
        final tombstoneDates = decodeTombstones(template.deletedInstanceDates);
        for (final date in dates) {
          if (tombstoneDates.contains(date)) continue;
          if (existingDates.contains(date)) continue;
          await _insertInstance(
            goalId: template.goalId,
            subjectId: subjectId?.value ?? template.subjectId,
            title: title ?? template.title,
            estimatedMinutes:
                estimatedMinutes?.value ?? template.estimatedMinutes,
            templateId: templateId,
            date: date,
          );
          existingDates.add(date);
        }
      }
    });
  }

  /// 删除模板：其实例降级为普通任务（解除关联），再删除模板。
  Future<void> delete(int templateId) {
    return _db.transaction(() async {
      await (_db.update(_db.tasks)
            ..where((t) => t.recurrenceTemplateId.equals(templateId)))
          .write(
            TasksCompanion(
              recurrenceTemplateId: const Value(null),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );
      await (_db.delete(_db.recurrenceTemplates)
            ..where((t) => t.id.equals(templateId)))
          .go();
    });
  }

  /// 删除模板及其全部实例（折叠列表父卡片「删除整个重复」语义）。
  ///
  /// 与 [delete] 不同：不保留历史实例，而是连同所有实例一起删除。
  /// 跨多表删除在单个事务内完成（NFR-2），中途失败回滚不留半删除数据。
  Future<void> deleteWithInstances(int templateId) {
    return _db.transaction(() async {
      await (_db.delete(_db.tasks)
            ..where((t) => t.recurrenceTemplateId.equals(templateId)))
          .go();
      await (_db.delete(_db.recurrenceTemplates)
            ..where((t) => t.id.equals(templateId)))
          .go();
    });
  }

  Future<List<RecurrenceTemplate>> _activeTemplates(int? goalId) {
    final query = _db.select(_db.recurrenceTemplates)
      ..where((t) => t.active.equals(true));
    if (goalId != null) {
      query.where((t) => t.goalId.equals(goalId));
    }
    return query.get();
  }

  Future<void> _insertInstance({
    required int goalId,
    int? subjectId,
    required String title,
    int? estimatedMinutes,
    required int templateId,
    required String date,
  }) {
    final now = DateTime.now().toUtc();
    return _db.into(_db.tasks).insert(
      TasksCompanion.insert(
        goalId: goalId,
        subjectId: Value(subjectId),
        title: title,
        plannedDate: date,
        estimatedMinutes: Value(estimatedMinutes),
        recurrenceTemplateId: Value(templateId),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  static String _plusDays(String yyyyMMdd, int days) {
    // 纯日历加法（date_text）：避免 Duration(days:) 在夏令时切换日偏移。
    return formatLocalDate(addLocalDays(_parse(yyyyMMdd), days));
  }

  static bool _dateLess(String a, String b) => a.compareTo(b) < 0;

  static String _minDate(String a, String? b) {
    if (b == null || a.compareTo(b) <= 0) return a;
    return b;
  }

  static DateTime _parse(String yyyyMMdd) {
    final parts = yyyyMMdd.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  static String _format(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }
}
