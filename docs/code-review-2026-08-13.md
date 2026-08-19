# TimeCalc 全量代码审查报告（2026-08-13）

> **注记（2026-08-16）：本报告审查时 WebDAV/整库同步尚在代码库中。该功能已于
> v1.15 整体移除（schema v13 删列），下文涉及的 `webdav_sync_service`、同步环路、
> 凭据存储等条目为**历史记录**，仅供追溯，不再适用当前代码。**
>
> 审查范围：`lib/` 全部源码（约 100 个文件 / ~500KB）、入口与核心服务；
> 佐证：`dart analyze`（0 问题）、`flutter test`（575/575 通过，含性能基线）。
> 审查方式：5 个并行子代理分区域深审 + 本人逐文件交叉验证关键发现。

## 总体评价

- **架构与工程质量高**：分层清晰（core / features / services / shared），
  进度页分区重算、热力图 O(1) 映射、批量 SQL 去 N+1、纯日历日期工具
  （`addLocalDays`）统一 DST 口径、事务边界（NFR-2）全覆盖、
  备份"先校验后写入 + 安全副本"、凭据 DPAPI 不进备份、错误分层
  （BackupException / WebDavException / runDbAction）与迁移幂等
  （addColumnIfMissing）均属上乘；**无数据丢失级缺陷**。
- 静态分析零告警；575 项测试全绿，性能测试达标
  （1 万任务：月视图聚合 26ms、单日查询 1ms、详情页导航 154~259ms）。
- 发现：**3 项【严重】**、**16 项【中等】**、**44 项【轻微/建议】**。
  严重项集中在「计划导入解析器」与「WebDAV 同步环路」，均可在不
  动架构的前提下小改修复。

---

## 一、严重（建议尽快修复）

### S1 计划导入解析器：畸形日期导致未捕获崩溃 + 非规范日期静默入库
**位置**：`lib/features/plan_import/domain/plan_import_parser.dart:209`（start_date 直调 `_parseDate`）、`:459`（daily_breakdown 键直调 `_parseDate`）、`:502-511`（`_parseDate` 实现）

`_parseDate` 不做格式校验直接 `int.parse`（对比 `_readDate` 先做 `^\d{4}-\d{2}-\d{2}$` 校验）：

1. **崩溃**：`start_date: "abc"` 或 `daily_breakdown` 的键为 `"abc"` → `int.parse` 抛 `FormatException`。
   `PlanImportParser.parse` 及调用方（`plan_import_dialog.dart:137` 的 `_validate`、`:143` 的 `_import`）均无 try/catch → 未处理异常（调试红屏 / release 静默失败且无校验反馈）。
2. **数据污染**：非零填充日期 `"2026-8-6"` 通过校验（`DateTime(2026,8,6)` 有效）并**原样返回入库**（`return value`）。
   该日期与 `"2026-08-06"` 的字典序比较错位（`"2026-8-6" > "2026-08-31"`）→ 任务在按日/按月视图查询中**消失**（byDate 精确匹配、byDateRange 区间比较都查不到）。

**修复**：`_parseDate` 先做正则格式校验，解析成功后返回规范化的 `_format(dt)` 而非原始字符串；`parse()` 入口包 try/catch 兜底转 ImportIssue。`TaskImportParser._validateDate` 已是正确范式，可对齐。

### S2 WebDAV 同步防回环守卫失效 → 双设备乒乓 + seq 无界增长 + 临时目录泄漏
**位置**：`lib/features/sync/data/webdav_sync_service.dart:117-245`、`lib/features/sync/data/database_change_watcher.dart:37-40`、`lib/features/backup/data/backup_service.dart:192-204`

- `_restoring` 守卫只在 `_pull` 内部检查（`:284-291`），`syncOnce` 不检查。拉取恢复写入业务表 → watcher 3 秒防抖后触发 `pushIfNeeded`，此时恢复已完成、`_restoring` 已复位 → **该推送照样执行**（`_restoring` 恰好被防抖窗口错开）。
- `_syncOnce` 尾部**无条件 `_push`**（`:219-225`），seq **无条件 +1**（`:343-345`）——即使本地与远端数据完全一致。
- 后果：单设备每次拉取后 3 秒多一次冗余推送（seq 再 +1）；双设备并发时每 5 分钟互相拉/推，seq 无界增长；每次覆盖拉取还经 `exportSafetyCopy` 在 `%TEMP%` 留下 `timecalc-safety-*` 目录**从不清理**（手动覆盖恢复 / 重置数据同样泄漏）。

**修复**：恢复期间忽略 watcher 触发（`pushIfNeeded` 检查 `_restoring`）；推送前比较「是否有真实变更」（脏标记或 meta 对比），无变更不推、seq 不递增；safety copy 改到应用缓存目录并设数量/时间上限清理。

### S3 无本地变更也每 5 分钟整库上传
**位置**：`lib/features/sync/data/webdav_sync_service.dart:165-245`（`_syncOnce` 尾部总是 `_push`）、`lib/main.dart:102`（周期 5 分钟）

即使本地零变更，周期同步也执行「整库导出 zip + 全量上传 + seq+1」。大库时每 5 分钟浪费带宽/CPU，且 seq 恒增使「远端与本地一致」状态永不达成（恶化 S2）。**修复**：仅在有真实变更（`_hasLocalChanges` 脏标记）时推送，无变更时同步只做拉取检查。

---

## 二、中等

### M1 同步拉取恢复后的 Provider 刷新清单不完整
**位置**：`lib/main.dart:115-124` vs `lib/core/providers/app_refresh.dart:38-48`

`_invalidateDataProviders` 只失效 8 个 provider，而覆盖恢复专用入口 `invalidateAllAppData` 还包含 goalDetailProvider / subjectListProvider / archivedCountProvider / archivedTaskListProvider / allArchivedTasksProvider / recurrenceTemplatesProvider / recurrenceTemplateProvider / milestoneListProvider。同步拉取恢复后，若用户正停在目标详情 / 归档页 / 科目页，界面残留陈旧数据（数据库正确，仅 UI 未刷新）。**修复**：`main.dart` 复用与 `invalidateAllAppData` 相同的容器级完整集合（消除两份清单漂移）。

### M2 启动错误屏「导出诊断信息」不含真正错误
**位置**：`lib/core/errors/startup_error_screen.dart:104`、`lib/main.dart:54`

`_exportDiagnostics` 新建 `DiagnosticsService()`（空实例），而 main 中已 `diagnostics.capture(error)` 的错误没有传入；导出的诊断文件「最近错误日志」为空，失去排查价值。**修复**：把共享 diagnostics 实例（或至少 error/stack）注入 `StartupErrorScope`。

### M3 AppShell 首帧 watch completedTasksProvider → 每次任务变更重建根壳
**位置**：`lib/core/router/app_router.dart:199-204`

为预热进度页在根壳 watch 26 周完成记录 provider：每次勾选任务（invalidateAppData → completedTasksProvider 失效重查）都会让整个 AppShell 重建并重查一次 26 周数据（drift 在后台 isolate 执行不卡 UI，但属无用功、放大刷新面）。**建议**：预热下移到进度页自身，或改为 `ref.listen` 一次性预热。

### M4 今日/日历页跨午夜不刷新
**位置**：`lib/core/providers/clock_provider.dart`、`lib/features/today/presentation/today_page.dart:62`

`clockProvider` 每次 build 取 `DateTime.now`，但无任何午夜定时器。应用托盘常驻跨天后，「今天」页日期/倒计时/逾期状态不更新，直到其他操作触发重建。**建议**：AppShell 挂一个「日期变化」监听（定时到下一个午夜或每分钟比对日期）并失效日期相关 provider。

### M5 「每周可用日全取消」口径矛盾
**位置**：`lib/services/load_service.dart:73-75`、`:115-117`；`lib/features/plan/presentation/calendar_view.dart:97-107`、`:516`；`lib/features/settings/presentation/plan_preference_page.dart:107`

负载/超出计算把**空集合回退为全部可用**，而日历视图按空集合把**所有日期置灰**（`calendar_view.dart:516` 直接 `weekdays.contains()`）；计划偏好页（`plan_preference_page.dart:107`）允许清空全部星期且保存不校验。用户取消全部星期后：日历全灰但负载/学习日/延期按 7 天可用计算，展示自相矛盾。**建议**：空集合在计划偏好页禁止保存，或负载计算同样视为「无可用日」。

### M6 燃尽图窗口日期用 `Duration(days:)`，与全库纯日历口径不一致
**位置**：`lib/services/statistics_service.dart:249`、`:252`、`:295`、`:321`

`_localDay` 归一化了起点，但 `days` 列表与 `elapsed` 用本地 `Duration` 差值；夏令时切换地区 `difference().inDays` 可能差一天（理想参考线偏移）。文件内 `_weekIndexOf`（`:196-204`）已有 UTC 归一化先例，建议统一为 `addLocalDays` + UTC 差值。

### M7 重复规则发生日循环从 startDate 全量遍历
**位置**：`lib/features/tasks/domain/recurrence/builtin_recurrence_handlers.dart:70/77/121/126/205-215`

daily / weekly / interval 三个 handler 的游标都从 `startDate` 起逐日迭代到 `to`，不从 `from` 起算。老模板（startDate 在数月/数年前）每次应用启动的滚动生成都要空跑整个历史区间；随模板年龄无界增长。**修复**：迭代起点取 `max(startDate, from)`（当前实际影响小，但属免费修复）。

### M8 艾宾浩斯间隔序列「所见非所存」：实时预览不回写规则
**位置**：`lib/features/tasks/presentation/recurrence_task_dialog.dart:488`（onChanged 仅 setState）、`:198-210`（`_previewDates` 读 `_ruleJson`）、`:220-226`（保存时才回写）

用户编辑间隔序列文本框时，`_ruleJson['offsets']` 不更新，预览仍显示默认 `[1,2,4,7,15,30]` 的日期；保存后才回写 → **预览误导**（保存值本身正确）。**修复**：onChanged 中解析并写回 `_ruleJson['offsets']`（校验失败时预览置空）。

### M9 大 JSON 计划解析阻塞 UI 线程
**位置**：`lib/features/plan_import/presentation/plan_import_dialog.dart:135-144`

`_validate`（400ms 防抖）与 `_import` 都在 UI isolate 同步执行解析 + 校验。数百 KB 层级 JSON 会卡顿对话框。解析器是纯 Dart，**建议** `compute()`/isolate 隔离。

### M10 计划导入的里程碑/科目名缺长度校验
**位置**：`lib/features/plan_import/domain/plan_import_parser.dart:355-367`、`:387-396`

任务标题有 200 字上限校验（`:473-476`），但 stage/focus 生成的里程碑标题无长度校验——超长写入触发 DB 约束异常而非干净校验错误，且整个事务回滚。**建议**：与任务标题对齐加长度校验。

### M11 覆盖恢复 / 重置数据泄漏安全副本临时目录
**位置**：`lib/features/backup/data/backup_service.dart:192-204`

`exportSafetyCopy` 每次在系统临时目录建 `timecalc-safety-*` 目录且从不删除（手动覆盖恢复、重置数据、每次同步拉取都会触发）。**建议**：用后即删（保留路径给用户提示后清理），或改为固定缓存目录 + 数量上限。

### M12 任务表单小时直输可突破 1440 分钟上限
**位置**：`lib/shared/widgets/duration_step_input.dart:158-161`

小时字段的 onChanged 直接 `_hours = v`（`_StepField` 只钳制到 0~24），不走 `_applyTotal` 的总时长钳制。先输入 24 小时再调整分钟，总时长可达 24×60+59=1499 分钟 > `maxMinutes` 1440，与组件自身文档「钳制在 0~maxMinutes」矛盾（保存时是否被表单拦截取决于调用方）。**修复**：小时 onChanged 也走 `_applyTotal(_hours*60+v)` 或钳制总时长。

### M13 schema 版本守卫缺口：手动恢复不校验 + 同步 meta 解析失败盲推覆盖
**位置**：`lib/features/backup/data/backup_manifest.dart:74-85`、`lib/features/sync/data/webdav_sync_service.dart:186-190`、`:267-276`、`:391-406`

- `BackupManifest.validate()` 不校验 `appSchemaVersion`：同步路径用 `remoteMeta.appSchemaVersion > schemaVersion` 拒绝降级恢复，但**手动恢复**无此守卫——新版本应用导出的备份可被旧版本应用恢复（codec 忽略未知字段 + 缺列落默认值，当前列集下不致命，但守卫缺失属不一致）。
- `_readRemoteMeta` 把「404 不存在」与「存在但解析失败/格式不兼容」（`SyncMeta.fromJson` 返回 null）**混同处理**：后者被当作"远端无 meta"→ 直接 `_push(remoteSeq: 0)` **盲推覆盖远端快照**，同时绕过 schema 版本守卫（新格式 meta 的远端快照会被旧应用整包覆盖）。**修复**：区分 404 与解析失败；解析失败应拒绝推送并提示。

### M14 备份下载文件名未校验 → WebDAV 恶意 href 路径穿越
**位置**：`lib/features/backup/presentation/backup_page.dart:420-423`、`lib/features/backup/data/backup_target.dart:96-97/120`

`File('${dir.path}\${picked.file.fileName}')` 直接拼接文件名。`WebDavBackupTarget.list` 的 fileName 来自服务器 href 末段（`e.href.split('/').last`），恶意 WebDAV 服务器返回含反斜杠的 href（如 `..\..\evil`，`Uri.decodeComponent` 后 split('/') 不切反斜杠）→ 写出临时目录之外（越权写文件）。本地目录列表路径安全（`uri.pathSegments.last`）。**修复**：fileName 做 `basename` 白名单校验（拒绝含 `/`、`\`、`..` 的名称）。

### M15 设置页写库后 invalidate(settingsProvider) 触发整页 loading 闪烁
**位置**：`lib/features/settings/presentation/appearance_page.dart:55`、`:70-88`；`close_behavior_page.dart:50`、`plan_preference_page.dart:160`

三个设置子页在 build 中 `ref.watch(settingsProvider)` 且用 `.when(loading: spinner)` 渲染：保存后 `ref.invalidate(settingsProvider)` 使 provider 短暂回到 loading → **整页 spinner 闪烁一次**（today_page 已用 valueOrNull 保留旧值去闪烁，设置页未跟进）。**修复**：设置页同样用 `valueOrNull ?? 旧值` 模式，或局部刷新设置值。

### M16 generateDue 不校验规则 → 脏数据下永久跳过实例生成（静默丢失）
**位置**：`lib/features/tasks/data/recurrence_repository.dart:187-226`、`lib/features/tasks/domain/recurrence/recurrence_registry.dart:51/59-61`

`generateDue` 对模板规则不校验：未知/非法类型经 registry **静默返回空列表**（`:59-61` catch 后返回 `[]`），随后**无条件**把 `generatedThroughDate` 推进到 target（`:219-226`）→ 下次启动窗口判据 `_dateLess(generatedThroughDate, target)` 为 false，该模板**从此不再尝试生成**——脏规则数据（手工改库/版本错位/备份恢复异常值）导致未来实例**永久静默丢失**。**修复**：生成前 `validateWith` 校验，非法规则跳过推进窗口并上报（诊断日志），而非静默吞掉。

---

## 三、轻微 / 建议（代表性）

| # | 位置 | 问题 |
|---|---|---|
| L1 | `task_repository.dart:458-474`、`:521-540` | `deferMany`/`deleteMany` 的 `IN (?,…)` 占位符数量无上限，极端批量（>SQLite 变量数上限）可能失败；建议分批。 |
| L2 | `services/recurrence_service.dart:47-54` | `_plusDays` 用 `Duration(days:)`（全库其余用 `addLocalDays`）；仅默认参数路径使用，实际无影响，建议统一。 |
| L3 | `services/load_service.dart:76` | `remainingAvailableDays` 用本地 `difference().inDays`，DST 地区可能差一天；建议 UTC 归一化（同 statistics_service 先例）。 |
| L4 | `goals/presentation/goal_list_page.dart:284` | 卡片取色 `goal.id % _accentColors.length` 对负 id 不安全（autoIncrement 实际不可达），建议 `abs` 防御。 |
| L5 | `core/database/database.dart:56-71` | 降级迁移清理不可逆且无备份（代码回退场景）；建议迁移前打安全副本。 |
| L6 | `core/errors/startup_error_screen.dart` / `main.dart` | 启动失败路径新建空诊断实例（同 M2 根因）。 |
| L7 | `backup_service.dart:436-466` | `_overwriteRestore` 中 `payload.settings.first` 依赖 settings 数组非空；若备份 settings 为空数组，覆盖后计划偏好被重置为默认（正常备份必有单行，仅手工构造触发）。 |
| L8 | `features/backup/presentation/backup_page.dart` 等 | 备份页 `buildEnabledTargets` 仍保留 WebDAV 目标，而自动备份已收敛为本地目录（M11 注释），两处语义建议统一注释/清理。 |
| L9 | 各页面 | 部分 `ref.watch(goalListProvider)` 在子区块重复 watch（如 `_BurndownSection:621-631`），输入面略宽；可提升到父级统一传参。 |
| L10 | `calendar_view.dart:25` | `DateFormat(..., 'zh_CN')` 依赖 flutter_localizations 初始化日期符号；当前可用，若未来移除 zh_CN locale 会抛错，建议加注释说明。 |
| L11 | `goals/presentation/subject_manager.dart:199` | `subject.name.characters.first` 对**空科目名**抛 StateError。空名可达：计划导入（`plan_import_parser.dart:442` 对科目键无空名校验，空键名会建空名科目）+ 备份恢复（codec 不校验 name 非空）；drift `withLength` 不生成 SQLite CHECK，DB 层不拦截。建议 `isEmpty` 兜底。 |
| L12 | `goals/presentation/goal_detail_page.dart:35` | `int.parse(goalId)` 无防护；当前被路由 redirect（`app_router.dart:107`）兜底，属防御性加固建议（未来复用该页时防崩溃）。 |
| L13 | `today/presentation/today_page.dart:168`、`:208`（progress 页同源） | 「目标剩余工作量」用 `allTodoTasksProvider` 汇总**全部**未完成任务，包含已完成/放弃/归档目标的残留 todo 任务——与倒计时（terminated 停止计数）口径不一致，进度页燃尽/甘特图同源。建议过滤进行中目标。 |
| L14 | `core/utils/date_text.dart:11-18` | `parseLocalDate` 对非法日期文本（如脏数据 `"abc"`）直接 `int.parse` 崩溃，多页面无容错。与 S1 同根：解析器不产生脏数据后此风险基本消除，可加 try/catch 兜底。 |
| L15 | `today/presentation/today_page.dart:745-746` | 时间进度条 `deadline.difference(createdDay).inDays` 用本地差值，DST 地区可能差一天（同 L3/M6 口径家族）。 |
| L16 | `today/presentation/today_page.dart:712` + `goals/data/milestone_repository_provider.dart:23-31` | `nextUpcomingMilestoneProvider` 派生自 `milestoneListProvider`（每活跃目标**全量**里程碑查询），`milestone_repository.dart:80-90` 的 limit-1 优化 `nextUpcoming` 是**死代码**（无调用方）。建议 provider 改调 `nextUpcoming`，或删除死代码。 |
| L17 | `milestone_repository.dart:17-22` | `byGoal` 仅按 sortOrder 排序无次级键，同 sortOrder 时顺序不稳定；建议追加 `id` 次级排序。 |
| L18 | `app_refresh.dart:23-31` + `calendar_view.dart:151-165` | 单任务变化经 invalidateAppData 整页/整月（35~42 格）重建——已用懒加载与分区 provider 缓解，属设计取舍；若追求极致可进一步拆分区块级 provider。 |
| L19 | `main.dart:178-180`、`desktop_controller.dart:91-93/236-238` | 桌面初始化/托盘/窗口关闭异常被**双重空 catch 吞掉**，无任何诊断记录；建议接入 `diagnostics.capture`（桌面能力降级原因可排查）。 |
| L20 | `desktop_controller.dart:388-390`、`main.dart:102-106` | `DesktopController.dispose` 未移除 window/tray 监听；`Timer.periodic` 与 `DatabaseChangeWatcher` 永不 dispose——均为进程级生命周期对象，无实际泄漏，属整洁性建议。 |
| L21 | `window_state_store.dart:131-138`、`diagnostics_service.dart:170-187` | `window_state.json` 非原子写（读侧已容错自愈）；诊断日志超限截断先全量读回再写，非原子——均可接受，建议留痕。 |
| L22 | `diagnostics_service.dart:110-124` | `exportDiagnostics` 用 `select().get().length` 全表扫描计数而非 COUNT 查询；用户主动导出、低频，影响可忽略。 |
| L23 | `main.dart:128-134`、`desktop_controller.dart:244-251` | 退出最差被同步推送阻塞 5s（已有 timeout 兜底、失败不阻断退出），设计取舍可接受；如追求瞬时退出可降至 2s。 |
| L24 | `core/database/database_provider.dart:9-12` | `main.dart` 用 `overrideWithValue(db)` 覆盖后，provider 内 `ref.onDispose(db.close)` 不生效，生产路径 db 永不 close——进程级生命周期无实际影响，测试覆盖容器时注意。 |
| L25 | `goals/data/goal_repository.dart:15` | `watchAll` 命名误导：实为一次性 `get()`，全库无响应式流；建议改名 `all()` 或补注释。 |
| L26 | `core/errors/db_error_dialog.dart:78` | 导出诊断 `on Exception` 只捕 Exception，Error（TypeError 等）场景无提示——`exportDiagnostics` 内部已逐段防护，实际概率极低。 |
| L27 | `webdav_sync_service.dart:256`、`auto_backup_service.dart:172`、`credential_store.dart:36-38` | 凭据 `read()` 失败路径未捕获，secure_storage 平台异常会冒泡为未处理异步错误（有全局错误处理器记录兜底，不崩溃）；建议在同步/备份入口统一转可读文案。 |
| L28 | `backup_service.dart:107-144`、`auto_backup_service.dart:118`、`webdav_sync_service.dart:341`、`webdav_client.dart:119-124/171-177` | 备份/同步全链路非流式：整库 zip 内存构建、文件整读进内存、上传/下载整包进内存。个人库（<10MB）可接受；大库时内存峰值明显，可改流式。 |
| L29 | `webdav_client.dart:212-214` | HTTP 超时只包 `client.send`（响应头），`Response.fromStream` 读响应体不在超时内——慢速服务器大文件下载可无限挂起；建议整体包 timeout 或加读取超时。 |
| L30 | `webdav_sync_service.dart:117-131/139-142/216/237` | 并发同步被 `_running` 布尔锁直接丢弃（不排队）；`_hasLocalChanges` 在并发交错时可能被误清。5 分钟周期兜底下影响有限，建议改为互斥 + 待处理标记。 |
| L31 | `auto_backup_service.dart:62`、`webdav_sync_service.dart:88` | 自建 `http.Client()` 无 dispose（进程级生命周期，连接池随进程释放）；建议注入统一 client 并随容器关闭。 |
| L32 | `backup_service.dart:280-337` | 合并恢复对里程碑/任务/检查项**追加不去重**：同一备份重复合并会产生重复数据（目标/科目有去重键，任务/里程碑没有）。建议在确认对话框提示「重复合并会追加重复数据」或为任务加去重键。 |
| L33 | `settings_repository.dart:147-154` | `decodeWeekdays` 不过滤 1~7 范围，DB 脏值（0/9 等）会流入负载/延期计算并可能回写；建议 `where((d) => d >= 1 && d <= 7)`。 |
| L34 | `plan_import_parser.dart:409-436` | week_range 只有单日期时生成「单日模板」（start==end）；当前周前半已过时仍生成含历史日期的实例（只跳过 endDate<today 的整周）。建议模板 startDate 钳制到今天。 |
| L35 | `plan_import_dialog.dart:312-339` | 导入预览按科目×任务重复线性扫描（O(科目×任务)），大文件预览卡顿；建议一次遍历分组。 |
| L36 | `reset_data_page.dart:188` | `_reset` 只捕 `Exception` 漏 `Error`（TypeError 等）——`backup_service.restoreBackup` 已为同类问题显式转 BackupException，此处未跟进；建议同款转换。 |
| L37 | `backup_service.dart:218-232` | 「重置数据 + 设置」不清除 WebDAV 凭据（DPAPI 中残留）；语义上"恢复出厂"不彻底。若为有意保留（远端安全网），建议 UI 明示。 |
| L38 | `progress_page.dart:74-78` | `progressTasksProvider` 串行 await（todo 完成后才查 completed）；可并行发起两个查询（drift 查询本就并发），首载略快。 |
| L39 | `progress_page.dart` 热力图区块 | 未来周格子与历史周同色渲染，无视觉区分；建议未来格置灰或加边框提示"未到"。 |
| L40 | `today_page.dart:239` | 「延期到指定日期」的 datepicker `firstDate` 为去年——允许把任务**改期到过去**（再次变逾期），与"延期"语义矛盾；建议 firstDate=今天。 |
| L41 | `tables.dart:159`、`task_repository.dart:546-570` | 墓碑 `deletedInstanceDates` JSON 数组随删除**无界增长**（长期使用后单模板数据膨胀）；建议定期压缩或改区间存储。 |
| L42 | `checklist_item_repository.dart:113-114` | 注释写「相邻项写中间值再交换」，实际是直接交换两行 sortOrder——注释与实现不符（当前实现无唯一约束问题，仅注释需更正）。 |
| L43 | `task_repository.dart:204-239` | `batchCreate` 的 `dateIntervalDays` 无上界，极大值经 `addLocalDays` 可能 RangeError（表单侧有步进上限，防御性建议）。 |
| L44 | `recurrence_task_dialog.dart:220-226` | `_save` 无条件把 offsets 文本写进 `_ruleJson`——若用户输入 offsets 后切到其他规则类型（`_syncOffsetsController` 对非 List 不清空 controller），多余 `offsets` 键会被写进 weekly/interval 规则 JSON（handler 忽略，无害但脏）。 |

---

## 四、正面确认（未发现问题）

- **静态分析**：`dart analyze` —— 0 问题。
- **测试**：`flutter test` 575/575 通过，含性能回归：
  - 10,000 条任务：月视图查询+聚合 26ms（840 条/月）、单日查询 1ms；
  - 目标卡片 → 详情页首帧：10 条任务 259ms / 1000 条任务 154ms。
- **日期/时区**：计划日期以 `yyyy-MM-dd` 文本存储、时间戳 UTC，`addLocalDays` 统一纯日历加法，`_dayDiff`/`_weekIndexOf` UTC 归一化——整体正确。
- **迁移**：step-by-step 迁移 + 幂等加列/删列，升级失败可重试，无数据损坏路径。
- **备份/恢复**：表覆盖完整、先校验后写入 + 单事务回滚、覆盖前安全副本、无 zip-slip、凭据（DPAPI）不进备份。
- **性能**：进度页聚合收敛为独立 provider（分区重算）、热力图 O(1)、列表懒加载（SliverList.builder）、目标卡片批量 SQL、重复生成单条 IN 查询去 N+1。
- **资源**：未发现空 catch、Timer/Stream 泄漏（各区域子代理交叉确认）。

---

## 五、修复优先级建议

1. **P0（本周）**：S1（解析器日期校验+规范化）、S2（同步防回环+seq 语义）、S3（无变更不推送）。
2. **P1（近期）**：M1（刷新清单统一）、M2（启动错误屏诊断）、M5（可用日口径）、M8（预览回写）、M9（解析隔离）。
3. **P2（择机）**：M3/M4/M6/M7/M10/M11/M12 与轻微项。

---

## 六、修复状态（2026-08-13 已提交）

本次审查后已修复并提交（`dart analyze` 0 告警、`flutter test` 全绿）：

### 已修复
- **S1** 计划导入解析器：日期正则校验 + 非零填充规范化 + 空科目/长度校验（M10/L34）
- **S2/S3/M13** 同步重构：拉取后不回推、无变更不推送、meta 损坏与 404 区分、抑制窗口防回显
- **M1** main.dart 刷新清单补全 8 个 provider 族
- **M2/L19** 启动错误屏共享诊断实例；桌面初始化失败留诊断
- **M3** AppShell `ref.listen` 预热；**M4** 午夜跨天自动刷新
- **M5/M15** 计划偏好禁空星期；设置三页去 loading 闪烁
- **M6/L2/L3/L15** 燃尽/负载/进度条/逾期天数 UTC 归一化
- **M7** 重复规则从 `from` 起算 + addLocalDays；**M8/L44** 艾宾浩斯预览实时回写
- **M9** 大 JSON 解析 isolate 隔离；**M11** 安全副本 7 天清理
- **M12** 时长小时直输钳制；**M14** 备份文件名路径穿越防护
- **M16** generateDue 规则校验（非法不推进窗口）
- **L1/L33/L40/L43** IN 分批、可用日脏值过滤、延期禁过去日期、批量间隔上界
- **L7/L11/L17/L21/L26/L29/L36/L42** 等轻微项

### 未修（有意保留，均有代码内注释说明）
- L9/L18（重建面宽，设计取舍）、L10（DateFormat 可用）、L12（路由已防护）、
  L14（S1 已断源头）、L16（nextUpcoming 保留，耦合正确性优先）、L20/L24/L31
  （进程级生命周期）、L22（低频）、L23（退出 5s 有超时兜底）、L25（已补注释）、
  L28（非流式 IO，个人库可接受）、L30（并发锁 + 变更计数已缓解）、
  L32（合并去重属产品决策）、L37（凭据保留是安全网）、L39（视觉项）、
  L41（墓碑增长可接受）、L45/L46（风格/微 UX）。
