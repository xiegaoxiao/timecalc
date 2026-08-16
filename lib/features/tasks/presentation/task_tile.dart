import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/utils/date_text.dart';
import '../../../services/defer_service.dart';
import '../../../services/duration_format.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/recurrence_repository_provider.dart';
import '../data/task_repository_provider.dart';
import 'checklist_dialog.dart';
import 'recurrence_task_dialog.dart';
import 'task_form_dialog.dart';

/// 跨目标任务条目（P3.4 合并 TaskTile 与 _TaskTile 后的唯一实现）。
///
/// 支持：完成/取消完成、编辑、延期至下一可用日、指定日期延期、删除。
/// [onChanged] 由父级触发相关 Provider 刷新；任务内容/归属/预估时长
/// 在延期时保持不变（FR-3.3 验收）。
///
/// 两种使用场景由可选参数区分：
/// - 跨目标列表（今日页/日历选日面板）：默认不展示计划日期、科目名经
///   [subjectListProvider] 自查；
/// - 目标内列表（目标详情页/科目任务页）：父级批量查询后经 [subjects]
///   传入科目（避免 N+1），[showPlannedDate] 为 true 时展示计划日期。
class TaskTile extends ConsumerStatefulWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onChanged,
    this.goalTitle,
    this.subjects,
    this.showPlannedDate = false,
  });

  final Task task;

  /// 变更后通知父级刷新（如 invalidate 相关 Provider）。
  final VoidCallback onChanged;

  /// 跨目标场景下展示目标名（如今日页）。
  final String? goalTitle;

  /// 父级已批量取好的科目列表（避免每行独立查询，N+1）；
  /// 为 null 时经 [subjectListProvider] 自查。
  final List<Subject>? subjects;

  /// 是否在副标题展示计划日期（目标内列表需要，跨目标列表冗余）。
  final bool showPlannedDate;

  @override
  ConsumerState<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends ConsumerState<TaskTile> {
  static const _defer = DeferService();

  /// 乐观完成态（2026-08-15 性能优化）：点击复选框立即反映到 UI，不等
  /// 数据库写入 + Provider 刷新往返——避免「点了没反应 → 数据回来后整行
  /// 猛然划线」的掉帧/延迟感。数据刷新确认后由 [didUpdateWidget] 清除。
  bool? _optimisticDone;

  /// 当前展示的完成态：乐观态优先，未覆盖时以真实数据为准。
  bool get _done => _optimisticDone ?? widget.task.status == TaskStatus.done;

  @override
  void didUpdateWidget(TaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据刷新已确认乐观态（父级以新 task 重建本行）→ 清除覆盖，
    // 恢复由真实数据驱动；未确认（例如其他刷新先到、旧数据仍在）则保留。
    if (_optimisticDone != null &&
        _optimisticDone == (widget.task.status == TaskStatus.done)) {
      _optimisticDone = null;
    }
  }

  /// 完成/取消完成切换：乐观更新 + 数据落地后统一刷新。
  Future<void> _toggle(bool? value) async {
    if (value == true && !_done) {
      // FR-4.1：勾选完成且存在未完成检查项时二次确认。
      final proceed = await confirmCompleteTask(context, ref, widget.task);
      if (!proceed) return;
      if (!mounted) return;
    }
    final target = value ?? false;
    setState(() => _optimisticDone = target); // 立即反馈，不等数据库往返
    final repo = ref.read(taskRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.setDone(widget.task.id, target),
    );
    if (ok) {
      widget.onChanged();
    } else if (mounted) {
      setState(() => _optimisticDone = null); // 写入失败回滚到真实态
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;

    // 科目名：优先用父级传入列表（N+1 优化）；否则 watch 自查。
    final subjectName = widget.subjects != null
        ? (widget.task.subjectId == null
              ? null
              : widget.subjects!
                  .where((s) => s.id == widget.task.subjectId)
                  .map((s) => s.name)
                  .firstOrNull)
        : ref
            .watch(subjectListProvider(widget.task.goalId))
            .valueOrNull
            ?.where((s) => s.id == widget.task.subjectId)
            .map((s) => s.name)
            .firstOrNull;

    return AnimatedOpacity(
      // 完成态整行轻微降透明（配合划线），过渡 200ms 平滑不跳变。
      duration: const Duration(milliseconds: 200),
      opacity: done ? 0.72 : 1.0,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Checkbox(
            value: done,
            // 读屏可读的名称（NFR-4）：任务完成复选框不依赖相邻文本推断。
            semanticLabel: done ? '标记未完成' : '标记完成',
            onChanged: _toggle,
          ),
          title: Row(
            children: [
              Flexible(
                child: AnimatedDefaultTextStyle(
                  // 完成划线 + 颜色过渡：勾选后平滑地划掉，而非跳变。
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  style: done
                      ? TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: Theme.of(context).colorScheme.outline,
                        )
                      : TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                  child: Text(
                    widget.task.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (widget.task.recurrenceTemplateId != null) ...[
                const SizedBox(width: 6),
                const Tooltip(
                  message: '重复任务',
                  child: Icon(Icons.autorenew, size: 16),
                ),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  ?widget.goalTitle,
                  if (widget.showPlannedDate)
                    formatLocalDate(parseLocalDate(widget.task.plannedDate)),
                  ?subjectName,
                  if (widget.task.estimatedMinutes != null)
                    DurationFormat.minutes(widget.task.estimatedMinutes!),
                ].join(' · '),
              ),
              if (widget.task.note?.isNotEmpty ?? false)
                Text(
                  widget.task.note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '任务操作',
            onSelected: (action) => _handleAction(context, ref, action),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              const PopupMenuItem(value: 'checklist', child: Text('检查项…')),
              const PopupMenuItem(value: 'deferNext', child: Text('延期至下一可用日')),
              const PopupMenuItem(value: 'deferPick', child: Text('延期…')),
              if (widget.task.recurrenceTemplateId != null) ...[
                const PopupMenuItem(value: 'editRecurrence', child: Text('编辑重复规则')),
                const PopupMenuItem(value: 'stopRecurrence', child: Text('停止重复')),
              ],
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleAction(
      BuildContext context, WidgetRef ref, String action) async {
    switch (action) {
      case 'edit':
        await _edit(context, ref);
        break;
      case 'checklist':
        await ChecklistDialog.show(context, task: widget.task);
        break;
      case 'deferNext':
        await _deferToNextAvailable(context, ref);
        break;
      case 'deferPick':
        await _deferPickDate(context, ref);
        break;
      case 'editRecurrence':
        await _editRecurrence(context, ref);
        break;
      case 'stopRecurrence':
        await _stopRecurrence(context, ref);
        break;
      case 'delete':
        await _delete(context, ref);
        break;
    }
  }

  /// 编辑重复规则（打开规则对话框，预填当前模板）。
  Future<void> _editRecurrence(BuildContext context, WidgetRef ref) async {
    final templateId = widget.task.recurrenceTemplateId;
    if (templateId == null) return;
    final template = await ref.read(recurrenceTemplateProvider(templateId).future);
    if (template == null || !context.mounted) return;
    final subjects = widget.subjects ??
        ref.read(subjectListProvider(widget.task.goalId)).valueOrNull ??
        const <Subject>[];
    final saved = await RecurrenceTaskDialog.show(
      context,
      goalId: widget.task.goalId,
      subjects: subjects,
      editTemplate: template,
    );
    if (saved) widget.onChanged();
  }

  /// 停止重复（确认后停用模板，历史实例保留，FR-4.5）。
  Future<void> _stopRecurrence(BuildContext context, WidgetRef ref) async {
    final templateId = widget.task.recurrenceTemplateId;
    if (templateId == null) return;
    final confirmed = await confirmStopRecurrence(context);
    if (confirmed != true) return;
    if (!context.mounted) return;
    final repo = ref.read(recurrenceRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.stop(templateId),
    );
    if (!ok) return;
    ref.invalidate(recurrenceTemplatesProvider(widget.task.goalId));
    widget.onChanged();
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    // 编辑对话框需要该目标下的科目列表（含无科目选项）。
    final subjects = widget.subjects ??
        await ref.read(subjectListProvider(widget.task.goalId).future);
    final subjectList = subjects ?? const <Subject>[];
    if (!context.mounted) return;
    final saved = await TaskFormDialog.show(
      context,
      goalId: widget.task.goalId,
      task: widget.task,
      subjects: subjectList,
    );
    if (saved) widget.onChanged();
  }

  Future<void> _deferToNextAvailable(BuildContext context, WidgetRef ref) async {
    final settings = await ref.read(settingsProvider.future);
    if (!context.mounted) return;
    final today = ref.read(clockProvider)();
    final next = _defer.nextAvailableDate(
      today: today,
      availableWeekdays: SettingsRepository.decodeWeekdays(
        settings.availableWeekdays,
      ),
    );
    final repo = ref.read(taskRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.defer(widget.task.id, next),
    );
    if (ok) widget.onChanged();
  }

  Future<void> _deferPickDate(BuildContext context, WidgetRef ref) async {
    // 与 _deferToNextAvailable 一致：用注入时钟（clockProvider），保证
    // 测试可固定日期、跨午夜行为正确（此前直接用 DateTime.now()）。
    final now = ref.read(clockProvider)();
    // 延期语义（与今日页 FR-3.7 横幅一致，L40 口径）：只允许今天及之后，
    // 禁止改期到过去再次变逾期——此前 firstDate 为去年可把任务「延期」回
    // 过去，与横幅行为分裂（2026-08-14 审查 #1）。
    final first = DateUtils.dateOnly(now);
    // 任务计划日期可早于 firstDate（逾期一年以上是真实场景）：initialDate
    // 越界会在 debug 下触发 datepicker 断言、release 下落到错误初值，故钳制。
    final planned = parseLocalDate(widget.task.plannedDate);
    final initial = planned.isBefore(first) ? first : planned;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(now.year + 10),
      helpText: '选择延期日期',
    );
    if (picked == null) return;
    if (!context.mounted) return;
    final repo = ref.read(taskRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.defer(widget.task.id, formatLocalDate(picked)),
    );
    if (ok) widget.onChanged();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDeleteTask(context, widget.task.title);
    if (confirmed != true) return;
    if (!context.mounted) return;
    final repo = ref.read(taskRepositoryProvider);
    final ok = await runDbAction(
      context,
      action: () => repo.delete(widget.task.id),
    );
    if (ok) widget.onChanged();
  }
}

/// 删除任务二次确认（P3.4 收敛：TaskTile 与重复任务父卡片共用）。
Future<bool?> confirmDeleteTask(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('删除任务「$title」？'),
      content: const Text('此操作不可撤销。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
}

/// 停止重复二次确认（P3.4 收敛：TaskTile 与重复任务父卡片共用）。
Future<bool?> confirmStopRecurrence(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('停止重复？'),
      content: const Text('停止后不再生成新的重复任务，已生成的任务保留。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('停止重复'),
        ),
      ],
    ),
  );
}
