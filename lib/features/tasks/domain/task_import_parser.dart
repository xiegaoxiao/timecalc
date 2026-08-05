import 'dart:convert';

/// 单个待导入任务（JSON 导入计划项）。
class ImportedTaskItem {
  const ImportedTaskItem({
    required this.title,
    required this.date,
    this.subjectName,
    this.minutes,
  });

  final String title;

  /// 本地日历日期（yyyy-MM-dd），已通过格式、有效性与「不早于今天」校验。
  final String date;

  /// 归属科目名；null 表示未分类任务。
  final String? subjectName;
  final int? minutes;
}

/// 解析通过的导入计划：科目（隔离分组）与未分类任务。
class TaskImportPlan {
  const TaskImportPlan({required this.items, required this.subjectOrder});

  final List<ImportedTaskItem> items;

  /// 科目出现顺序（预览分组用）。
  final List<String> subjectOrder;
}

/// 导入统计结果。
class ImportStats {
  const ImportStats({required this.createdSubjects, required this.createdTasks});

  final int createdSubjects;
  final int createdTasks;
}

/// 单个校验问题。
class ImportIssue {
  const ImportIssue(this.message, {this.location});

  final String message;

  /// 出错位置，如「科目 数学 · 第 2 项」或「未分类 · 第 1 项」。
  final String? location;
}

/// JSON 解析结果：全部通过才携带 [plan]。
class TaskImportResult {
  const TaskImportResult({this.plan, this.issues = const []});

  final TaskImportPlan? plan;
  final List<ImportIssue> issues;

  bool get isValid => plan != null && issues.isEmpty;
}

/// JSON 批量导入解析与校验（批量添加的升级版）。
///
/// 纯 Dart service，不依赖数据库与 UI。JSON 结构：
///
/// ```json
/// {
///   "subjects": {
///     "数学": [
///       { "title": "真题 2013", "date": "2026-08-06", "minutes": 180 }
///     ]
///   },
///   "unclassified": [
///     { "title": "复盘", "date": "2026-08-06" }
///   ]
/// }
/// ```
///
/// 规则：
/// - `subjects`（可选，对象）与 `unclassified`（可选，数组）相互隔离；
/// - 每条任务：`title` 必填非空；`date` 必填，格式 yyyy-MM-dd、必须是
///   真实日历日期、不得早于 [today]（本地日期）；`minutes` 可选 1～1440；
/// - 任一问题存在时返回 [TaskImportResult.issues] 且不带计划，阻止导入。
class TaskImportParser {
  const TaskImportParser();

  TaskImportResult parse(String source, {required DateTime today}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      return TaskImportResult(
        issues: [ImportIssue('JSON 格式不合法：${e.message}')],
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const TaskImportResult(
        issues: [ImportIssue('JSON 顶层必须是对象 { ... }')],
      );
    }

    final issues = <ImportIssue>[];
    final items = <ImportedTaskItem>[];
    final subjectOrder = <String>[];

    // subjects：科目名 -> 任务数组（与未分类任务隔离）。
    final subjectsValue = decoded['subjects'];
    if (subjectsValue != null) {
      if (subjectsValue is! Map<String, dynamic>) {
        issues.add(const ImportIssue('subjects 必须是对象 { "科目名": [...] }'));
      } else {
        for (final entry in subjectsValue.entries) {
          final name = entry.key.trim();
          if (name.isEmpty) {
            issues.add(const ImportIssue('科目名称不能为空'));
            continue;
          }
          if (entry.value is! List) {
            issues.add(ImportIssue('科目「$name」的值必须是任务数组'));
            continue;
          }
          subjectOrder.add(name);
          _parseEntries(
            entry.value,
            items,
            issues,
            subjectLabel: '科目「$name」',
            subjectName: name,
            today: today,
          );
        }
      }
    }

    // unclassified：未分类任务数组。
    final unclassifiedValue = decoded['unclassified'];
    if (unclassifiedValue != null) {
      if (unclassifiedValue is! List) {
        issues.add(const ImportIssue('unclassified 必须是任务数组'));
      } else {
        _parseEntries(
          unclassifiedValue,
          items,
          issues,
          subjectLabel: '未分类',
          subjectName: null,
          today: today,
        );
      }
    }

    if (issues.isNotEmpty) {
      return TaskImportResult(issues: issues);
    }
    if (items.isEmpty) {
      return const TaskImportResult(
        issues: [ImportIssue('没有可导入的任务（subjects 或 unclassified 至少提供一项）')],
      );
    }
    return TaskImportResult(
      plan: TaskImportPlan(items: items, subjectOrder: subjectOrder),
    );
  }

  void _parseEntries(
    List<dynamic> list,
    List<ImportedTaskItem> items,
    List<ImportIssue> issues, {
    required String subjectLabel,
    required String? subjectName,
    required DateTime today,
  }) {
    for (var i = 0; i < list.length; i++) {
      final raw = list[i];
      final location = '$subjectLabel · 第 ${i + 1} 项';
      if (raw is! Map<String, dynamic>) {
        issues.add(
          ImportIssue('必须是对象 { "title": ..., "date": ... }', location: location),
        );
        continue;
      }

      final title = raw['title'];
      if (title is! String || title.trim().isEmpty) {
        issues.add(ImportIssue('title 必填且不能为空', location: location));
        continue;
      }

      final date = raw['date'];
      if (date is! String) {
        issues.add(ImportIssue('date 必填，格式 yyyy-MM-dd', location: location));
        continue;
      }
      final dateError = _validateDate(date, today);
      if (dateError != null) {
        issues.add(ImportIssue(dateError, location: location));
        continue;
      }

      int? minutes;
      final minutesRaw = raw['minutes'];
      if (minutesRaw != null) {
        if (minutesRaw is! int) {
          issues.add(ImportIssue('minutes 必须是整数（1～1440）', location: location));
          continue;
        }
        if (minutesRaw < 1 || minutesRaw > 1440) {
          issues.add(ImportIssue('minutes 必须在 1～1440 之间', location: location));
          continue;
        }
        minutes = minutesRaw;
      }

      items.add(ImportedTaskItem(
        title: title.trim(),
        date: date,
        subjectName: subjectName,
        minutes: minutes,
      ));
    }
  }

  /// 校验 yyyy-MM-dd 格式、真实日历日期，且不早于 [today]。
  String? _validateDate(String dateStr, DateTime today) {
    final match = RegExp(r'^\d{4}-\d{2}-\d{2}$').firstMatch(dateStr);
    if (match == null) return '日期格式应为 yyyy-MM-dd';
    final parts = dateStr.split('-');
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final d = int.parse(parts[2]);
    final dt = DateTime(y, m, d);
    // DateTime 会溢出归一化（如 2026-02-30 -> 03-02），回读校验拦截非法日期。
    if (dt.year != y || dt.month != m || dt.day != d) {
      return '不是有效日期（$dateStr）';
    }
    if (_dayDiff(dt, today) < 0) {
      return '日期不能早于今天（${_format(today)}）';
    }
    return null;
  }

  static int _dayDiff(DateTime a, DateTime b) {
    final aDay = DateTime.utc(a.year, a.month, a.day);
    final bDay = DateTime.utc(b.year, b.month, b.day);
    return aDay.difference(bDay).inDays;
  }

  static String _format(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
