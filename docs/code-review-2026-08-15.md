# TimeCalc 专项代码审查报告（2026-08-15）

> **注记（2026-08-16）：本报告审查时 WebDAV/整库同步尚在代码库中。该功能已于
> v1.15 整体移除（schema v13 删列），下文涉及的同步 meta、`_restoring` 状态机、
> WebDAV 抑制窗口等条目为**历史记录**，仅供追溯，不再适用当前代码。**

> 审查维度（按需求选定）：**健壮性与边界 / 代码规范与整洁度 / 架构与可测试性**。
> 审查方式：3 个并行子代理分维度深审 + 本人对全部关键发现逐条交叉验证（含实验验证
> `DateTime.parse` 边界行为、核查失效清单、核实同步/备份/恢复错误路径）。
> 基线：`dart analyze` **0 问题**；`flutter test` **603/603 通过**。
> 代码量：`lib/` 106 文件共 34,336 行，其中 drift 生成代码
> （`database.g.dart` 8,562 + `migration.dart` 2,486）约 1.1 万行，手写约 2.3 万行。
> 延续 08-13 全量审查、08-14 业务逻辑专项复查之后的第三轮专项复查。

## 总体结论

**工程质量处于中上偏优水平，未发现「常规操作即触发」的高危缺陷，更无数据丢失级缺陷。**
前两轮审查的整改（S1-S3 / M1-M16 / 08-14 的 6 项）均已验证到位且未回归：
计划导入 `_parseDate` 已做校验+规范化、task_tile 延期已禁止过去并用注入时钟、
`generateDue` 已防脏模板拖垮滚动生成、周视图已统一 `addLocalDays`、SyncMeta 的
seq/schema 已改类型判定、`_restoring` 防回环抑制已实现。

本轮新发现集中在**两条系统性线索**：

1. **「外部输入 → `as` 强转 → 只 `on Exception` 守卫」不一致** —— 3 个【中】级缺陷
   同源（同步 meta、备份 manifest、恢复预览），都是 TypeError（Error）逃出 `on Exception`
   导致**静默失败、用户零反馈**。项目自身已在别处明确防御（`restoreBackup` 的
   `on Error` 兜底、SyncMeta 的 `is int` 判定），这几处是漏网。
2. **同步恢复状态机的异常安全** —— `_restoring` 标志非异常安全、变更抑制窗口固定 15s
   且失败路径残留。

另有若干【低】级健壮性缺口、一批可机械消除的重复代码（整洁度维度）与测试盲区
（架构维度）。以下按严重级别列出，均附 文件:行号 与修复建议。

---

## 一、健壮性与边界

### 【中】1. 同步 meta `syncedAtUtc` 残留 `as String?` 强转 → TypeError 逃出 → 同步静默失败
- **位置**：`lib/features/sync/data/webdav_sync_service.dart:499`（`SyncMeta.fromJson`）
- **问题**：该函数注释（08-14 #6）声称已对远端 meta 做类型判定——`seq`/`appSchemaVersion`
  确实用了 `is int`，但 `syncedAtUtc` 仍是 `DateTime.tryParse(json['syncedAtUtc'] as String? ?? '')`。
  若远端 meta 该字段为数字（如 `123`）或对象，`as String?` 立即抛 **TypeError（Error）**，
  不被 `_readRemoteMeta` / `_syncOnce` 的 `on WebDavException` 捕获 → 冒泡为未处理异步错误；
  同步页 `_syncNow` 的 `on Exception` 也捕不到 → **同步静默失败、无任何提示**（release 下只落诊断日志）。
- **触发场景**：远端 meta 被手工构造/其他工具写入（应用自身恒写合法 ISO 串，非常规路径）。
- **修复**：`final raw = json['syncedAtUtc']; final at = raw is String ? DateTime.tryParse(raw) : null;`
  与同函数 seq/schema 的既有做法保持一致。已由我亲自核实。

### 【中】2. `_pull` 的 `_restoring` 标志在临时目录创建失败时永久卡死
- **位置**：`lib/features/sync/data/webdav_sync_service.dart:385-386`
- **问题**：`_restoring = true;` 与 `Directory.systemTemp.createTemp(...)` 都在 `try` **之外**
  （try 从 390 行才开始）。系统临时目录不可写/创建抛 `FileSystemException` 时：异常既不进
  `on Exception`（冒泡为未处理异步错误），`_restoring` 也**永不复位** → 此后所有同步永久返回
  「同步互斥：正在恢复数据」，直到重启应用。
- **修复**：把 `createTemp` 移入 `try` 内，或在 createTemp 外层包 try/catch 并保证 `_restoring = false`。
  （`_push` 的 createTemp 也在 try 外，但无状态标志，问题较轻。）

### 【中】3. 备份 manifest 字段类型损坏 → TypeError 逃出 `on Exception` → 恢复预览静默中止
- **位置**：`lib/features/backup/data/backup_manifest.dart:108,109,113`
  （`counts as Map?` / `exportedAtUtc as String?` / `type as String?`）
  → 调用点 `lib/features/backup/data/backup_service.dart:562`（`_unpack` 的 fromJson 未包 Error 兜底）
  → UI 层 `lib/features/backup/presentation/backup_page.dart:450`（`readBackupManifest` 只 `on Exception`）。
- **问题**：备份 JSON 合法但字段类型错（`exportedAtUtc: 123`、`type: 5`）时 `as String?` 抛 TypeError。
  `restoreBackup` 路径有外层 `on Error` 转 `BackupException` 而安全；但**恢复前预览清单的必经路径
  `readBackupManifest` 没有该兜底** → TypeError 逃出 → 恢复预览流程静默中止、用户无任何提示。
- **修复**：`BackupManifest.fromJson` 全字段改类型判定（同 SyncMeta），或在 `_unpack` 的
  manifest 解析外加 `on Error` 转 `BackupException`。这正是一处「代码自身已在别处明确防御却在此漏掉」
  的同类缺陷。

### 【中】4. 周/年视图 provider 未纳入数据失效清单 → 勾选/改期任务后日历周/年视图陈旧
- **位置**：`lib/core/providers/app_refresh.dart:23-31`（`invalidateAppData`）、`:38-48`
  （`invalidateAllAppData`）、`lib/features/plan/presentation/calendar_view.dart:372`（`_invalidateAll`
  也走 `invalidateAppData`）
- **问题**：`tasksByWeekProvider` / `tasksByYearProvider`（`task_repository_provider.dart:43,55`）
  是**独立查询的 family provider**（不派生于会被失效的 `tasksByDate`/`tasksByMonth`）。任何任务变更
  （今日页勾选/延期、计划页内操作）走 `invalidateAppData` 都不失效它们 → 周视图任务条预览/聚合
  与年视图月完成数**保持陈旧**，直到重启或周/年键变化。日历页仅错误重试路径（`calendar_view.dart:219-221`）
  会失效它们。已确认无测试覆盖此场景。
- **修复**：把 `tasksByWeekProvider`/`tasksByYearProvider`（family 无参失效整族）补进
  `invalidateAppData`；顺带把 `main.dart:126-143` 的 `_invalidateDataProviders` 与
  `app_refresh.dart` 的清单去重（见整洁度 #5）。

### 【低】5. 甘特图对脏 `plannedDate` 无容错（与全库日期口径不一致）
- **位置**：`lib/services/statistics_service.dart:190`（`DateTime.parse(task.plannedDate)`）
- **问题**：已实验验证 `DateTime.parse("2026-8-6")` 抛 `FormatException`，而项目统一的
  `parseLocalDate`（split+int.parse）能解析；`DateTime.parse("2026-13-99")` 还会静默溢出归一化到
  2027-04-09。手工改库/旧版残留的非规范日期会让 `progressGanttProvider` 报错、进度页甘特区变错误态。
  另 `calendar_view.dart:1386`、`task_repository_provider.dart:45` 同款（内部生成日期，风险更低）。
- **修复**：统一用 `parseLocalDate`（或在统计层对解析失败跳过该任务，与 `generateDue` 脏数据防御同思路）。

### 【低】6. backup_codec 时间戳 `DateTime.parse(... as String)` 的 FormatException 原样逃出
- **位置**：`lib/features/backup/data/backup_codec.dart:122,168,177`（completedAt/archivedAt）
- **问题**：`FormatException` 是 Exception 而非 Error，`restoreBackup` 的 `on Error` 兜不住；
  手工构造的损坏备份会以「恢复失败：Invalid date format…」这种原始技术文案呈现（UI `on Exception`
  能捕获，功能无碍，但提示不友好、与「先校验后写入」的设计意图不符）。同文件 `_parseUtc` 已用
  `tryParse`，此处不一致。
- **修复**：改用 `_parseUtc` 式 `tryParse`，失败统一转 `BackupException`。

### 【低】7. 「从备份位置恢复」临时目录从不清理
- **位置**：`lib/features/backup/presentation/backup_page.dart:430-435`
- **问题**：`createTemp('timecalc-restore')` 下载备份后进入统一恢复流程，**无 finally 删除**，
  也不在 `_sweepStaleSafetyDirs` 的清扫前缀内（对比 `_pull`/`_push`/auto_backup 都在 finally
  deleteSync）。每次从本地/WebDAV 恢复泄漏一个备份大小的临时文件，长期累积。
- **修复**：finally 中 `deleteSync(recursive: true)`，并把 `timecalc-restore-*` 纳入过期清扫。

### 【低】8. 自动备份导出失败无用户反馈
- **位置**：`lib/features/backup/data/auto_backup_service.dart:117`（`exportBackup` 的 try/finally **无 catch**）
- **问题**：磁盘满/IO 异常时 `exportBackup` 抛 `FileSystemException` 逃出 `run()`；「立即备份」与
  「开启自动备份」按钮（backup_page）均无 catch → 未处理异步错误、用户无提示（仅调度器会吞掉）。
- **修复**：把导出也包进 catch，并入 `errors` 列表按失败返回（与逐目的地同款）。

### 【低】9. recurrence 编辑对话框 `cast<int>()` 惰性强转可能在 build 崩溃
- **位置**：`lib/features/tasks/presentation/recurrence_task_dialog.dart:480`
  （`((_ruleJson['weekdays'] as List?) ?? []).cast<int>()`）
- **问题**：`cast<int>()` 是惰性视图，元素访问时才强转。被污染的 weekly 模板
  （如 `ruleJson: {"weekdays": ["1","3"]}`，手工改库/被污染备份）打开编辑对话框时，
  `_WeekdaysPicker` build 中 `selected.contains(day)` 对 String 元素做 `as int` → **TypeError 崩溃**
  （`_ruleError` 虽已提示，但 `_buildParams` 仍会构建 picker，挡不住崩溃）。已核实。
- **修复**：与 `builtin_recurrence_handlers.dart` 的 `_asIntList` 同款安全解析后再渲染。

### 【低】10. 同步变更抑制窗口：失败路径残留 + 固定 15s 对慢恢复失效
- **位置**：`lib/features/sync/data/webdav_sync_service.dart:396-397`
- **问题**：① `_suppressWatchUntil` 在恢复**前**设定、`on Exception` 分支不清除——**拉取恢复失败后
  15s 内本地真实编辑会被静默跳过**（不置脏标记、不推送），仅靠下次编辑/启动兜底；注释声称「下载失败
  路径不残留」，但恢复失败路径仍残留。② 固定 15s 小于大库恢复（安全副本导出+导入）实际耗时时会
  提前失效，期间 watcher 触发的 `pushIfNeeded` 不再被抑制（`pushIfNeeded` 只查墙钟窗口、不查
  `_restoring`）→ 可能恢复中段回推一次（seq+1，无数据损坏，仅多余网络/seq 开销）。
- **修复**：catch 分支清 `_suppressWatchUntil = null`；把抑制判据与 `_restoring` 标志结合而非纯墙钟。

### 【低】11. WebDAV 下载/上传整文件驻留内存、无大小上限；备份解压无压缩比限制
- **位置**：`lib/features/backup/data/webdav_client.dart:120-178`、`backup_service.dart:542`
- **问题**：同步快照/备份下载后整体驻留内存；`ZipDecoder.decodeBytes(verify: true)` 无字节/压缩比上限。
  恶意或超大远端文件可致内存暴涨（zip bomb 场景）。本地单机工具风险可控，属防御性建议。
- **修复**：为下载/解压设字节上限并给出可读错误。

### 【低】12. `_overwriteRestore` 中 `lastPushedSeq as int` 硬转（类型判定不一致）
- **位置**：`lib/features/backup/data/backup_service.dart:493`
- **问题**：手工构造备份含 double（5.0）时抛 TypeError；被外层 `on Error` 转 `BackupException` 兜住、
  不崩，但与 SyncMeta 已推广的「类型判定替代 `as` 强转」不一致，属同类漏网。
- **修复**：改 `(x as num?)?.toInt()` 或 `is int` 判定。

---

## 二、代码规范与整洁度

**亮点**：零 TODO/FIXME/print；`dart analyze` 全绿（无死代码）；注释与代码一致；错误分层
（BackupException/WebDavException/runDbAction）与 provider 命名纪律统一。

### 【中】1. 日期助手/UTC 日差未真正收敛到 `date_text.dart`
- `date_text.dart:5` 明言「收敛全库散落的 `_parseDate`/`_formatDate`」，实际仍有 5 份私有副本：
  `statistics_service.dart:367` `_formatDate`、`recurrence_repository.dart:442`、`builtin_recurrence_handlers.dart:246`
  （顶层 `_parse`/`_format`）、`task_import_parser.dart:272`、`plan_import_parser.dart:538`；
  `task_repository_provider.dart:30-50` 还手写 `month.split` + `DateFormat`。
- UTC 归一化日差 `_dayDiff` 重复 4 份：`countdown_service.dart:71`、`statistics_service.dart:361`、
  `task_import_parser.dart:267`、`today_page.dart:921`（`_utcDayDiff`）。
- **建议**：统一调 `parseLocalDate`/`formatLocalDate`；把严格校验变体吸收为
  `date_text.tryParseLocalDate`；新增 `date_text.dayDiff`。

### 【中】2. 状态比较：枚举常量 vs 裸字符串混用（含同文件混用）
- 裸 `'done'`：`task_repository.dart:50,52`、`progress_page.dart:145`、`today_page.dart:181`、
  `task_tile.dart:59`、`subject_manager.dart:72`、`subject_task_page.dart:105`、`task_import_dialog.dart:125`。
- 裸 `'completed'/'abandoned'/'archived'`：`calendar_view.dart:114-116`、`today_page.dart:128-130`、
  `goal_list_page.dart:597,610,621`（写库）。
- 同文件混用：`task_repository.dart:50`（裸串）vs `:95`（`TaskStatus.todo`）；`calendar_view.dart:114`（裸串）vs `:131`。
- **建议**：统一用 `GoalStatus`/`TaskStatus` 常量（`tables.dart:13-30`），零成本、改名安全。

### 【中】3. 两份数据失效清单逐字重复
- `main.dart:126-143` `_invalidateDataProviders` 与 `app_refresh.dart:38-49` `invalidateAllAppData`
  逐条相同（`main.dart:119` 注释自述「对齐」）——正是 `app_refresh.dart:12-14` 文档警告的反模式。
- **建议**：抽共享 provider 列表常量，两个入口共同迭代（顺带修复上文健壮性 #4 的周/年视图缺口）。

### 【中】4. 跨文件重复组件/文案/色板
- `_SectionError`：`today_page.dart:669` 与 `calendar_view.dart:512` 逐字相同 → 抽 `shared/widgets/section_error.dart`。
- 空态 `_EmptyView`：`today_page.dart:869`、`goal_list_page.dart:212`、`archived_tasks_page.dart:196`
  各自实现（注释自述已统一语言却未复用）。
- 中文星期文案 4 套：`calendar_view.dart:711,1017`、`progress_page.dart:490,1205`、`plan_preference_page.dart:189`。
- 热力色板：`progress_page.dart:26-41` 与 `calendar_view.dart:1355` 相同；暗色空档灰在 progress_page 内重复。
- **建议**：依次抽 `weekdayLabel(int)`、共享空态/错误条组件、色板并入 `app_tokens.dart`。

### 【中】5. 「进行中目标」过滤谓词重复 5+ 处
- `progress_page.dart:96,223,705,1486`（同文件 4 处）+ `today_page.dart:125` + `calendar_view.dart:111`
  + `countdown_service.dart:40`。
- **建议**：`GoalStatus` 增加 `bool get isActive`。

### 【低】6. `task_import_dialog.dart:82` 违反全库 DST 防护约定
- `today.add(const Duration(days: 1))` + `DateFormat`（`date_text.dart:6` 明确警告过 Duration 加法）。
  仅用于生成示例 JSON（`today` 来自 clockProvider），影响面小，但应改 `addLocalDays` + `formatLocalDate` 保持一致。

### 【低】7. 魔法值/裸串
- SnackBar 时长（6s/2s/8s）散落、路由路径裸字符串 11 处（部分页面已用 `XxxPage.route` 好做法）、
  内联 fontSize/fontWeight ~74 处、`'#3F6C51'` 默认科目色在 4 个仓储重复。
- 注：硬编码中文文案数千条——单语言本地优先应用不做 l10n 可接受，不建议为此引入 i18n。

### 【低】8. 超大单文件
- `progress_page.dart` 1791 行（5 provider + 13 私有组件 + 顶层工具）、`calendar_view.dart` 1506 行。
  分区清晰、注释充分，但 1500+ 行评审成本高。`migration.dart` 2486 行是 **drift 生成代码**，不算手写上帝文件。

---

## 三、架构与可测试性

**整体**：分层规范（`core` 零向上依赖、`services` 纯 Dart、presentation 不直接摸数据库、
跨 feature 依赖单向无环、事务与刷新机制用心），未发现「真实架构缺陷级」问题。
评分参考：分层 9/10 · 依赖方向 9/10 · 可测性 8/10 · 测试覆盖 8.5/10 · 职责粒度 7/10。

### 【高】H1. 数据层时间不可注入（可测性最大短板）
- `clockProvider` 只接 UI 层；7 个 repository + backup_codec + sync 共 30+ 处裸 `DateTime.now()`
  （`goal_repository`/`task_repository`/`recurrence_repository`/`milestone_repository`/
  `subject_repository`/`checklist_item_repository`/`settings_repository`/`backup_codec`/`webdav_sync_service` 等）。
  导致时间戳精确断言不可测、跨午夜/日期边界行为只能靠注入 today 参数曲线救国。
- **建议**：给 repository 注入 clock 参数（改动小、价值最高），与 UI 层 `clockProvider` 同一时钟源。

### 【高】H2. WebDAV 推送失败分支零测试
- `webdav_sync_service_test` 覆盖拉取/成功路径；**推送失败**（含「快照成功、meta 失败」的部分失败
  不一致态）无测试。该分支是数据一致性关键路径。
- **建议**：补 push 失败（upload 抛错、meta 失败、超时）用例。

### 【中】M1. main() 启动接线无测试 + 两份失效清单无一致性断言
- 启动拉取/周期/退出推送接线、`markLocalDirty`→首推语义无测试；两份失效清单无「相等」断言
  （正是本次 #4 漏掉周/年视图的土壤）。
- **建议**：为清单抽常量并加单测断言两清单一致。

### 【中】M2. 跨午夜 `_armMidnightTimer` 裸时钟无测试
- `app_router.dart:236-246` 直接用 `DateTime.now()` 定下个午夜定时器；桌面托盘常驻跨天是核心场景。
- **建议**：注入时钟或抽可测的「距下个午夜时长」纯函数。

### 【中】M3. `goal_list_page.dart:598` 标记完成直接 `DateTime.now()`（UI 层裸时钟）
### 【中】M4. 超长 presentation 文件（provider 混入页面文件）
### 【中】M5. `settings.get()` 并发 seed 无用例（insertOrIgnore 竞态路径）
### 【中】M6. sync → backup 强耦合（可接受，需协同演进时注意）
### 【中】M7. 同步抑制窗口裸时钟（同健壮性 #10）
### 【中】M8. `backup_service` 职责过载（导出/恢复/安全副本/清扫/重置 5 项职责）

### 测试盲区清单（对照 lib 功能）
1. WebDAV 推送失败分支（H2）
2. 同步接线：启动拉取/周期/退出推送（M1）
3. 合并恢复的回滚路径（备份某段损坏时事务回滚断言）
4. `buildEnabledTargets` 的 WebDAV 分支（密码缺失/完整）
5. `deferMany`/`deleteMany` 的 >500 分批边界（`kMaxInListSize`）
6. 跨午夜刷新（`clockProvider` 失效）
7. `settings.get()` 并发首次 seed
8. `CloseBehaviorPage` / `ResetDataPage` / `ShortcutsPage` 三个设置子页无 widget 测试
9. 周/年视图在任务变更后的刷新（本次 #4）
10. codec 时间戳损坏（FormatException → BackupException 文案）
11. 同步恢复失败路径的抑制窗口清理（#10）
12. 甘特图脏 `plannedDate` 容错（#5）

---

## 四、跨维度系统性问题（优先级建议）

**P0（数据丢失）**：无。

**P1（本次最值得修，均为外部输入/异常路径静默失败）**：
- 同步 meta `syncedAtUtc` 类型判定（健壮性 #1）
- `_restoring` 异常安全（#2）
- manifest `fromJson` 补 `on Error` 兜底 / 类型判定（#3）
- 周/年视图补进失效清单（#4）

**P2（可维护性）**：日期助手/`_dayDiff` 收敛到 `date_text`（整洁度 #1）→ 状态常量统一（#2）→
失效清单去重（#3 + P1 #4 一起做）→ repository 注入 clock（H1）→ 抑制窗口清理（健壮性 #10）。

**P3（防御性）**：`timecalc-restore` 临时目录清理（#7）、自动备份导出失败提示（#8）、
`cast<int>` 修复（#9）、WebDAV 大小上限（#11）、测试盲区补齐（架构 §三）。

## 五、亮点（值得保持）

- 事务边界完整：所有多表写入（目标级联删/替换导入/恢复/删除重复）单事务回滚；
- 外部输入校验成熟：导入解析对标题长度/真实日历日期/minutes 范围全量校验、错误收集+定位；
- 备份/同步防护：schema 版本守卫、manifest 计数校验、`Error→BackupException` 兜底、
  文件名路径穿越防护（M14）、互斥锁与防回环抑制；
- 日期计算全库统一 DST 安全口径（`addLocalDays` + UTC 归一化）配合可注入 `clockProvider`；
- 全局错误处理：`PlatformDispatcher.onError` + 有界诊断日志 + 启动错误屏 + 导出诊断；
- 性能侧边界：SQLite IN 分批（≤500）、懒加载列表、N+1 收敛、防抖定时器。
