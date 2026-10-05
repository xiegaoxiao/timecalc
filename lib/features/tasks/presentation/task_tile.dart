import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../core/utils/time_text.dart';
import '../../../services/defer_service.dart';
import '../../../services/duration_format.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../../shared/widgets/completion_checkbox.dart';
import '../../goals/data/subject_repository_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/recurrence_repository_provider.dart';
import '../data/task_completion_controller.dart';
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
    this.enableCompleteUndo = false,
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

  /// 是否启用「勾选完成 + 5 秒撤回」交互（今天页专用）。
  ///
  /// 启用后勾选不立即写库，先进入 [taskCompletionControllerProvider] 的
  /// 待完成批次，5 秒内可整批撤回、到期才定稿；其余页面保持即时完成。
  final bool enableCompleteUndo;

  @override
  ConsumerState<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends ConsumerState<TaskTile> {
  static const _defer = DeferService();

  /// 乐观完成态（2026-08-15 性能优化）：点击复选框立即反映到 UI，不等
  /// 数据库写入 + Provider 刷新往返——避免「点了没反应 → 数据回来后整行
  /// 猛然划线」的掉帧/延迟感。数据刷新确认后由 [didUpdateWidget] 清除。
  bool? _optimisticDone;

  /// 桌面端行 hover 态（撞色 v2）：hover 时行底铺撞色淡底 + 抬升投影。
  /// 只影响本行的 [AnimatedContainer]，不重建父级列表。
  bool _hovered = false;

  /// 真实/乐观完成态（不含「5 秒撤回」待定稿批次：后者在 build 中单独并入，
  /// [_toggle] 里按批次成员单独判断，避免在非 build 上下文里 watch）。
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

  /// 完成/取消完成切换：
  ///
  /// - 今天页（[widget.enableCompleteUndo]）：勾选进入 5 秒撤回批次（不写库，
  ///   由 [TaskCompletionController] 统一定稿/撤回）；再点取消勾选待完成任务
  ///   直接移出批次，取消勾选已定稿任务才写库。
  /// - 其余页面：乐观更新 + 数据落地后统一刷新（原行为）。
  Future<void> _toggle(bool? value) async {
    final target = value ?? false;
    final controller = ref.read(taskCompletionControllerProvider.notifier);

    if (widget.enableCompleteUndo) {
      final statusDone = widget.task.status == TaskStatus.done;
      final pendingThis = controller.isPending(widget.task.id);
      if (target) {
        if (!statusDone && !pendingThis) {
          // FR-4.1：勾选完成且存在未完成检查项时二次确认。
          final proceed = await confirmCompleteTask(context, ref, widget.task);
          if (!proceed) return;
          if (!mounted) return;
          controller.check(widget.task.id);
        }
      } else {
        if (pendingThis) {
          // 撤回该单个任务（未写库，移出批次即可）。
          controller.remove(widget.task.id);
        } else if (statusDone) {
          // 已定稿完成 → 写库取消完成。
          setState(() => _optimisticDone = false);
          final repo = ref.read(taskRepositoryProvider);
          final ok = await runDbAction(
            context,
            action: () => repo.setDone(widget.task.id, false),
          );
          if (ok) {
            widget.onChanged();
          } else if (mounted) {
            setState(() => _optimisticDone = null);
          }
        }
      }
      return;
    }

    // 非今天页：原即时完成/取消逻辑（乐观更新 + 写库 + 刷新）。
    if (value == true && !_done) {
      // FR-4.1：勾选完成且存在未完成检查项时二次确认。
      final proceed = await confirmCompleteTask(context, ref, widget.task);
      if (!proceed) return;
      if (!mounted) return;
    }
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
    // 今天页「5 秒撤回」：勾选后先进入待完成批次（不写库），批次内视为
    // 已勾选显示；其余页面不启用该行为，维持原即时完成逻辑。
    // watch 用 select 收窄到「本任务是否在批次内」（2026-08-16 性能优化）：
    // 批次集合变化时只有成员关系变化的任务行重建，而不是全部行。
    final statusDone = widget.task.status == TaskStatus.done;
    final pendingThis =
        widget.enableCompleteUndo &&
        ref.watch(
          taskCompletionControllerProvider.select(
            (s) => s.contains(widget.task.id),
          ),
        );
    // 定稿显示态：5 秒到期后（写库 → 数据落地之间）保持勾选，消除
    // 「闪回未勾选 → 重新划线」的双段动画。
    final finalizingThis =
        widget.enableCompleteUndo &&
        ref.watch(
          taskFinalizingProvider.select((s) => s.contains(widget.task.id)),
        );
    final done =
        _optimisticDone ?? (pendingThis || finalizingThis || statusDone);

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

    // 副标题元信息 chips（2026-08-16 视觉升级）：目标/科目/计划日期/时长
    // 由「· 拼接长文本」改为小 chip，替代 Material 默认的密集文字感；
    // 计划时刻（schema v16）作为独立 chip 展示：列表已按日期分组时
    // （今日页/日历日面板，showPlannedDate=false）只显示「20:00」，
    // 跨日期的列表（目标任务页）则与日期合并为「2026-08-05 20:00」。
    final startTime = tryNormalizeTimeOfDay(widget.task.startTime);
    final plannedDateText = widget.showPlannedDate
        ? formatLocalDate(parseLocalDate(widget.task.plannedDate))
        : null;
    // 行状态（撞色 v2）：待办=暖、已完成=点缀（citrus）、逾期=危险（danger）。
    // 逾期按「未完成且计划日期早于今天」判定（注入时钟，测试可固定日期）。
    final planned = parseLocalDate(widget.task.plannedDate);
    final today = DateUtils.dateOnly(ref.watch(clockProvider)());
    final overdue = !done && planned.isBefore(today);
    final tone = done
        ? ClashTone.citrus
        : (overdue ? ClashTone.danger : ClashTone.warm);
    final t = ClashTones.of(context, tone);

    // 元信息药丸（撞色 v2）：目标=暖、日期/时刻/科目=冷、时长=点缀，
    // 逾期额外给一枚危险药丸——状态在颜色之外仍有文字/图标承载（NFR-4）。
    final metaChips = <Widget>[
      if (widget.goalTitle != null)
        _metaChip(label: widget.goalTitle!, tone: ClashTone.warm),
      if (plannedDateText != null && startTime != null)
        _metaChip(
          label: '$plannedDateText $startTime',
          tone: ClashTone.cool,
          icon: Icons.event_outlined,
        )
      else if (plannedDateText != null)
        _metaChip(
          label: plannedDateText,
          tone: ClashTone.cool,
          icon: Icons.event_outlined,
        )
      else if (startTime != null)
        _metaChip(
          label: startTime,
          tone: ClashTone.cool,
          icon: Icons.schedule_outlined,
        ),
      if (subjectName != null)
        _metaChip(
          label: subjectName,
          tone: ClashTone.cool,
          icon: Icons.book_outlined,
        ),
      if (widget.task.estimatedMinutes != null)
        _metaChip(
          label: DurationFormat.minutes(widget.task.estimatedMinutes!),
          tone: ClashTone.citrus,
          icon: Icons.timer_outlined,
        ),
      if (overdue)
        _metaChip(
          label: '逾期',
          tone: ClashTone.danger,
          icon: Icons.error_outline,
        ),
    ];
    final hasNote = widget.task.note?.isNotEmpty ?? false;

    return AnimatedOpacity(
      // 完成态整行轻微降透明（配合划线），过渡 200ms 平滑不跳变。
      duration: const Duration(milliseconds: 200),
      opacity: done ? 0.72 : 1.0,
      // 单卡列表行（2026-08-16 视觉升级）：TaskTile 自身不再包 Card，
      // 由外层列表容器提供统一卡片 + 行间分隔线（今天页/计划页/目标页）。
      // 撞色 v2：行内左侧为撞色状态竖条，hover 时行底铺撞色淡底 + 抬升投影
      // （ClashTones.tint + AppTokens.shadowCardHover）。
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: AppTokens.motionNormal,
          curve: AppTokens.motionCurve,
          decoration: BoxDecoration(
            color: _hovered
                ? ClashTones.tint(t.ink, alpha: 0.06)
                : Colors.transparent,
            boxShadow: _hovered
                ? AppTokens.shadowCardHover(
                    Theme.of(context).brightness == Brightness.dark,
                  )
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceSm,
              AppTokens.spaceSm,
              AppTokens.spaceXs,
              AppTokens.spaceSm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 撞色状态竖条（行色标）：待办=暖 / 已完成=点缀 / 逾期=危险。
                AnimatedContainer(
                  duration: AppTokens.motionNormal,
                  curve: AppTokens.motionCurve,
                  width: 3.5,
                  height: 36,
                  decoration: BoxDecoration(
                    color: t.ink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceXs),
                CompletionCheckbox(
                  value: done,
                  // 读屏可读的名称（NFR-4）：任务完成复选框不依赖相邻文本推断。
                  semanticLabel: done ? '标记未完成' : '标记完成',
                  onChanged: _toggle,
                ),
                const SizedBox(width: AppTokens.spaceXs),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: AnimatedDefaultTextStyle(
                              // 完成划线 + 颜色过渡：勾选后平滑地划掉，而非跳变。
                              duration: AppTokens.motionNormal,
                              curve: AppTokens.motionCurve,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                decoration: done
                                    ? TextDecoration.lineThrough
                                    : TextDecoration.none,
                                color: done
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                              child: Text(
                                widget.task.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          // 重复任务徽标（fr-4）：撞色药丸 + 原 tooltip 语义保留。
                          if (widget.task.recurrenceTemplateId != null) ...[
                            const SizedBox(width: AppTokens.spaceXs),
                            const Tooltip(
                              message: '重复任务',
                              child: ClashChip(
                                label: '重复',
                                icon: Icons.autorenew,
                                tone: ClashTone.citrus,
                                variant: ClashChipVariant.soft,
                                dense: true,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (metaChips.isNotEmpty || hasNote) ...[
                        const SizedBox(height: AppTokens.spaceXs),
                        if (metaChips.isNotEmpty)
                          Wrap(
                            spacing: AppTokens.spaceXs,
                            runSpacing: AppTokens.spaceXs,
                            children: metaChips,
                          ),
                        if (hasNote)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: AppTokens.spaceXs,
                            ),
                            child: Text(
                              widget.task.note!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '任务操作',
                  iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  onSelected: (action) => _handleAction(context, ref, action),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    const PopupMenuItem(
                      value: 'checklist',
                      child: Text('检查项…'),
                    ),
                    const PopupMenuItem(
                      value: 'deferNext',
                      child: Text('延期至下一可用日'),
                    ),
                    const PopupMenuItem(
                      value: 'deferPick',
                      child: Text('延期…'),
                    ),
                    if (widget.task.recurrenceTemplateId != null) ...[
                      const PopupMenuItem(
                        value: 'editRecurrence',
                        child: Text('编辑重复规则'),
                      ),
                      const PopupMenuItem(
                        value: 'stopRecurrence',
                        child: Text('停止重复'),
                      ),
                    ],
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
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
    final template = await ref.read(
      recurrenceTemplateProvider(templateId).future,
    );
    if (template == null || !context.mounted) return;
    final subjects =
        widget.subjects ??
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
    final ok = await runDbAction(context, action: () => repo.stop(templateId));
    if (!ok) return;
    ref.invalidate(recurrenceTemplatesProvider(widget.task.goalId));
    widget.onChanged();
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    // 编辑对话框需要该目标下的科目列表（含无科目选项）。
    final subjects =
        widget.subjects ??
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

  Future<void> _deferToNextAvailable(
    BuildContext context,
    WidgetRef ref,
  ) async {
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

/// 任务行元信息药丸（撞色 v2）：目标/科目/计划日期/计划时刻/时长/逾期。
///
/// 替代此前自绘的浅灰小 chip——统一走 [ClashChip]（soft 浅底 + 撞色文字），
/// 信息密度不变但每枚药丸带自己的撞色语义（目标=暖、日期/科目=冷、
/// 时长=点缀、逾期=危险），列表整体形成撞色节奏。
///
/// **长度保护**：目标名可能很长（如「28考研数学全程计划（零基础冲140+）」），
/// 而任务行会出现在窄容器里（日历日面板仅约 330px）。`Wrap` 给子项的横向
/// 约束是无界的，药丸按内容自适应就会直接抛 `RenderFlex overflow`。
/// 因此这里给每枚药丸一个宽度上限并允许省略（`flexible`），保证任何父级
/// 宽度下都不溢出；[maxWidth] 由各调用点按信息重要性给出。
Widget _metaChip({
  required String label,
  required ClashTone tone,
  IconData? icon,
  double maxWidth = 220,
}) {
  return ClashChip(
    label: label,
    tone: tone,
    icon: icon,
    variant: ClashChipVariant.soft,
    dense: true,
    flexible: true,
    maxWidth: maxWidth,
  );
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
        // 危险动作（撞色 v2）：删除按钮走 ClashTone.danger，而非主色实心——
        // 与「取消」形成明确的语义分离（颜色之外仍有「删除」文案承载）。
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: ClashTones.of(context, ClashTone.danger).fill,
            foregroundColor: ClashTones.of(context, ClashTone.danger).onFill,
          ),
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
