import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/goals/data/goal_repository_provider.dart';
import '../../features/goals/data/milestone_repository_provider.dart';
import '../../features/goals/data/subject_repository_provider.dart';
import '../../features/settings/data/settings_repository_provider.dart';
import '../../features/tasks/data/recurrence_repository_provider.dart';
import '../../features/tasks/data/task_repository_provider.dart';

/// 跨页数据刷新统一入口（P3 收敛）。
///
/// 历史做法是各页面/对话框复制粘贴一段连续 `ref.invalidate(...)`，容易
/// 遗漏 provider 或写歪（today_page 与 calendar_view 曾各有一份逐字相同的
/// 7 项副本）。这里把公共集合收敛为两个函数：
///
/// - [invalidateAppData]：FR-3 验收要求的「任务/日历/目标/进度同一操作周期
///   同步更新」公共集合（任务列表、今日/日历按日期、未完成横幅、目标列表、
///   完成热力图与目标剩余工作量）；
/// - [invalidateTaskForms]：创建/编辑任务对话框的轻量子集（目标任务列表 +
///   今日/日历/未完成横幅），部分场景需在其后追加自身额外 provider
///   （如重复模板、归档列表）。
///
/// family 级 provider 在无参时 invalidate 整族，覆盖所有日期/月份/目标实例。
void invalidateAppData(WidgetRef ref) {
  ref.invalidate(taskListProvider);
  ref.invalidate(tasksByDateProvider);
  ref.invalidate(tasksByMonthProvider);
  ref.invalidate(unfinishedBeforeProvider);
  ref.invalidate(goalListProvider);
  ref.invalidate(completedTasksProvider);
  ref.invalidate(allTodoTasksProvider);
}

/// 任务表单保存后的轻量刷新（[goalId] 非空时对目标任务列表族精确失效，
/// 避免无谓重建其他目标的任务缓存）。
void invalidateTaskForms(WidgetRef ref, {int? goalId}) {
  if (goalId != null) {
    ref.invalidate(taskListProvider(goalId));
  } else {
    ref.invalidate(taskListProvider);
  }
  ref.invalidate(tasksByDateProvider);
  ref.invalidate(tasksByMonthProvider);
  ref.invalidate(unfinishedBeforeProvider);
}

/// 全量数据刷新（影响面最广的操作专用：覆盖恢复 / 重置数据）。
///
/// 在 [invalidateAppData] 基础上补齐其余页面/入口的缓存：目标详情、
/// 科目、归档任务、重复模板、里程碑与设置。覆盖恢复原本在 backup_page
/// 内私有实现，提取后供重置数据页复用，避免两份逐字副本漂移。
void invalidateAllAppData(WidgetRef ref) {
  invalidateAppData(ref);
  ref.invalidate(goalDetailProvider); // family 无参失效整族（详情页缓存）
  ref.invalidate(subjectListProvider); // family 整族（科目页/表单缓存）
  ref.invalidate(archivedCountProvider);
  ref.invalidate(archivedTaskListProvider);
  ref.invalidate(allArchivedTasksProvider);
  ref.invalidate(recurrenceTemplatesProvider); // family 整族（重复任务入口）
  ref.invalidate(recurrenceTemplateProvider); // family 整族（任务条目标注）
  ref.invalidate(milestoneListProvider); // family 整族（里程碑列表/首页卡片）
  ref.invalidate(settingsProvider);
}
