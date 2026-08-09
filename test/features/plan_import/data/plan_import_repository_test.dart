import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/features/plan_import/data/plan_import_repository.dart';
import 'package:timecalc/features/plan_import/domain/plan_import_parser.dart';

/// 完整计划落库测试：单事务写入目标 + 里程碑 + 科目 + 任务 + 重复模板实例。
void main() {
  late AppDatabase db;
  late PlanImportRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = PlanImportRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// 构造一个解析通过的完整计划（含里程碑/科目任务/模板/未分类）。
  ImportedPlan buildPlan() {
    return const ImportedPlan(
      goalTitle: '2027考研数学备考计划',
      deadlineDate: '2026-08-15',
      milestones: [
        ImportedMilestone(title: '强化阶段', date: '2026-08-09'),
        ImportedMilestone(title: '第 1 周：真题套卷', date: '2026-08-09'),
      ],
      tasks: [
        ImportedPlanTask(
          title: '武忠祥讲义：三重积分（听课+例题）',
          date: '2026-08-10',
          subjectName: '高等数学',
          minutes: 180,
        ),
        ImportedPlanTask(
          title: '复盘错题',
          date: '2026-08-11',
          note: '每周日复盘',
          minutes: 90,
        ),
      ],
      templates: [
        ImportedPlanTemplate(
          title: '完成《三大计算》积分专项（每天30分钟）',
          startDate: '2026-08-09',
          endDate: '2026-08-15',
          minutes: 30,
        ),
      ],
      subjectOrder: ['高等数学'],
    );
  }

  test('导入完整计划：各表数量与字段正确，模板生成 7 天实例', () async {
    final stats = await repo.importPlan(buildPlan());
    expect(stats.goalId, greaterThan(0));
    expect(stats.milestoneCount, 2);
    expect(stats.subjectCount, 1);
    expect(stats.taskCount, 2);
    expect(stats.templateCount, 1);
    expect(stats.instanceCount, 7); // 每天规则覆盖 08-09 ~ 08-15 共 7 天

    // 目标。
    final goal = await (db.select(db.goals)..where((g) => g.id.equals(stats.goalId)))
        .getSingle();
    expect(goal.title, '2027考研数学备考计划');
    expect(goal.deadlineDate, '2026-08-15');
    expect(goal.status, 'active');

    // 里程碑（按写入顺序 sortOrder）。
    final milestones = await (db.select(db.milestones)
          ..where((m) => m.goalId.equals(stats.goalId)))
        .get();
    expect(milestones, hasLength(2));
    expect(milestones.map((m) => m.title).toList(), [
      '强化阶段',
      '第 1 周：真题套卷',
    ]);
    expect(milestones[0].sortOrder, 0);
    expect(milestones[1].sortOrder, 1);

    // 科目。
    final subjects = await (db.select(db.subjects)
          ..where((s) => s.goalId.equals(stats.goalId)))
        .get();
    expect(subjects, hasLength(1));
    expect(subjects.single.name, '高等数学');

    // 任务：科目任务 + 未分类任务（note 落库，minutes 写入预估时长）。
    final tasks = await (db.select(db.tasks)
          ..where((t) => t.goalId.equals(stats.goalId)))
        .get();
    expect(tasks, hasLength(2 + 7)); // 2 普通任务 + 7 模板实例
    final mathTask = tasks.firstWhere((t) => t.title.contains('三重积分'));
    expect(mathTask.subjectId, subjects.single.id);
    expect(mathTask.note, isNull);
    expect(mathTask.estimatedMinutes, 180); // minutes 落库（进度页统计依赖）
    final unclassified = tasks.firstWhere((t) => t.title == '复盘错题');
    expect(unclassified.subjectId, isNull);
    expect(unclassified.note, '每周日复盘');
    expect(unclassified.estimatedMinutes, 90);

    // 模板与实例（minutes 落库：模板 + 每条实例继承，进度页统计依赖）。
    final templates = await (db.select(db.recurrenceTemplates)
          ..where((t) => t.goalId.equals(stats.goalId)))
        .get();
    expect(templates, hasLength(1));
    expect(templates.single.ruleType, 'daily');
    expect(templates.single.ruleJson, '{}');
    expect(templates.single.generatedThroughDate, '2026-08-15');
    expect(templates.single.estimatedMinutes, 30);
    final instances = tasks.where((t) => t.recurrenceTemplateId != null).toList();
    expect(instances, hasLength(7));
    expect(instances.map((t) => t.plannedDate).toSet(), {
      '2026-08-09', '2026-08-10', '2026-08-11', '2026-08-12',
      '2026-08-13', '2026-08-14', '2026-08-15',
    });
    expect(instances.every((t) => t.title == '完成《三大计算》积分专项（每天30分钟）'), isTrue);
    // 实例时长继承自模板 minutes（每条 30 分钟）。
    expect(instances.every((t) => t.estimatedMinutes == 30), isTrue);
  });

  test('导入失败整体回滚：里程碑插入失败不留半成品（NFR-2）', () async {
    final plan = buildPlan();
    // 注入超长里程碑标题（>200）触发数据库约束错误。
    final bad = ImportedPlan(
      goalTitle: plan.goalTitle,
      deadlineDate: plan.deadlineDate,
      milestones: [
        ImportedMilestone(title: '长' * 201, date: '2026-08-09'),
      ],
      tasks: const [],
      templates: const [],
      subjectOrder: const [],
    );
    await expectLater(repo.importPlan(bad), throwsA(anything));

    // 事务回滚：不残留任何目标。
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.milestones).get(), isEmpty);
    expect(await db.select(db.subjects).get(), isEmpty);
    expect(await db.select(db.tasks).get(), isEmpty);
    expect(await db.select(db.recurrenceTemplates).get(), isEmpty);
  });
}
