import 'dart:convert';

import '../../tasks/domain/task_import_parser.dart' show ImportIssue;

/// 单个待导入的里程碑（目标下的阶段性节点，FR-2 语义）。
///
/// 由层级计划中的 `stages`（阶段）与每周 `focus`（周节点）生成。
class ImportedMilestone {
  const ImportedMilestone({required this.title, required this.date});

  final String title;

  /// 本地日历日期（yyyy-MM-dd），已通过格式/有效性校验，且不晚于目标截止日。
  final String date;
}

/// 单个待导入的任务（daily_breakdown 或 unclassified）。
///
/// [subjectName] 为 null 表示未分类任务（unclassified 来源）。
class ImportedPlanTask {
  const ImportedPlanTask({
    required this.title,
    required this.date,
    this.subjectName,
    this.note,
    this.minutes,
  });

  final String title;
  final String date;

  /// 归属科目名；null 表示未分类任务。
  final String? subjectName;

  /// 任务备注（unclassified 来源的 note 字段；daily_breakdown 无此字段）。
  final String? note;

  /// 预估时长（分钟，1～1440）；未设置为 null。
  ///
  /// 完整计划 JSON 的 `minutes` 字段（与 JSON 任务导入对齐）：进度页的
  /// 剩余工作量趋势 / 任务耗时图只统计带预估时长的任务（FR-7.4），
  /// 不设置则导入的任务不进入进度统计。
  final int? minutes;
}

/// 单个待导入的「每天」重复模板（每周 daily_must_do 一条）。
///
/// 规则固定为「每天」：ruleType `daily`、ruleJson `{}`（无参数），
/// 覆盖 [startDate] ~ [endDate]（该周的 7 天）。[minutes] 为每条实例的
/// 预估时长（继承到所有生成的实例，进度页统计用，FR-7.4）。
class ImportedPlanTemplate {
  const ImportedPlanTemplate({
    required this.title,
    required this.startDate,
    required this.endDate,
    this.minutes,
  });

  final String title;
  final String startDate;
  final String endDate;

  /// 每条实例的预估时长（分钟，1～1440）；未设置为 null。
  final int? minutes;

  /// 固定「每天」规则类型与参数。
  static const ruleType = 'daily';
  static const ruleJson = '{}';
}

/// 解析通过的完整计划：目标 + 里程碑 + 科目任务 + 重复模板。
class ImportedPlan {
  const ImportedPlan({
    required this.goalTitle,
    required this.deadlineDate,
    required this.milestones,
    required this.tasks,
    required this.templates,
    required this.subjectOrder,
    this.skippedTasks = 0,
    this.skippedTemplates = 0,
  });

  /// 目标标题（plan_name）。
  final String goalTitle;

  /// 目标截止日（end_date，yyyy-MM-dd）。
  final String deadlineDate;

  final List<ImportedMilestone> milestones;

  /// 全部任务（科目任务 + 未分类任务，subjectName 区分）。
  final List<ImportedPlanTask> tasks;

  final List<ImportedPlanTemplate> templates;

  /// 科目出现顺序（预览分组用）。
  final List<String> subjectOrder;

  /// 早于今天被跳过的任务数（255 条量大，整体报错不现实，跳过并统计）。
  final int skippedTasks;

  /// 整周已过去（endDate < today）被跳过的模板数。
  final int skippedTemplates;
}

/// 解析结果：全部通过才携带 [plan]（与 TaskImportParser 同契约）。
class PlanImportResult {
  const PlanImportResult({this.plan, this.issues = const []});

  final ImportedPlan? plan;
  final List<ImportIssue> issues;

  bool get isValid => plan != null && issues.isEmpty;
}

/// 层级 JSON 完整计划解析与校验。
///
/// 纯 Dart service，不依赖数据库与 UI。支持「计划书」式结构：
///
/// ```json
/// {
///   "plan_name": "2027考研数学备考计划",
///   "start_date": "2026-08-09",
///   "end_date": "2026-12-18",
///   "stages": [
///     {
///       "stage": "强化阶段",
///       "weekly_plan": [
///         {
///           "week": 1,
///           "week_range": "2026-08-09 ~ 2026-08-15",
///           "focus": "真题套卷",
///           "subjects": {
///             "高等数学": {
///               "daily_breakdown": {
///                 "2026-08-09": { "title": "武忠祥讲义：三重积分（听课+例题）", "minutes": 180 }
///               }
///             },
///             "daily_must_do": [
///               { "title": "完成《三大计算》积分专项", "minutes": 30 }
///             ]
///           }
///         }
///       ]
///     }
///   ],
///   "unclassified": [
///     { "title": "复盘本周错题", "date": "2026-08-10", "note": "每周日复盘", "minutes": 90 }
///   ]
/// }
/// ```
///
/// 结构映射：
/// - `plan_name` → 目标标题；`end_date` → 目标截止日；
/// - `stages[].stage` → 阶段里程碑；`weekly_plan[].focus` → 周里程碑
///   （标题「第 N 周：focus」），日期取 `week_range` 起点；
/// - `subjects.<科目>.daily_breakdown`（date 为键）→ 科目任务。值为文本
///   （历史写法）或对象 `{ "title": ..., "minutes": 180 }`；
/// - `subjects.daily_must_do`（每周数组）→ 每条生成一个「每天」重复模板，
///   覆盖该周 7 天。条目为文本（历史写法）或对象
///   `{ "title": ..., "minutes": 30 }`（时长继承到每条实例）；
/// - `unclassified` → 未分类任务（note 落库，`minutes` 可带预估时长）。
///
/// 校验（错误全收集 + location 定位，任一结构性错误则整体不通过）：
/// - plan_name 必填且 ≤200 字；end_date 必填、yyyy-MM-dd 有效且 ≥ start_date；
/// - 里程碑 date 有效且不晚于目标截止日（FR-2.2 同款，导入侧补上）；
/// - 任务 title ≤200 字、date 有效；`minutes` 为整数 1～1440（与 JSON
///   任务导入同契约）；
/// - 日期策略：**早于今天的任务自动跳过并计入统计**（量大不整体报错），
///   模板整周已过去（endDate < today）同样跳过；里程碑/目标日期宽松不跳过
///   （计划含历史期是正常的）。
class PlanImportParser {
  const PlanImportParser();

  PlanImportResult parse(String source, {required DateTime today}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      return PlanImportResult(
        issues: [ImportIssue('JSON 格式不合法：${e.message}')],
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const PlanImportResult(
        issues: [ImportIssue('JSON 顶层必须是对象 { ... }')],
      );
    }

    final issues = <ImportIssue>[];
    final todayStr = _format(today);

    // 目标：plan_name + end_date。
    final goalTitle = _readTitle(decoded['plan_name']);
    if (goalTitle == null) {
      issues.add(const ImportIssue('plan_name 必填且不能为空'));
    } else if (goalTitle.length > 200) {
      issues.add(const ImportIssue('plan_name 不能超过 200 字'));
    }
    final deadlineDate = _readDate(decoded['end_date']);
    if (deadlineDate == null) {
      issues.add(const ImportIssue('end_date 必填，格式 yyyy-MM-dd'));
    }
    if (deadlineDate != null) {
      final startRaw = decoded['start_date'];
      if (startRaw is String) {
        final startDate = _parseDate(startRaw);
        if (startDate == null) {
          issues.add(ImportIssue('start_date 不是有效日期（$startRaw）'));
        } else if (startDate.compareTo(deadlineDate) > 0) {
          issues.add(const ImportIssue('end_date 不能早于 start_date'));
        }
      }
    }

    // 里程碑与任务、模板。
    final milestones = <ImportedMilestone>[];
    final tasks = <ImportedPlanTask>[];
    final templates = <ImportedPlanTemplate>[];
    final subjectOrder = <String>[];
    final subjectSeen = <String>{};
    var skippedTasks = 0;
    var skippedTemplates = 0;

    final stagesValue = decoded['stages'];
    if (stagesValue != null) {
      if (stagesValue is! List) {
        issues.add(const ImportIssue('stages 必须是数组'));
      } else {
        for (var si = 0; si < stagesValue.length; si++) {
          final stage = stagesValue[si];
          if (stage is! Map<String, dynamic>) {
            issues.add(ImportIssue('stages 第 ${si + 1} 项必须是对象'));
            continue;
          }
          _parseStage(
            stage,
            issues: issues,
            todayStr: todayStr,
            deadlineDate: deadlineDate,
            milestones: milestones,
            tasks: tasks,
            templates: templates,
            subjectOrder: subjectOrder,
            subjectSeen: subjectSeen,
            onSkipTask: () => skippedTasks++,
            onSkipTemplate: () => skippedTemplates++,
          );
        }
      }
    }

    // unclassified：未分类任务（note 落库）。
    final unclassifiedValue = decoded['unclassified'];
    if (unclassifiedValue != null) {
      if (unclassifiedValue is! List) {
        issues.add(const ImportIssue('unclassified 必须是任务数组'));
      } else {
        for (var i = 0; i < unclassifiedValue.length; i++) {
          final raw = unclassifiedValue[i];
          final location = '未分类 · 第 ${i + 1} 项';
          if (raw is! Map<String, dynamic>) {
            issues.add(
              ImportIssue('必须是对象 { "title": ..., "date": ... }', location: location),
            );
            continue;
          }
          final title = _readTitle(raw['title']);
          if (title == null) {
            issues.add(ImportIssue('title 必填且不能为空', location: location));
            continue;
          }
          if (title.length > 200) {
            issues.add(ImportIssue('title 不能超过 200 字', location: location));
            continue;
          }
          final date = _readDate(raw['date']);
          if (date == null) {
            issues.add(ImportIssue('date 必填，格式 yyyy-MM-dd', location: location));
            continue;
          }
          if (date.compareTo(todayStr) < 0) {
            skippedTasks++;
            continue;
          }
          final minutes = _readMinutes(
            raw['minutes'],
            location: location,
            issues: issues,
          );
          final note = raw['note'];
          tasks.add(ImportedPlanTask(
            title: title,
            date: date,
            subjectName: null,
            note: note is String && note.trim().isNotEmpty ? note.trim() : null,
            minutes: minutes,
          ));
        }
      }
    }

    if (issues.isNotEmpty) {
      return PlanImportResult(issues: issues);
    }
    if (goalTitle == null || deadlineDate == null) {
      // 理论上 issues 已拦截，防御性兜底。
      return PlanImportResult(issues: issues);
    }
    if (milestones.isEmpty && tasks.isEmpty && templates.isEmpty) {
      return const PlanImportResult(
        issues: [ImportIssue('没有可导入的内容（stages 或 unclassified 至少提供一项）')],
      );
    }
    return PlanImportResult(
      plan: ImportedPlan(
        goalTitle: goalTitle,
        deadlineDate: deadlineDate,
        milestones: milestones,
        tasks: tasks,
        templates: templates,
        subjectOrder: subjectOrder,
        skippedTasks: skippedTasks,
        skippedTemplates: skippedTemplates,
      ),
    );
  }

  /// 解析单个阶段：阶段里程碑 + 各周（周里程碑/科目任务/每周例行模板）。
  void _parseStage(
    Map<String, dynamic> stage, {
    required List<ImportIssue> issues,
    required String todayStr,
    required String? deadlineDate,
    required List<ImportedMilestone> milestones,
    required List<ImportedPlanTask> tasks,
    required List<ImportedPlanTemplate> templates,
    required List<String> subjectOrder,
    required Set<String> subjectSeen,
    required void Function() onSkipTask,
    required void Function() onSkipTemplate,
  }) {    final stageName = stage['stage'];
    final weeklyPlan = stage['weekly_plan'];

    // 阶段里程碑：日期取第一周的起始日（weeks 是描述文本，不可靠）。
    DateTime? firstWeekStart;
    if (weeklyPlan is List && weeklyPlan.isNotEmpty) {
      final first = weeklyPlan.first;
      if (first is Map<String, dynamic>) {
        firstWeekStart = _weekRangeStart(first['week_range']);
      }
    }
    if (stageName is String && stageName.trim().isNotEmpty) {
      final title = stageName.trim();
      // 长度校验与 schema 约束一致（milestones.title ≤ 200）：超长写入会
      // 触发 DB 约束异常而非干净校验错误（M10）。
      if (title.length > 200) {
        issues.add(ImportIssue('阶段名称不能超过 200 字'));
      } else if (firstWeekStart != null) {
        final date = _format(firstWeekStart);
        if (_dateExceedsDeadline(date, deadlineDate)) {
          issues.add(ImportIssue('里程碑「$title」日期晚于目标截止日（$deadlineDate）'));
        } else {
          milestones.add(ImportedMilestone(title: title, date: date));
        }
      } else {
        issues.add(ImportIssue('阶段「$title」缺少有效的 week_range 起点，无法确定日期'));
      }
    }

    if (weeklyPlan == null) return;
    if (weeklyPlan is! List) {
      issues.add(ImportIssue('阶段「$stageName」的 weekly_plan 必须是数组'));
      return;
    }

    for (var wi = 0; wi < weeklyPlan.length; wi++) {
      final week = weeklyPlan[wi];
      final location = '阶段「$stageName」· 第 ${wi + 1} 周';
      if (week is! Map<String, dynamic>) {
        issues.add(ImportIssue('必须是对象', location: location));
        continue;
      }

      final weekStart = _weekRangeStart(week['week_range']);
      final weekNum = week['week'];
      // 周里程碑：focus 存在才生成（强化周无 focus）。
      final focus = week['focus'];
      if (weekStart != null && focus is String && focus.trim().isNotEmpty) {
        final weekLabel = weekNum is num ? '第 ${weekNum.toInt()} 周' : weekNum;
        final title = '$weekLabel：${focus.trim()}';
        // 长度校验（M10，milestones.title ≤ 200）。
        if (title.length > 200) {
          issues.add(ImportIssue('周里程碑标题不能超过 200 字', location: location));
        } else {
          final date = _format(weekStart);
          if (_dateExceedsDeadline(date, deadlineDate)) {
            issues.add(
              ImportIssue('里程碑「$title」日期晚于目标截止日（$deadlineDate）', location: location),
            );
          } else {
            milestones.add(ImportedMilestone(title: title, date: date));
          }
        }
      }

      final subjects = week['subjects'];
      if (subjects is! Map<String, dynamic>) {
        if (subjects != null) {
          issues.add(ImportIssue('subjects 必须是对象', location: location));
        }
        continue;
      }

      // 每周例行项（daily_must_do，与科目平级）→ 每天重复模板。
      // 条目为字符串（历史写法，无时长）或对象 { "title": ..., "minutes": 30 }。
      final mustDo = subjects['daily_must_do'];
      if (mustDo is List && weekStart != null) {
        final weekEnd = _weekRangeEnd(week['week_range']);
        for (var mi = 0; mi < mustDo.length; mi++) {
          final item = mustDo[mi];
          final itemLocation = '$location · 每日例行 ${mi + 1}';
          final (title, minutes) = _readMustDoEntry(
            item,
            location: itemLocation,
            issues: issues,
          );
          if (title == null) continue;
          if (weekEnd == null) {
            issues.add(ImportIssue('week_range 无效，无法确定结束日期', location: itemLocation));
            continue;
          }
          final endDate = _format(weekEnd);
          if (endDate.compareTo(todayStr) < 0) {
            // 整周已过去：模板无意义，跳过并统计。
            onSkipTemplate();
            continue;
          }
          // L34：当前周前半已过——起始日钳制到今天，避免生成历史日期
          // 实例（如周一导入时周一起始的模板生成周一到今天的逾期任务）。
          final startText = _format(weekStart);
          final effectiveStart = startText.compareTo(todayStr) < 0
              ? todayStr
              : startText;
          templates.add(ImportedPlanTemplate(
            title: title,
            startDate: effectiveStart,
            endDate: endDate,
            minutes: minutes,
          ));
        }
      }

      // 科目任务（daily_breakdown）。
      for (final entry in subjects.entries) {
        final name = entry.key;
        if (name == 'daily_must_do') continue;
        // 长度校验（M10，subjects.name ≤ 100）：空/超长科目名会静默写入
        // 或触发 DB 约束异常（L11 曾因空科目名导致 subject_manager 崩溃）。
        if (name.trim().isEmpty) {
          issues.add(ImportIssue('科目名称不能为空', location: location));
          continue;
        }
        if (name.length > 100) {
          issues.add(ImportIssue('科目名称不能超过 100 字', location: location));
          continue;
        }
        if (entry.value is! Map<String, dynamic>) {
          issues.add(ImportIssue('科目「$name」的值必须是对象', location: location));
          continue;
        }
        final subject = entry.value as Map<String, dynamic>;
        if (subjectSeen.add(name)) {
          subjectOrder.add(name);
        }
        final breakdown = subject['daily_breakdown'];
        if (breakdown is! Map<String, dynamic>) {
          if (breakdown != null) {
            issues.add(ImportIssue('daily_breakdown 必须是对象 { 日期: 任务文本 }', location: '科目「$name」'));
          }
          continue;
        }
        for (final dateEntry in breakdown.entries) {
          final date = _parseDate(dateEntry.key);
          final itemLocation = '科目「$name」· ${dateEntry.key}';
          if (date == null) {
            issues.add(ImportIssue('${dateEntry.key} 不是有效日期（应为 yyyy-MM-dd）', location: itemLocation));
            continue;
          }
          final (title, minutes) = _readTaskEntry(
            dateEntry.value,
            location: itemLocation,
            issues: issues,
          );
          if (title == null) {
            continue;
          }
          if (title.length > 200) {
            issues.add(ImportIssue('任务内容不能超过 200 字', location: itemLocation));
            continue;
          }
          if (date.compareTo(todayStr) < 0) {
            // 历史日期任务：自动跳过并统计（量大不整体报错）。
            onSkipTask();
            continue;
          }
          tasks.add(ImportedPlanTask(
            title: title,
            date: date,
            subjectName: name,
            minutes: minutes,
          ));
        }
      }
    }
  }

  /// 校验并解析 yyyy-MM-dd（格式 + 真实日历日期）；非法返回 null。
  ///
  /// 月份/日期允许非零填充（如 `2026-8-6`），解析后统一规范化输出。
  String? _readDate(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$').firstMatch(value);
    if (match == null) return null;
    return _parseDate(value);
  }

  /// 解析 yyyy-MM-dd 并校验真实日历日期；非法返回 null。
  ///
  /// 先做格式正则校验再 `int.parse`（防畸形字符串抛 FormatException），
  /// 且返回**规范化**的 `yyyy-MM-dd`（拒绝 `2026-8-6` 这类非零填充写法
  /// 原样入库——会导致字典序比较错位、任务在按日/按月视图查询中消失，
  /// S1）。月份/日期允许非零填充输入，统一规范化为两位。
  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$');

  static String? _parseDate(String value) {
    if (!_datePattern.hasMatch(value)) return null;
    final parts = value.split('-');
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final d = int.parse(parts[2]);
    final dt = DateTime(y, m, d);
    // DateTime 会溢出归一化（如 2026-02-30 -> 03-02），回读校验拦截非法日期。
    if (dt.year != y || dt.month != m || dt.day != d) return null;
    // 规范化输出：非零填充输入（手工构造）统一为 yyyy-MM-dd。
    return _format(dt);
  }

  /// 里程碑日期是否晚于目标截止日（FR-2.2 同款，导入侧校验）。
  ///
  /// [deadlineDate] 为 null（解析层已报 end_date 缺失）时返回 false 跳过，
  /// 避免叠加一条误导性的"晚于截止日"错误。
  static bool _dateExceedsDeadline(String date, String? deadlineDate) {
    if (deadlineDate == null) return false;
    return date.compareTo(deadlineDate) > 0;
  }

  /// 标题：必填且 trim 非空（长度上限由调用方单独校验，文案区分「空」与「超长」）。
  static String? _readTitle(Object? value) {
    if (value is! String) return null;
    final title = value.trim();
    if (title.isEmpty) return null;
    return title;
  }

  /// 解析 daily_breakdown 单个条目（兼容两种写法）：
  /// - 字符串：任务标题（历史写法，无时长）；
  /// - 对象：`{ "title": ..., "minutes": 180 }`（带预估时长，与 JSON 任务
  ///   导入对齐——进度统计只计带时长的任务，FR-7.4）。
  ///
  /// 返回 (标题, 时长)；标题为 null 表示非法（错误已入 [issues]）。
  static (String?, int?) _readTaskEntry(
    Object? value, {
    required String location,
    required List<ImportIssue> issues,
  }) {
    if (value is String) {
      return (_readTitle(value), null);
    }
    if (value is Map<String, dynamic>) {
      final title = _readTitle(value['title']);
      if (title == null) {
        issues.add(ImportIssue('任务内容不能为空', location: location));
      }
      final minutes = _readMinutes(
        value['minutes'],
        location: location,
        issues: issues,
      );
      return (title, minutes);
    }
    issues.add(
      ImportIssue('任务内容必须是文本或 { "title": ..., "minutes": ... } 对象', location: location),
    );
    return (null, null);
  }

  /// 解析 daily_must_do 单个条目（兼容两种写法）：
  /// - 字符串：例行标题（历史写法，无时长）；
  /// - 对象：`{ "title": ..., "minutes": 30 }`（带预估时长，继承到每天实例）。
  ///
  /// 返回 (标题, 时长)；标题为 null 表示非法（错误已入 [issues]）。
  /// 标题长度上限与 schema 一致（tasks.title ≤ 200，M10）。
  static (String?, int?) _readMustDoEntry(
    Object? value, {
    required String location,
    required List<ImportIssue> issues,
  }) {
    if (value is String) {
      final title = _readTitle(value);
      if (title == null) {
        issues.add(ImportIssue('daily_must_do 条目必须是非空文本', location: location));
      } else if (title.length > 200) {
        issues.add(ImportIssue('daily_must_do 标题不能超过 200 字', location: location));
        return (null, null);
      }
      return (title, null);
    }
    if (value is Map<String, dynamic>) {
      final title = _readTitle(value['title']);
      if (title == null) {
        issues.add(ImportIssue('daily_must_do 条目必须是非空文本', location: location));
      } else if (title.length > 200) {
        issues.add(ImportIssue('daily_must_do 标题不能超过 200 字', location: location));
        return (null, null);
      }
      final minutes = _readMinutes(
        value['minutes'],
        location: location,
        issues: issues,
      );
      return (title, minutes);
    }
    issues.add(
      ImportIssue(
        'daily_must_do 条目必须是文本或 { "title": ..., "minutes": ... } 对象',
        location: location,
      ),
    );
    return (null, null);
  }

  /// 读取并校验预估时长（分钟）：整数 1～1440；非法入 [issues] 返回 null。
  ///
  /// 与 JSON 任务导入（TaskImportParser）同契约：类型/范围错误只记 issue
  /// （issues 非空时整体校验不通过，不写入任何数据），不静默丢弃。
  static int? _readMinutes(
    Object? value, {
    required String location,
    required List<ImportIssue> issues,
  }) {
    if (value == null) return null;
    if (value is! int) {
      issues.add(ImportIssue('minutes 必须是整数（1～1440）', location: location));
      return null;
    }
    if (value < 1 || value > 1440) {
      issues.add(ImportIssue('minutes 必须在 1～1440 之间', location: location));
      return null;
    }
    return value;
  }

  /// 解析 week_range 起止日期（形如 "2026-08-09 ~ 2026-08-15"）。
  ///
  /// 用正则取第一/第二个 yyyy-MM-dd 匹配，兼容不同分隔符；解析失败返回 null。
  static DateTime? _weekRangeStart(Object? range) =>
      _weekRangeDate(range, first: true);

  static DateTime? _weekRangeEnd(Object? range) =>
      _weekRangeDate(range, first: false);

  static DateTime? _weekRangeDate(Object? range, {required bool first}) {
    if (range is! String) return null;
    // 允许非零填充（S1）：\d{1,2} 兼容 `2026-8-9` 这类手工写法。
    final matches = RegExp(r'\d{4}-\d{1,2}-\d{1,2}').allMatches(range).toList();
    if (matches.isEmpty) return null;
    final target = first ? matches.first : matches.last;
    final value = target.group(0)!;
    final parsed = _parseDate(value);
    if (parsed == null) return null;
    final parts = value.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static String _format(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
