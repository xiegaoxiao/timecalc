import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/app_dialog.dart';
import '../data/course_repository_provider.dart';
import '../domain/class_period.dart';
import '../domain/course_week.dart';
import 'course_color.dart';
import 'course_form_dialog.dart';

/// 课程详情（点击网格中的课程卡片弹出）。
///
/// 网格里一节课的卡片空间有限（只够标题 + 地点），详情把教师、类别、备注
/// 与「第几周 / 星期几 / 第几节 / 钟点」的完整语义补齐，并承载编辑与删除
/// 两个动作。删除不可逆，用二次确认对话框（与科目/目标删除同款）。
class CourseDetailDialog extends ConsumerWidget {
  const CourseDetailDialog({super.key, required this.course});

  final Course course;

  /// 返回 true 表示课程已被修改或删除（调用方据此刷新）。
  static Future<bool?> show(BuildContext context, Course course) {
    return AppDialog.show<bool>(
      context,
      title: course.title,
      titleIcon: Icons.class_outlined,
      maxWidth: 420,
      content: CourseDetailDialog(course: course),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = courseColorOf(course.color);
    final timeRange = ClassPeriods.timeRangeLabel(
      course.startPeriod,
      course.endPeriod,
    );
    final rows = <(IconData, String, String)>[
      (
        Icons.schedule_outlined,
        '时间',
        '${weekRangeLabel(course.startWeek, course.endWeek, course.weekParity)}'
            ' · ${weekdayLabel(course.weekday) ?? ''} '
            '${ClassPeriods.rangeLabel(course.startPeriod, course.endPeriod)}'
            '${timeRange == null ? '' : '（$timeRange）'}',
      ),
      if (course.location != null)
        (Icons.place_outlined, '地点', course.location!),
      if (course.teacher != null)
        (Icons.person_outline, '教师', course.teacher!),
      if (course.category != null)
        (Icons.sell_outlined, '类别', course.category!),
      if (course.note != null) (Icons.notes_outlined, '备注', course.note!),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (icon, label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 18,
                  margin: const EdgeInsets.only(
                    top: 2,
                    right: AppTokens.spaceSm,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppTokens.spaceSm),
                SizedBox(
                  width: 36,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(value, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppTokens.spaceXs),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => _delete(context, ref),
              icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
              label: Text('删除', style: TextStyle(color: scheme.error)),
            ),
            const Spacer(),
            FilledButton.tonal(
              onPressed: () => _edit(context, ref),
              child: const Text('编辑'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final navigator = Navigator.of(context);
    navigator.pop(); // 先关详情，避免表单叠在详情之上。
    final saved = await CourseFormDialog.show(context, initial: course);
    if (saved == true) ref.invalidate(courseListProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除课程「${course.title}」？'),
        content: const Text('从课表中移除这门课，不影响任务与目标。'),
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
    if (confirmed != true) return;
    if (!context.mounted) return;
    final ok = await runDbAction(
      context,
      action: () => ref.read(courseRepositoryProvider).delete(course.id),
    );
    if (!ok) return;
    ref.invalidate(courseListProvider);
    navigator.pop(true);
  }
}
