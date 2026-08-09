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
/// 7 项副本）。这里收敛为一个公共函数：
///
/// - [invalidateAppData]：FR-3 验收要求的「任务/日历/目标/进度同一操作周期
///   同步更新」公共集合（任务列表、今日/日历按日期、未完成横幅、目标列表、
///   完成热力图与目标剩余工作量）。任务变更一律走全量集合——今日页概览
///   「目标剩余」与进度页各图依赖 allTodoTasksProvider/completedTasksProvider，
///   用轻量子集会留下陈旧缓存（导入/批量新增曾因此不刷新，回归教训）。
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
