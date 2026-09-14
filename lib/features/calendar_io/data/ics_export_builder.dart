/// 计划 → iCalendar（.ics）导出：把任务与里程碑写成日历事件。
///
/// 与「计划导入」互为逆操作：库内 `plannedDate` + `startTime` 直接映射为
/// 事件的日期与钟点（本地墙上时间，浮动时区），`estimatedMinutes` 作为
/// 事件时长（缺省 1 小时）。导出全天/定时混排的日历，可直接导入
/// Google 日历、Outlook、iOS/Android 系统日历。
///
/// 纯函数式：不触碰数据库与文件系统，便于单测；写文件由调用方（服务层）
/// 负责。
library;

import '../../../core/database/database.dart';
import '../domain/ics_codec.dart';

class IcsExportBuilder {
  const IcsExportBuilder({this.codec = const IcsCodec()});

  final IcsCodec codec;

  /// UID 命名空间：同一任务的 UID 稳定可复现（重复导出/再次导入同一份
  /// 日历时，日历应用可据此识别为同一条目而非新建）。
  static const String _uidDomain = 'timecalc.local';

  /// 由任务与里程碑构造日历（[calendarName] 作为 X-WR-CALNAME）。
  ///
  /// 只导出未归档任务（归档任务属于历史记录，不进日历）；已完成任务以
  /// `STATUS:CONFIRMED` 导出——日历应用通常以删除线/灰显表现已完成，
  /// 而 TimeCalc 的「完成」语义与日历的「已取消」不同，故不做 CANCELLED。
  IcsCalendar build({
    required List<Task> tasks,
    List<Milestone> milestones = const [],
    String? calendarName,
  }) {
    final events = <IcsEvent>[
      for (final task in tasks)
        if (task.archivedAt == null)
          IcsEvent(
            uid: 'timecalc-task-${task.id}@$_uidDomain',
            summary: task.title,
            description: _taskDescription(task),
            startDate: task.plannedDate,
            startTime: task.startTime,
            durationMinutes: task.estimatedMinutes,
          ),
      for (final milestone in milestones)
        IcsEvent(
          uid: 'timecalc-milestone-${milestone.id}@$_uidDomain',
          summary: milestone.title,
          startDate: milestone.date,
        ),
    ];
    return IcsCalendar(name: calendarName, events: events);
  }

  /// 序列化为 .ics 文本。
  String serialize(IcsCalendar calendar, {DateTime? stamp}) =>
      codec.serialize(calendar, stamp: stamp);

  /// 任务描述：备注 + 时长备注（有无备注都要给出可读的时长信息）。
  static String? _taskDescription(Task task) {
    final parts = <String>[];
    final note = task.note?.trim();
    if (note != null && note.isNotEmpty) parts.add(note);
    if (task.estimatedMinutes != null) {
      parts.add('预估 ${_formatMinutes(task.estimatedMinutes!)}');
    }
    if (task.status == 'done') parts.add('已完成');
    return parts.isEmpty ? null : parts.join('\n');
  }

  /// 时长文本（与 DurationFormat.minutes 同口径的精简版，避免 domain 层
  /// 反向依赖 services 层）。
  static String _formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
  }
}
