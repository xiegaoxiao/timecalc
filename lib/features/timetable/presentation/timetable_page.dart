import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/clock_provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/date_text.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/clash_hero.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../../../shared/widgets/hoverable_card.dart';
import '../../../shared/widgets/page_skeletons.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/course_repository_provider.dart';
import '../domain/class_period.dart';
import '../domain/course_week.dart';
import 'course_color.dart';
import 'course_detail_dialog.dart';
import 'course_form_dialog.dart';
import 'timetable_import_dialog.dart';

/// 作息表网格的几何参数（网格与节次标签列共用，保证逐行对齐）。
const double _rowHeight = 52;
const double _labelColumnWidth = 56;
const double _minDayColumnWidth = 96;

/// 课表页（FR-10）：一学期课程的教学周网格。
///
/// 结构（自上而下）：
/// 1. 工具区：导入/添加 + 更多菜单（主题默认按钮）；
/// 2. 撞色周次头区（`ClashHero`，冷色）：上一周/下一周 + 周次药丸 +
///    本周（暖色实心）/单双周指示；
/// 3. 副标题行：教学周日期范围 + 学期基准 + 本周摘要；
/// 4. 网格（白卡面板）：`ClassPeriods.count` 节 × 7 天，课程卡片按节次跨行、按冲突分列。
///
/// 撞色分工：**课程色**沿用既有调色板（`course_palette`/`course_color`），
/// 只作科目辨识色（左侧竖条 + 淡色底纹）；页面容器与状态色走撞色语言
/// （今日 = 暖，课表区块/当日列 = 冷）。
///
/// 数据是**外部给定的固定作息**，与「今天」页的任务闭环互不干扰：
/// 课程不参与负载、不计完成度，因此本页只读课表、不勾选完成。
class TimetablePage extends ConsumerStatefulWidget {
  const TimetablePage({super.key});

  @override
  ConsumerState<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends ConsumerState<TimetablePage> {
  /// 当前正在查看的教学周；null 表示跟随「今天」所在的教学周。
  int? _selectedWeek;

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(clockProvider)();
    final settingsAsync = ref.watch(settingsProvider);
    final coursesAsync = ref.watch(courseListProvider);

    final settings = settingsAsync.valueOrNull;
    final courses = coursesAsync.valueOrNull;
    if (settings == null || courses == null) {
      if (settingsAsync.hasError || coursesAsync.hasError) {
        return Scaffold(
          appBar: AppBar(title: const Text('课表')),
          body: AppErrorView(
            error: settingsAsync.hasError
                ? settingsAsync.error!
                : coursesAsync.error!,
            onRetry: () {
              ref.invalidate(settingsProvider);
              ref.invalidate(courseListProvider);
            },
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('课表')),
        body: PageSkeletons.cardColumn(count: 2, height: 260),
      );
    }

    // 教学周基准：脏值（手工改库/旧备份）当作未设置处理，不抛异常。
    final rawStart = settings.semesterStartDate;
    final semesterStart = rawStart == null ? null : tryParseLocalDate(rawStart);
    final currentWeek =
        semesterStart == null ? null : teachingWeekOf(semesterStart, today);
    // 尚未开学（第 1 周之前）时把「本周」定为第 1 周，网格不至于空白无解释。
    final lastWeek = _lastWeekOf(courses, currentWeek);
    final shownWeek = semesterStart == null
        ? null
        : _clamp(_selectedWeek ?? currentWeek ?? 1, 1, lastWeek);

    final visible = shownWeek == null
        ? courses
        : courses.where((c) => _isActiveInWeek(c, shownWeek)).toList();
    final isCurrentWeek = shownWeek != null && shownWeek == currentWeek;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ToolBar(
              onImport: _import,
              onAdd: _addCourse,
              onClear: courses.isEmpty ? null : _clearAll,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            _WeekHeader(
              shownWeek: shownWeek,
              isCurrentWeek: isCurrentWeek,
              onPrev: shownWeek == null
                  ? null
                  : () => setState(() => _selectedWeek = shownWeek - 1),
              onNext: shownWeek == null || shownWeek >= lastWeek
                  ? null
                  : () => setState(() => _selectedWeek = shownWeek + 1),
              onBackToCurrentWeek: () =>
                  setState(() => _selectedWeek = null),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            _SubHeader(
              semesterStart: semesterStart,
              shownWeek: shownWeek,
              today: today,
              courseCount: visible.length,
              periodCount: _periodCountOf(visible),
              onPickSemesterStart: _pickSemesterStart,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            if (courses.isEmpty)
              // 全空课表：给出与页面相关的首个操作（导入优先，手动添加兜底）。
              SizedBox(
                width: double.infinity,
                child: ClashEmptyState(
                  icon: Icons.calendar_view_week_outlined,
                  title: '还没有课程',
                  message: '导入课表文件（.ics / .json），或手动添加一门课',
                  tone: ClashTone.cool,
                  action: FilledButton.icon(
                    onPressed: _import,
                    icon: const Icon(Icons.upload_file_outlined, size: 18),
                    label: const Text('导入课表'),
                  ),
                ),
              )
            else if (visible.isEmpty)
              SizedBox(
                width: double.infinity,
                child: ClashEmptyState(
                  icon: Icons.beach_access_outlined,
                  title: '第 $shownWeek 教学周没有课',
                  message: '换一周看看，或检查课程的起止周设置',
                  tone: ClashTone.cool,
                ),
              )
            else
              // 网格浮在白卡上（契约：白卡浮于暖奶油底，撞色块浮于白卡）。
              HoverableCard(
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  child: _TimetableGrid(
                    courses: visible,
                    semesterStart: semesterStart,
                    shownWeek: shownWeek,
                    todayWeekday: isCurrentWeek ? today.weekday : null,
                    onTapCourse: (course) => _openCourse(course),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 网格可翻到的最后一周：课表里最晚的结束周（无课时用当前周兜底）。
  static int _lastWeekOf(List<Course> courses, int? currentWeek) {
    final last = latestWeekOf(courses.map((c) => c.endWeek));
    final fallback = currentWeek ?? 1;
    return last < fallback ? fallback : last;
  }

  /// 课程在第 [week] 教学周是否有课（周次区间 + 单双周）。
  static bool _isActiveInWeek(Course course, int week) {
    if (week < course.startWeek || week > course.endWeek) return false;
    return weekParityMatches(course.weekParity, week);
  }

  /// 本周课节数（一个「节次」算一节，与课表口径一致）。
  static int _periodCountOf(List<Course> courses) =>
      courses.fold(0, (sum, c) => sum + (c.endPeriod - c.startPeriod + 1));

  static int _clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  Future<void> _import() async {
    final imported = await TimetableImportDialog.show(context);
    if (imported == true) {
      ref.invalidate(courseListProvider);
      // 导入可能带出「第 1 周周一」的推导结果，设置一并失效。
      ref.invalidate(settingsProvider);
    }
  }

  Future<void> _addCourse() async {
    final saved = await CourseFormDialog.show(context);
    if (saved == true) ref.invalidate(courseListProvider);
  }

  Future<void> _openCourse(Course course) async {
    final changed = await CourseDetailDialog.show(context, course);
    if (changed == true) ref.invalidate(courseListProvider);
  }

  /// 设置/修改教学周基准（第 1 周周一）。
  ///
  /// 选任何一天都接受：归一化到所在周的周一后再入库，避免用户顺手选了
  /// 周三导致整学期周号偏移（course_week.mondayOf）。
  Future<void> _pickSemesterStart() async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final raw = settings?.semesterStartDate;
    final initial = (raw == null ? null : tryParseLocalDate(raw)) ??
        mondayOf(ref.read(clockProvider)());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择开学第 1 周的周一',
      fieldLabelText: '第 1 周周一',
    );
    if (picked == null) return;
    if (!mounted) return;
    final repo = ref.read(settingsRepositoryProvider);
    final normalized = formatLocalDate(mondayOf(picked));
    final ok = await _runWrite(
      () => repo.updateSemesterStartDate(normalized),
    );
    if (!ok) return;
    ref.invalidate(settingsProvider);
    setState(() => _selectedWeek = null);
  }

  /// 清空课表（不可逆，二次确认；设置与任务不受影响）。
  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空课表？'),
        content: const Text('将删除课表中的全部课程；任务、目标与学期设置保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final repo = ref.read(courseRepositoryProvider);
    final ok = await _runWrite(repo.deleteAll);
    if (!ok) return;
    ref.invalidate(courseListProvider);
    setState(() => _selectedWeek = null);
  }

  /// 走统一数据库错误守卫（失败弹「数据保存失败」并跳过后续刷新）。
  Future<bool> _runWrite(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error) {
      if (!mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('操作失败'),
          content: Text('$error'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return false;
    }
  }
}

/// 顶部工具区：导入课表 / 添加课程 / 更多菜单。
///
/// 按钮统一用主题默认样式（`filledButton` 暖实心 + `outlinedButton` 冷描边），
/// 不包 `styleFrom` 覆盖颜色——撞色由主题层统一供给（契约 §4）。
class _ToolBar extends StatelessWidget {
  const _ToolBar({
    required this.onImport,
    required this.onAdd,
    required this.onClear,
  });

  final VoidCallback onImport;
  final VoidCallback onAdd;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        FilledButton.icon(
          onPressed: onImport,
          icon: const Icon(Icons.upload_file_outlined, size: 18),
          label: const Text('导入课表'),
        ),
        const SizedBox(width: AppTokens.spaceSm),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加课程'),
        ),
        const Spacer(),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) {
            if (value == 'clear') onClear?.call();
          },
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              value: 'clear',
              enabled: onClear != null,
              child: const Text('清空课表'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 撞色周次头区：教学周切换 + 本周/单双周指示。
///
/// 撞色分工：课表属「数据 / 时间表」→ hero 用**冷**；「看的是不是本周」是
/// 主动作信息 → 当前周用**暖色实心药丸**，非当前周退化为可点的中性药丸，
/// 冷暖对冲形成结构性区分，而不是同色深浅。
///
/// 注意：hero 渐变上的文字/图标不能用主题前景色（深色主题下是深字压深底），
/// 一律取该撞色的 [ClashTones.onFill]；中性药丸浅色模式走默认 soft（不透明浅底
/// + 撞色深字），深色模式改用半透明白底 + 白字（浅底在暗渐变上看不出块形）。
/// 当前周指示保持 `filled` 暖实心（唯一的实心药丸，落在渐变冷端做冷暖对冲）。
class _WeekHeader extends StatelessWidget {
  const _WeekHeader({
    required this.shownWeek,
    required this.isCurrentWeek,
    required this.onPrev,
    required this.onNext,
    required this.onBackToCurrentWeek,
  });

  final int? shownWeek;
  final bool isCurrentWeek;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onBackToCurrentWeek;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onHero = ClashTones.of(context, ClashTone.cool).onFill;
    // 浅色模式：不传 → 中性药丸走默认 soft（不透明浅青底 + 深青字 11.15:1，
    // 块形对该模式下的深色渐变 ≥6:1），已是最优。
    // 深色模式：渐变与浅底药丸同为暗色，块形对比只剩 0.7~1.2:1 → 换成半透明白底
    // + 白字（文字仍 ≥5:1，且药丸边界可见）。两处都只取 token，无硬编码色。
    final pillForeground = isDark ? onHero : null;
    final pillBackground =
        isDark ? ClashTones.tint(onHero, alpha: 0.22) : null;
    final week = shownWeek;

    return ClashHero(
      tone: ClashTone.cool,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceMd,
      ),
      child: Row(
        children: [
          if (week == null)
            // 未设学期基准：无法按教学周筛选，退化为全部课程（仍是冷色中性药丸）。
            ClashChip(
              label: '全部课程',
              tone: ClashTone.cool,
              variant: ClashChipVariant.soft,
              icon: Icons.view_week_outlined,
              foreground: pillForeground,
              background: pillBackground,
            )
          else ...[
            IconButton(
              tooltip: '上一周',
              onPressed: onPrev,
              color: onHero,
              icon: const Icon(Icons.chevron_left),
            ),
            ClashChip(
              label: '第 $week 周',
              tone: ClashTone.cool,
              variant: ClashChipVariant.soft,
              foreground: pillForeground,
              background: pillBackground,
            ),
            IconButton(
              tooltip: '下一周',
              onPressed: onNext,
              color: onHero,
              icon: const Icon(Icons.chevron_right),
            ),
            const SizedBox(width: AppTokens.spaceMd),
            // 单双周指示：周次奇偶决定课程是否排课，是课表的结构性信息。
            ClashChip(
              label: week.isOdd ? '单周' : '双周',
              tone: ClashTone.cool,
              variant: ClashChipVariant.soft,
              dense: true,
              foreground: pillForeground,
              background: pillBackground,
            ),
          ],
          const Spacer(),
          if (isCurrentWeek)
            const ClashChip(
              label: '本周',
              tone: ClashTone.warm,
              variant: ClashChipVariant.filled,
              icon: Icons.today_outlined,
            )
          else if (week != null)
            ClashChip(
              label: '回到本周',
              tone: ClashTone.cool,
              variant: ClashChipVariant.soft,
              icon: Icons.history,
              foreground: pillForeground,
              background: pillBackground,
              onTap: onBackToCurrentWeek,
            ),
        ],
      ),
    );
  }
}

/// 副标题行：教学周日期范围 + 学期基准 + 本周摘要。
class _SubHeader extends StatelessWidget {
  const _SubHeader({
    required this.semesterStart,
    required this.shownWeek,
    required this.today,
    required this.courseCount,
    required this.periodCount,
    required this.onPickSemesterStart,
  });

  final DateTime? semesterStart;
  final int? shownWeek;
  final DateTime today;
  final int courseCount;
  final int periodCount;
  final VoidCallback onPickSemesterStart;

  @override
  Widget build(BuildContext context) {
    final start = semesterStart;
    final week = shownWeek;
    final dateRange = (start == null || week == null)
        ? null
        : _formatRange(mondayOfWeek(start, week));

    return Row(
      children: [
        if (dateRange != null) ...[
          Text(dateRange, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: AppTokens.spaceSm),
          Text(
            '· $courseCount 门课 · $periodCount 节',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else
          // 未设学期基准：说明为什么看不到周次（而非静默退化为「全部课程」）。
          Text(
            '设置开学第 1 周周一后，可按教学周查看',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const Spacer(),
        TextButton.icon(
          onPressed: onPickSemesterStart,
          icon: const Icon(Icons.event_outlined, size: 16),
          label: Text(
            start == null
                ? '设置开学日期'
                : '学期：${formatLocalDate(mondayOf(start))} 起',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// `9月14日 – 9月20日`（跨月时补月份）。
  static String _formatRange(DateTime monday) {
    final sunday = addLocalDays(monday, 6);
    if (monday.month == sunday.month) {
      return '${monday.month}月${monday.day}日 – ${sunday.day}日';
    }
    return '${monday.month}月${monday.day}日 – ${sunday.month}月${sunday.day}日';
  }
}

/// 教学周网格：左侧节次标签 + 7 天列，课程卡片按节次跨行、按冲突分列。
class _TimetableGrid extends StatelessWidget {
  const _TimetableGrid({
    required this.courses,
    required this.semesterStart,
    required this.shownWeek,
    required this.todayWeekday,
    required this.onTapCourse,
  });

  final List<Course> courses;
  final DateTime? semesterStart;
  final int? shownWeek;

  /// 「今天」的星期（1~7）；仅在展示当前教学周时非 null。
  final int? todayWeekday;
  final ValueChanged<Course> onTapCourse;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄窗（含手机宽度）下 7 列会被压到不可读，故给列宽设下限并允许
        // 横向滚动：整块网格滚动，节次标签列跟随固定，保证行仍然对齐。
        final available = constraints.maxWidth - _labelColumnWidth;
        final columnWidth = available / 7 < _minDayColumnWidth
            ? _minDayColumnWidth
            : available / 7;
        final gridWidth = _labelColumnWidth + columnWidth * 7;

        final grid = SizedBox(
          width: gridWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDayHeader(context, columnWidth),
              const SizedBox(height: AppTokens.spaceXs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPeriodLabels(context),
                  for (var day = 1; day <= 7; day++)
                    SizedBox(
                      width: columnWidth,
                      child: _DayColumn(
                        columnWidth: columnWidth,
                        courses: courses
                            .where((c) => c.weekday == day)
                            .toList(growable: false),
                        isToday: todayWeekday == day,
                        onTapCourse: onTapCourse,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );

        if (gridWidth <= constraints.maxWidth) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: grid,
        );
      },
    );
  }

  Widget _buildDayHeader(BuildContext context, double columnWidth) {
    final scheme = Theme.of(context).colorScheme;
    final warm = ClashTones.of(context, ClashTone.warm);
    final start = semesterStart;
    final week = shownWeek;
    return Row(
      children: [
        const SizedBox(width: _labelColumnWidth),
        for (var day = 1; day <= 7; day++)
          SizedBox(
            width: columnWidth,
            child: Column(
              children: [
                Text(
                  '周${kWeekdayLabels[day - 1]}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: todayWeekday == day
                        ? FontWeight.w700
                        : FontWeight.w600,
                    // 今日 = 暖（契约 §1）；ink 是压底文字的安全取色。
                    color: todayWeekday == day
                        ? warm.ink
                        : scheme.onSurfaceVariant,
                  ),
                ),
                // 日期：有教学周基准才算得出来（无基准时只显示星期）。
                if (start != null && week != null)
                  Text(
                    '${addLocalDays(mondayOfWeek(start, week), day - 1).day}',
                    style: TextStyle(
                      fontSize: 11,
                      color: todayWeekday == day
                          ? warm.ink
                          : scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 节次标签列：节号 + 起止钟点（钟点是网格的行定义，见 ClassPeriods）。
  Widget _buildPeriodLabels(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _labelColumnWidth,
      child: Column(
        children: [
          for (var period = 1; period <= ClassPeriods.count; period++)
            SizedBox(
              height: _rowHeight,
              child: Padding(
                padding: const EdgeInsets.only(right: AppTokens.spaceSm),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$period',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (ClassPeriods.byIndex(period) case final p?)
                      Text(
                        p.start,
                        style: TextStyle(
                          fontSize: 9,
                          color: scheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单天列：逐节次画分隔线，课程卡片按冲突分列叠放。
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.columnWidth,
    required this.courses,
    required this.isToday,
    required this.onTapCourse,
  });

  final double columnWidth;
  final List<Course> courses;
  final bool isToday;
  final ValueChanged<Course> onTapCourse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cool = ClashTones.of(context, ClashTone.cool);
    final lanes = _assignLanes(courses);
    final laneCount = lanes.isEmpty ? 1 : lanes.length;
    final laneWidth = columnWidth / laneCount;

    return SizedBox(
      height: _rowHeight * ClassPeriods.count,
      child: Stack(
        children: [
          // 行分隔线（网格骨架）：课程未占满时也能看清节次位置。
          // 当日列铺冷藏青淡底（冷 = 课表/日历）。
          for (var period = 0; period < ClassPeriods.count; period++)
            Positioned(
              left: 0,
              right: 0,
              top: period * _rowHeight,
              child: Container(
                height: _rowHeight,
                decoration: BoxDecoration(
                  color: isToday ? ClashTones.tint(cool.ink, alpha: 0.08) : null,
                  border: Border(
                    bottom: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          for (var lane = 0; lane < lanes.length; lane++)
            for (final course in lanes[lane])
              Positioned(
                left: lane * laneWidth + 2,
                width: laneWidth - 4,
                top: (course.startPeriod - 1) * _rowHeight + 2,
                height:
                    (course.endPeriod - course.startPeriod + 1) * _rowHeight - 4,
                child: _CourseBlock(
                  course: course,
                  onTap: () => onTapCourse(course),
                ),
              ),
        ],
      ),
    );
  }

  /// 把同一天的课程分配到「无重叠的列」（贪心区间着色）。
  ///
  /// 同时段两门课（如限选撞课）必须都看得见，所以不做「后到覆盖先到」，
  /// 而是并排缩窄；这是课表视图的通行做法。返回的每个子列表即一列，
  /// 列内课程按时间递增（[Course.startPeriod] 已由仓库排序）。
  static List<List<Course>> _assignLanes(List<Course> courses) {
    final sorted = [...courses]..sort(
        (a, b) => a.startPeriod != b.startPeriod
            ? a.startPeriod - b.startPeriod
            : a.endPeriod - b.endPeriod,
      );
    final lanes = <List<Course>>[];
    for (final course in sorted) {
      List<Course>? target;
      for (final lane in lanes) {
        if (lane.last.endPeriod < course.startPeriod) {
          target = lane;
          break;
        }
      }
      if (target == null) {
        lanes.add([course]);
      } else {
        target.add(course);
      }
    }
    return lanes;
  }
}

/// 课程卡片：课程色竖条 + 标题 + 可容纳的地点/教师副行（按可用高度决定展示几行）。
///
/// 撞色分工：**课程色只作辨识色**（左侧 3px 竖条 + 淡色底纹，沿用
/// `course_palette`/`course_color`，不并入撞色——否则会丢掉课表的科目辨识度），
/// 卡片**容器**统一走卡语言（[AppTokens.radiusLg] 圆角 + 暖调细边框 +
/// [AppTokens.shadowCard]），卡片内文字一律用主题前景色
/// （`onSurface` / `onSurfaceVariant`），因此深浅色模式下对比度都不依赖课程色。
class _CourseBlock extends StatelessWidget {
  const _CourseBlock({required this.course, required this.onTap});

  final Course course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final accent = courseColorOf(course.color);
    final titleStyle = theme.textTheme.bodySmall?.copyWith(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
          color: scheme.onSurface,
        );
    final subStyle = theme.textTheme.bodySmall?.copyWith(
          fontSize: 10,
          height: 1.2,
          color: scheme.onSurfaceVariant,
        );

    final span = course.endPeriod - course.startPeriod + 1;
    // 卡片高度决定信息密度：1 节的块放不下副行，2 节起放一行，4 节放两行。
    final subLines = <String>[
      if (course.location != null) course.location!,
      if (course.teacher != null) course.teacher!,
    ];
    final maxSubLines = span >= 4 ? 2 : (span >= 2 ? 1 : 0);
    final subtitle = subLines.take(maxSubLines).join(' · ');

    return Semantics(
      button: true,
      label: '${course.title}，${weekdayLabel(course.weekday) ?? ''} '
          '${ClassPeriods.rangeLabel(course.startPeriod, course.endPeriod)}'
          '${course.location == null ? '' : '，${course.location}'}',
      child: Container(
        decoration: BoxDecoration(
          // 课程色淡底纹：保留既有调色板的科目辨识度。
          color: courseTint(accent, theme.brightness),
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          // 暖调细边框：与主题卡片同一语言（不写死颜色）。
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: AppTokens.shadowCard(isDark),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 课程色竖条：科目辨识色在卡片上的唯一实心出现点。
                Container(width: 3, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.spaceXs + 2,
                      vertical: AppTokens.spaceXs,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          course.title,
                          style: titleStyle,
                          maxLines: span >= 2 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: subStyle,
                            maxLines: maxSubLines,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
