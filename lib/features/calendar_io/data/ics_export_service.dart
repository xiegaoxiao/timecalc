import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../goals/data/milestone_repository.dart';
import '../../goals/data/milestone_repository_provider.dart';
import '../../tasks/data/task_repository.dart';
import '../../tasks/data/task_repository_provider.dart';
import '../data/ics_export_builder.dart';
import '../data/ics_file_picker.dart';

/// 日历导出：读库 → 生成 .ics 文本 → 由用户选择位置写盘。
///
/// 与备份导出同款交互（原生「另存为」对话框）；文件是纯文本 `.ics`，
/// 可直接导入 Google 日历 / Outlook / 系统日历。
class IcsExportService {
  const IcsExportService({
    required this.tasks,
    required this.milestones,
    required this.picker,
    this.builder = const IcsExportBuilder(),
  });

  final TaskRepository tasks;
  final MilestoneRepository milestones;
  final IcsFilePicker picker;
  final IcsExportBuilder builder;

  /// 导出未归档任务与全部里程碑。用户取消选择位置时返回 null。
  Future<IcsExportResult?> export({String? calendarName}) async {
    final file = await picker.saveIcsFile();
    if (file == null) return null; // 用户取消。

    final allTasks = await tasks.allActive();
    final allMilestones = await milestones.all();
    final calendar = builder.build(
      tasks: allTasks,
      milestones: allMilestones,
      calendarName: calendarName,
    );
    await file.writeAsString(builder.serialize(calendar), flush: true);
    return IcsExportResult(
      path: file.path,
      eventCount: calendar.events.length,
      taskCount: allTasks.length,
      milestoneCount: allMilestones.length,
    );
  }
}

/// 导出结果（供 UI 提示）。
class IcsExportResult {
  const IcsExportResult({
    required this.path,
    required this.eventCount,
    required this.taskCount,
    required this.milestoneCount,
  });

  final String path;
  final int eventCount;
  final int taskCount;
  final int milestoneCount;
}

/// 日历导出服务 Provider。
final icsExportServiceProvider = Provider<IcsExportService>((ref) {
  return IcsExportService(
    tasks: ref.watch(taskRepositoryProvider),
    milestones: ref.watch(milestoneRepositoryProvider),
    picker: ref.watch(icsFilePickerProvider),
  );
});
