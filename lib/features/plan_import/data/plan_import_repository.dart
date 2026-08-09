import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../services/recurrence_service.dart';
import '../../tasks/domain/recurrence/recurrence_rule.dart';
import '../../tasks/domain/recurrence/recurrence_registry.dart';
import '../domain/plan_import_parser.dart';

/// 完整计划导入统计结果。
class PlanImportStats {
  const PlanImportStats({
    required this.goalId,
    required this.milestoneCount,
    required this.subjectCount,
    required this.taskCount,
    required this.templateCount,
    required this.instanceCount,
    required this.skippedTasks,
    required this.skippedTemplates,
  });

  final int goalId;
  final int milestoneCount;
  final int subjectCount;
  final int taskCount;
  final int templateCount;

  /// 重复模板生成的实例任务数。
  final int instanceCount;
  final int skippedTasks;
  final int skippedTemplates;
}

/// 完整计划导入数据访问层：单事务写入目标 + 里程碑 + 科目 + 任务 +
/// 重复模板（含实例生成），任一步失败整体回滚（NFR-2）。
///
/// 参照既有先例：`GoalRepository.createWithSubjects`（目标+科目同事务）、
/// `TaskRepository.importPlan`（科目自动创建+任务写入）、
/// `RecurrenceRepository.create`（模板+实例生成，实例逻辑在此内联避免嵌套事务）。
class PlanImportRepository {
  PlanImportRepository(this._db);

  final AppDatabase _db;

  static final _registry = RecurrenceRuleRegistry();

  /// 导入解析通过的完整计划，返回统计结果（含新建目标 id）。
  Future<PlanImportStats> importPlan(ImportedPlan plan) {
    final now = DateTime.now().toUtc();
    final service = RecurrenceService(registry: _registry);
    // 每天规则：无参数（与 RecurrenceTaskDialog 创建「每天」模板一致）。
    final dailyRule = const RecurrenceRule(ruleType: 'daily', ruleJson: '{}');

    return _db.transaction(() async {
      // 1. 目标（status 走 DB 默认 active）。
      final goalId = await _db.into(_db.goals).insert(GoalsCompanion.insert(
            title: plan.goalTitle,
            deadlineDate: plan.deadlineDate,
            createdAt: now,
            updatedAt: now,
          ));

      // 2. 里程碑（按写入顺序 sortOrder 递增，阶段在前、周节点在后）。
      for (var i = 0; i < plan.milestones.length; i++) {
        final m = plan.milestones[i];
        await _db.into(_db.milestones).insert(MilestonesCompanion.insert(
              goalId: goalId,
              title: m.title,
              date: m.date,
              sortOrder: Value(i),
              createdAt: now,
              updatedAt: now,
            ));
      }

      // 3. 科目（按 subjectOrder 顺序创建，默认颜色与排序，同 importPlan）。
      final subjectIdByName = <String, int>{};
      for (var i = 0; i < plan.subjectOrder.length; i++) {
        final name = plan.subjectOrder[i];
        subjectIdByName[name] = await _db.into(_db.subjects).insert(
              SubjectsCompanion.insert(
                goalId: goalId,
                name: name,
                color: '#3F6C51',
                sortOrder: Value(i),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }

      // 4. 任务（科目任务 + 未分类任务；note 落库，subjectId 经映射，
      // estimatedMinutes 来自 JSON minutes 字段——进度统计只计带时长
      // 的任务，FR-7.4）。
      for (final t in plan.tasks) {
        await _db.into(_db.tasks).insert(TasksCompanion.insert(
              goalId: goalId,
              subjectId: Value(
                t.subjectName == null ? null : subjectIdByName[t.subjectName],
              ),
              title: t.title,
              note: Value(t.note),
              estimatedMinutes: Value(t.minutes),
              plannedDate: t.date,
              createdAt: now,
              updatedAt: now,
            ));
      }

      // 5. 重复模板：每条生成覆盖 [startDate, endDate] 的全部「每天」实例。
      // 实例生成内联（RecurrenceService.occurrences + 直接 insert），不调用
      // RecurrenceRepository.create（自带事务，避免嵌套事务退化）。
      // 模板的 estimatedMinutes（JSON minutes 字段）继承到每条实例，
      // 保证进度页统计（FR-7.4）能看到重复任务。
      var instanceCount = 0;
      for (final t in plan.templates) {
        final templateId = await _db.into(_db.recurrenceTemplates).insert(
              RecurrenceTemplatesCompanion.insert(
                goalId: goalId,
                title: t.title,
                estimatedMinutes: Value(t.minutes),
                ruleType: ImportedPlanTemplate.ruleType,
                ruleJson: ImportedPlanTemplate.ruleJson,
                startDate: t.startDate,
                endDate: Value(t.endDate),
                generatedThroughDate: t.endDate,
                createdAt: now,
                updatedAt: now,
              ),
            );
        final dates = service.occurrences(
          ruleType: ImportedPlanTemplate.ruleType,
          json: dailyRule.jsonMap,
          startDate: t.startDate,
          to: t.endDate,
        );
        for (final date in dates) {
          await _db.into(_db.tasks).insert(TasksCompanion.insert(
                goalId: goalId,
                title: t.title,
                plannedDate: date,
                estimatedMinutes: Value(t.minutes),
                recurrenceTemplateId: Value(templateId),
                createdAt: now,
                updatedAt: now,
              ));
          instanceCount++;
        }
      }

      return PlanImportStats(
        goalId: goalId,
        milestoneCount: plan.milestones.length,
        subjectCount: plan.subjectOrder.length,
        taskCount: plan.tasks.length,
        templateCount: plan.templates.length,
        instanceCount: instanceCount,
        skippedTasks: plan.skippedTasks,
        skippedTemplates: plan.skippedTemplates,
      );
    });
  }
}
