import 'package:drift/drift.dart';

/// TimeCalc 数据模型（schema v17）。
///
/// 遵循 PRD §9：
/// - 业务实体包含 id、createdAt、updatedAt；
/// - 时间戳（createdAt/updatedAt/completedAt）使用 UTC 存储；
/// - 计划日期（deadlineDate/plannedDate）按本地日历日期以 `yyyy-MM-dd`
///   文本单独存储，避免跨时区导致日期漂移。
/// - 计划时刻（Tasks.startTime / RecurrenceTemplates.startTime）为本地
///   墙上时间 `HH:mm`，可空：日期仍是排程锚点，时刻用来精确到小时。
/// - schema v10（P3.6）：高频查询列补充 @TableIndex 索引。
/// - schema v16：Tasks / RecurrenceTemplates 增加 start_time（小时级排程）。
/// - schema v17：新增 Courses 课程表（FR-10 课表）；Settings 增加
///   semester_start_date（教学周基准，第 1 周周一）。

/// 目标状态（FR-1.3 / FR-1.4）。
class GoalStatus {
  static const String active = 'active';
  static const String completed = 'completed';
  static const String abandoned = 'abandoned';
  static const String archived = 'archived';
}

/// 关闭按钮行为（FR-8.1，schema v6 引入）。
class CloseBehavior {
  static const String exit = 'exit';
  static const String minimizeToTray = 'minimize_to_tray';
}

/// 任务状态。
class TaskStatus {
  static const String todo = 'todo';
  static const String done = 'done';
}

/// 里程碑状态（FR-2，schema v7 引入）。
class MilestoneStatus {
  static const String todo = 'todo';
  static const String done = 'done';
}

/// 课程单双周（FR-10，schema v17 引入）。
///
/// 与 [GoalStatus] 等同为「文本列的取值常量」，入库即此处常量字符串，
/// 语义解释在 `features/timetable/domain/course_week.dart` 的纯函数里。
class WeekParity {
  static const String all = 'all';
  static const String odd = 'odd';
  static const String even = 'even';
}

/// 计划偏好默认值（PRD §5.1：默认每天 2 小时、每周 7 天）。
class SettingsDefaults {
  static const int dailyAvailableMinutes = 120;

  /// 每周可用日（ISO 星期 1=周一 … 7=周日），默认全部可用。
  static const Set<int> availableWeekdays = {1, 2, 3, 4, 5, 6, 7};
}

class Goals extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();
  TextColumn get deadlineDate => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

@TableIndex(name: 'subjects_goal_idx', columns: {#goalId})
class Subjects extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get color => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 里程碑（FR-2，schema v7 引入）。
///
/// 目标下的阶段性节点，用户可添加/编辑/完成/删除（FR-2.1）；
/// 里程碑日期原则上不得晚于目标截止日（FR-2.2）。date 为本地日历日期，
/// 遵循 `yyyy-MM-dd` 文本约定（tables.dart 头注释）。
@TableIndex(name: 'milestones_goal_idx', columns: {#goalId})
class Milestones extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get date => text()();
  TextColumn get status => text().withDefault(const Constant('todo'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 任务表（schema v10 起带高频查询索引，P3.6）。
///
/// 索引服务的高频查询（P3.6）：
/// - [tasks_goal_archived_idx]：目标下任务（byGoal/archivedByGoal）；
/// - [tasks_planned_date_idx]：按计划日期（byDate/byDateRange，今日页/日历）；
/// - [tasks_status_archived_idx]：未完成任务集（allTodoTasks/unfinishedBefore）；
/// - [tasks_status_completed_idx]：完成热力图区间（completedBetween）。
@TableIndex(name: 'tasks_goal_archived_idx', columns: {#goalId, #archivedAt})
@TableIndex(name: 'tasks_planned_date_idx', columns: {#plannedDate})
@TableIndex(name: 'tasks_status_archived_idx', columns: {#status, #archivedAt})
@TableIndex(
  name: 'tasks_status_completed_idx',
  columns: {#status, #completedAt},
)
class Tasks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  IntColumn get subjectId => integer().references(Subjects, #id).nullable()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get note => text().nullable()();
  TextColumn get plannedDate => text()();

  /// 计划开始时刻（本地时钟 `HH:mm`，24 小时制，schema v16 引入）。
  ///
  /// 计划日期仍以 [plannedDate] 的 `yyyy-MM-dd` 为锚点，本列只在「天」之上
  /// 追加可选的钟点，用于把任务排进日历（升序排序、日历视图时间轴、
  /// iCalendar 导出）。null 表示「当天某个时刻未定」——即原按天计划的语义，
  /// 旧数据无需回填，按天逻辑（负载、延期、重复生成）不受影响。
  ///
  /// 不存 UTC 也不存带时区的时刻：与 [plannedDate] 同为「本地墙上时间」，
  /// 避免跨时区漂移（tables.dart 头注释）。
  TextColumn get startTime => text().nullable()();

  IntColumn get estimatedMinutes => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('todo'))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 原计划日期（FR-3.3 验收：延期保留原计划日期）。
  ///
  /// schema v2 引入，仅记录首次延期/改期前的日期，不随后续延期刷新，
  /// 用于审计与后续恢复/统计。未延期过的任务为 null。
  TextColumn get originalPlannedDate => text().nullable()();

  /// 归档时间（JSON 替换导入时保留的已完成旧任务，schema v3 引入）。
  ///
  /// 非 null 表示该任务已被归档：不参与负载/日历统计与常规列表，仅在
  /// 设置页「备份与恢复」的已归档任务区展示，可手动恢复回当前计划。
  /// 替换导入时未完成旧任务直接删除、不归档；已完成的归档保留。未归档
  /// 任务为 null。
  DateTimeColumn get archivedAt => dateTime().nullable()();

  /// 所属重复模板（FR-4，schema v4 引入）。
  ///
  /// 非 null 表示该任务是重复任务的实例：随模板规则由 generateDue 滚动生成；
  /// 模板停止后仍保留为普通任务。普通任务为 null。
  IntColumn get recurrenceTemplateId =>
      integer().references(RecurrenceTemplates, #id).nullable()();
}

/// 重复任务模板（FR-4，schema v4 引入）。
///
/// 「模板 + 实例」模型：模板保存重复规则，实例为具体日期上的任务
/// （Tasks.recurrenceTemplateId 指向本表）。规则以 ruleType(文本) +
/// ruleJson(文本) 存储，由 RecurrenceRuleRegistry 中的 handler 解释，
/// 新增规则类型无需 schema 变更。
@TableIndex(name: 'recurrence_templates_goal_idx', columns: {#goalId})
class RecurrenceTemplates extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().references(Goals, #id)();
  IntColumn get subjectId => integer().references(Subjects, #id).nullable()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  IntColumn get estimatedMinutes => integer().nullable()();
  TextColumn get ruleType => text()();
  TextColumn get ruleJson => text()();
  TextColumn get startDate => text()();
  TextColumn get endDate => text().nullable()();

  /// 实例的计划开始时刻（本地时钟 `HH:mm`，schema v16 引入）。
  ///
  /// 模板上的「钟点」随规则一起继承到每条生成的实例（Tasks.startTime），
  /// 使「每天 20:00 背单词」这类重复安排能落到日历上。null 表示只排到天。
  TextColumn get startTime => text().nullable()();

  BoolColumn get active => boolean().withDefault(const Constant(true))();
  TextColumn get generatedThroughDate => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 已删除实例日期（schema v5 引入，墓碑）。
  ///
  /// 用户删除某个重复实例任务后，该日期记录在此（JSON 数组，yyyy-MM-dd），
  /// 后续 generateDue/updateRule 滚动生成时跳过这些日期，被删除的实例
  /// 不会随窗口滚动「复活」。null 表示从未删除过实例。
  TextColumn get deletedInstanceDates => text().nullable()();
}

/// 任务检查项（FR-4.1，schema v8 引入）。
///
/// 任务可包含可排序的检查项（PRD §9 ChecklistItem：taskId/title/done/
/// sortOrder，另按项目惯例带 id/createdAt/updatedAt）。检查项随任务
/// 级联删除（防孤儿数据，NFR-2）。done 用 BoolColumn（仿
/// RecurrenceTemplates.active），sortOrder 支持任务内上移/下移重排。
@TableIndex(name: 'checklist_items_task_idx', columns: {#taskId})
class ChecklistItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().references(Tasks, #id)();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 单门课程（FR-10 课表，schema v17 引入）。
///
/// 与 Tasks 的边界：任务是「可延期、可勾选完成」的一次性/重复安排；
/// 课程是**外部给定的固定作息**——每周同一时段、按教学周编号重复，
/// 不参与负载/完成度统计，也不进「今天」页的待办闭包。因此独立建表，
/// 不与 Goals/Tasks 混在一张表里（避免课程被误当作可延期任务）。
///
/// 时间定位为「第几周 + 星期几 + 第几节」四元组，全部是整数：
/// - [weekday]/[startPeriod]/[endPeriod] 落在单周内（节次语义见
///   `features/timetable/domain/class_period.dart` 的作息表）；
/// - [startWeek]/[endWeek] 是**教学周编号**（第 1 周 = 学期开始那一周），
///   基准由 `Settings.semesterStartDate` 提供，因此换学期只需改基准、
///   不必改每门课的周次；
/// - [weekParity] 表达单/双周（`all`/`odd`/`even`）。
///
/// 不存绝对日期：课程表按学期循环复用，存绝对日期会在每学期导入时
/// 产生一轮无意义的日期漂移（tables.dart 头注释的「本地日历日期」约定
/// 针对的是用户指定的计划日期，不适用于周期性作息）。
@TableIndex(name: 'courses_weekday_idx', columns: {#weekday})
class Courses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get teacher => text().nullable()();
  TextColumn get location => text().nullable()();

  /// 星期几（ISO，1=周一 … 7=周日）。
  IntColumn get weekday => integer()();

  /// 起始节次与结束节次（含两端，1 起）。
  IntColumn get startPeriod => integer()();
  IntColumn get endPeriod => integer()();

  /// 教学周范围（含两端，1 起）。
  IntColumn get startWeek => integer()();
  IntColumn get endWeek => integer()();

  /// 单双周：见 [WeekParity]（`all` 每周 / `odd` 单周 / `even` 双周）。
  TextColumn get weekParity =>
      text().withDefault(const Constant(WeekParity.all))();

  /// 课程类别（公共必修课/学科基础课/方向必修课/选修课…），可空。
  TextColumn get category => text().nullable()();

  /// 卡片配色（`#RRGGBB`，与 Subjects.color 同格式）。
  TextColumn get color => text()();

  /// 备注（如「官方标注 17:50 开始，以任课教师通知为准」）。
  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 计划偏好（单行表，PRD §9 Settings 的 M2 子集 + M3 关闭行为 + M8 自动备份
/// + M10 外观主题）。
///
/// schema v13（2026-08：移除全部 WebDAV/同步功能）删除了
/// webdav_url / webdav_username / webdav_password_saved（v9）与
/// webdav_sync_enabled / last_pushed_seq / last_synced_at（v11）6 列，
/// 数据回到纯本地单机。
///
/// schema v2 引入。默认行不写死在迁移里，由 SettingsRepository.get()
/// 惰性 seed（insertOrIgnore），保证迁移库与全新安装行为一致。
class Settings extends Table {
  /// 单行表固定主键 1。
  IntColumn get id => integer()();

  /// 每日可用时长（分钟），PRD §5.1 默认 120。
  IntColumn get dailyAvailableMinutes =>
      integer().withDefault(const Constant(120))();

  /// 每周可用日，逗号分隔的 ISO 星期（1=周一…7=周日），如 `1,2,3,4,5,6,7`。
  TextColumn get availableWeekdays =>
      text().withDefault(const Constant('1,2,3,4,5,6,7'))();

  /// 关闭按钮行为（FR-8.1，schema v6 引入）。
  ///
  /// 取值见 [CloseBehavior]：`exit`（默认，直接退出）或
  /// `minimize_to_tray`（最小化到托盘）。窗口状态属于桌面层状态，
  /// 不进入业务数据备份（FR-9.5）。
  TextColumn get closeBehavior => text().withDefault(const Constant('exit'))();

  /// 每日自动备份开关（FR-9.4，schema v9 引入）。
  ///
  /// 运行时配置，不进入业务数据备份（FR-9.5，同 close_behavior）。
  BoolColumn get autoBackupEnabled =>
      boolean().withDefault(const Constant(false))();

  /// 本地自动备份目录（schema v9，可空）。
  ///
  /// 为空时本地目的地不启用；选择目录经原生对话框后写回（Windows 路径）。
  TextColumn get localBackupFolder => text().nullable()();

  /// 上次自动备份完成时间（schema v9，UTC，可空）。
  ///
  /// 调度判据：距离上次成功不足 1 天时跳过（FR-9.4「每日」语义）。
  /// 失败不推进该时间戳，避免静默跳过。
  DateTimeColumn get lastAutoBackupAt => dateTime().nullable()();

  /// 主题模式（M10，schema v12 引入）。
  ///
  /// 取值与 [ThemeMode.name] 一致：`system`（默认，跟随 Windows 明暗）/
  /// `light` / `dark`。设备级外观配置（同 close_behavior），不进入业务
  /// 数据备份（FR-9.5），覆盖恢复/同步拉取时保留本设备选择。
  TextColumn get themeMode => text().withDefault(const Constant('system'))();

  /// 主题色系（2026-08-16 色系解耦，schema v14 引入）。
  ///
  /// 取值见 [AccentPalette.id]：`green`（默认）或 `blue`。设备级外观配置
  /// （同 theme_mode），不进入业务数据备份（FR-9.5），覆盖恢复时保留
  /// 本设备选择。
  TextColumn get accentColor => text().withDefault(const Constant('green'))();

  /// 减少动画开关（2026-08-20 动效改造，schema v15 引入）。
  ///
  /// 开启后全局过渡/入场动效时长归零（直接显示），仅保留必要操作反馈。
  /// 设备级外观配置（同 theme_mode），不进入业务数据备份（FR-9.5）。
  BoolColumn get reduceMotion => boolean().withDefault(const Constant(false))();

  /// 教学周基准：第 1 周周一（本地日历日期 `yyyy-MM-dd`，schema v17）。
  ///
  /// 课表页把「第 N 教学周 + 星期几」换算成真实日期时要一个锚点——
  /// 该锚点就是学期第 1 周的周一。它属于「本学期的时间设定」而非外观
  /// 偏好，随课表一起备份（FR-9.1）；为空表示尚未设定，课表页退化为
  /// 不按周筛选的「全部课程」视图并提示设置。
  TextColumn get semesterStartDate => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
