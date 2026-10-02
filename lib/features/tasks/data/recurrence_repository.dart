import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
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
  Future<int> generateDue({int? goalId, DateTime? today}) {
    final service = RecurrenceService();
    return _db.transaction(() async {
      final todayStr = _format(today ?? DateTime.now());
      var generated = 0;
      final templates = await _activeTemplates(goalId);
      for (final template in templates) {
        final rule = RecurrenceRule(
          ruleType: template.ruleType,
          ruleJson: template.ruleJson,
        );
        final target = _minDate(_plusDays(todayStr, 30), template.endDate);
        if (!_dateLess(template.generatedThroughDate, target)) continue;

        final existing = await (_db.select(_db.tasks)
              ..where((t) => t.recurrenceTemplateId.equals(template.id)))
            .get();
        final existingDates = existing
            .where((t) => t.archivedAt == null)
            .map((t) => t.plannedDate)
            .toSet();

        final dates = service.occurrences(
          ruleType: template.ruleType,
          json: rule.jsonMap,
          startDate: template.startDate,
          from: _plusDays(template.generatedThroughDate, 1),
          to: target,
        );
        for (final date in dates) {
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
  /// 模板的规则与结束日期总是更新。按 [applyTo]：
  /// - [RecurrenceApplyTo.future]：删除该模板「今天之后未完成」的实例
  ///   （已完成实例保留，不覆盖 FR-4.4），再按新规则重新生成未来实例；
  /// - [RecurrenceApplyTo.template]：仅更新模板规则，已有实例不动。
  Future<void> updateRule({
    required int templateId,
    required RecurrenceRule rule,
    String? endDate,
    required RecurrenceApplyTo applyTo,
    DateTime? today,
  }) async {
    _validatedJson(rule);
    final service = RecurrenceService();
    return _db.transaction(() async {
      final template = await byId(templateId);
      if (template == null) return;
      final todayStr = _format(today ?? DateTime.now());

      if (applyTo == RecurrenceApplyTo.future) {
        // 删除今天之后未完成的实例（已完成保留）。
        await (_db.delete(_db.tasks)
              ..where((t) =>
                  t.recurrenceTemplateId.equals(templateId) &
                  t.plannedDate.isBiggerThanValue(todayStr) &
                  t.status.equals(TaskStatus.todo)))
            .go();
      }

      // 更新模板规则与结束日期，并重置生成窗口（未来实例按新规则生成）。
      final target = _minDate(_plusDays(todayStr, 30), endDate);
      await (_db.update(_db.recurrenceTemplates)
            ..where((t) => t.id.equals(templateId)))
          .write(
            RecurrenceTemplatesCompanion(
              ruleType: Value(rule.ruleType),
              ruleJson: Value(rule.ruleJson),
              endDate: Value(endDate),
              generatedThroughDate: Value(
                applyTo == RecurrenceApplyTo.future
                    ? _minusDays(todayStr, 1) // 触发重新生成
                    : template.generatedThroughDate,
              ),
              active: const Value(true),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );

      if (applyTo == RecurrenceApplyTo.future) {
        // 按新规则重新生成未来实例（含今天）。
        final dates = service.occurrences(
          ruleType: rule.ruleType,
          json: rule.jsonMap,
          startDate: template.startDate,
          from: todayStr,
          to: target,
        );
        final existing = await (_db.select(_db.tasks)
              ..where((t) => t.recurrenceTemplateId.equals(templateId)))
            .get();
        final existingDates =
            existing.where((t) => t.archivedAt == null).map((t) => t.plannedDate).toSet();
        for (final date in dates) {
          if (existingDates.contains(date)) continue;
          await _insertInstance(
            goalId: template.goalId,
            subjectId: template.subjectId,
            title: template.title,
            estimatedMinutes: template.estimatedMinutes,
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
    return _format(_parse(yyyyMMdd).add(Duration(days: days)));
  }

  static String _minusDays(String yyyyMMdd, int days) {
    return _format(_parse(yyyyMMdd).subtract(Duration(days: days)));
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
