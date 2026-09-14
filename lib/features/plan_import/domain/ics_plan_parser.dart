/// iCalendar（.ics）→ 可导入计划的桥接解析。
///
/// 把外部日历（Google Calendar / Outlook / 手机日历导出的 .ics）转成
/// [ImportedPlan]，从而复用「计划导入」既有链路：同一套校验结果类型
/// （[PlanImportResult] / [ImportIssue]）、同一个落库事务
/// （PlanImportRepository.importPlan）、同一份预览 UI。
///
/// 映射规则：
/// - 目标标题 ← `X-WR-CALNAME`（日历名）；缺省用调用方给的 [fallbackTitle]
///   （通常是文件名）；
/// - 目标截止日 ← 全部事件中最晚的日期（`end_date` 由我们推导，因为
///   ics 没有「计划整体截止」的概念）；
/// - 每个 VEVENT → 一条任务：`SUMMARY` → title、`DTSTART` → date
///   （+ 钟点 → startTime）、`DTEND−DTSTART`/`DURATION` → minutes、
///   `DESCRIPTION` → note；
/// - `STATUS:CANCELLED` 事件跳过；早于今天的任务按既有策略跳过并统计；
/// - 里程碑与重复模板不生成（ics 的 RRULE 不在此展开——重复实例在导出侧
///   本就是逐条实体化的事件）。
///
/// 纯 Dart，不依赖数据库与 UI，可在 isolate 内运行。
library;

import '../../../core/utils/time_text.dart';
import '../../calendar_io/domain/ics_codec.dart';
import '../../tasks/domain/task_import_parser.dart' show ImportIssue;
import 'plan_import_parser.dart';

/// ics → [ImportedPlan]，与 [PlanImportParser] 同契约（校验不通过不带计划）。
class IcsPlanParser {
  const IcsPlanParser({this.codec = const IcsCodec()});

  final IcsCodec codec;

  /// [source] 为 ics 文本；[today] 为本地「今天」（早于它的任务按策略跳过）；
  /// [fallbackTitle] 为无日历名时的目标标题（如文件名）。
  PlanImportResult parse(
    String source, {
    required DateTime today,
    String? fallbackTitle,
  }) {
    final IcsCalendar calendar;
    try {
      calendar = codec.parse(source);
    } on FormatException catch (e) {
      return PlanImportResult(issues: [ImportIssue(e.message)]);
    }

    final todayStr = _format(today);
    final issues = <ImportIssue>[];

    if (calendar.events.isEmpty) {
      return const PlanImportResult(
        issues: [ImportIssue('这个日历里没有可导入的事件（VEVENT）')],
      );
    }

    final tasks = <ImportedPlanTask>[];
    var skippedTasks = 0;
    var latestDate = todayStr;

    for (var i = 0; i < calendar.events.length; i++) {
      final event = calendar.events[i];
      final location = '第 ${i + 1} 个事件';
      if (event.isCancelled) {
        skippedTasks++;
        continue;
      }
      final title = event.summary.trim();
      if (title.length > 200) {
        issues.add(ImportIssue('事件标题不能超过 200 字（SUMMARY）', location: location));
        continue;
      }
      if (event.startDate.compareTo(todayStr) < 0) {
        // 与计划导入同策略：历史事件不写入，跳过并统计（导入外部日历时
        // 过去的事件往往很多，整体报错不现实）。
        skippedTasks++;
        continue;
      }
      if (event.startDate.compareTo(latestDate) > 0) {
        latestDate = event.startDate;
      }
      tasks.add(
        ImportedPlanTask(
          title: title,
          date: event.startDate,
          note: event.description,
          minutes: _normalizeMinutes(event.durationMinutes),
          time: tryNormalizeTimeOfDay(event.startTime),
        ),
      );
    }

    if (issues.isNotEmpty) return PlanImportResult(issues: issues);
    if (tasks.isEmpty) {
      return const PlanImportResult(
        issues: [ImportIssue('没有可导入的事件：全部事件都已取消或早于今天')],
      );
    }

    final calendarName = calendar.name?.trim();
    final goalTitle = (calendarName != null && calendarName.isNotEmpty)
        ? (calendarName.length > 200
              ? calendarName.substring(0, 200)
              : calendarName)
        : (fallbackTitle == null || fallbackTitle.trim().isEmpty
              ? '导入的日历'
              : fallbackTitle.trim());

    return PlanImportResult(
      plan: ImportedPlan(
        goalTitle: goalTitle,
        deadlineDate: latestDate,
        milestones: const [],
        tasks: tasks,
        templates: const [],
        subjectOrder: const [],
        skippedTasks: skippedTasks,
      ),
    );
  }

  /// 时长归一到 1～1440 分钟（与 plans/tasks 导入同契约）：超出上界的
  /// 事件（如全天跨多天）按一天封顶，小于 1 分钟或缺失则不带时长。
  static int? _normalizeMinutes(int? minutes) {
    if (minutes == null || minutes < 1) return null;
    return minutes > 1440 ? 1440 : minutes;
  }

  static String _format(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
