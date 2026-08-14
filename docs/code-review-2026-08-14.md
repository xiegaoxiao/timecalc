# TimeCalc 业务逻辑专项审查与修复（2026-08-14）

> 审查范围：业务逻辑核心文件（任务 / 重复任务 / 目标 / 里程碑 / 负载 /
> 统计 / 备份 / 同步 / 计划导入 / 三视图日历）。
> 佐证：`dart analyze` 0 问题；`flutter test` 全绿（含新增回归测试）。
> 延续 2026-08-13 全量审查（docs/code-review-2026-08-13.md）之后的复查，
> 重点核对 08-13 整改的回归面与新增功能（周/年视图、目标卡片 Dashboard 等）
> 引入的业务逻辑问题。

## 总体结论

上一轮审查的 S1/S2/S3/M1~M16 已修复且未回归；本轮新发现 **2 项明确业务
逻辑缺陷**（延期语义分裂、目标剩余工作量口径不一致）、**3 项健壮性/口径
问题**（脏模板拖垮滚动生成、周视图 DST 口径、同步 meta 防御性解析）与
若干轻微项，已全部修复并补回归测试。无数据丢失级缺陷。

---

## 一、明确业务逻辑缺陷（已修复）

### #1 延期到指定日期可改期到过去，且两个入口口径分裂
- **位置**：`lib/features/tasks/presentation/task_tile.dart`（`_deferPickDate`）
- **问题**：`firstDate = DateTime(now.year - 1)` 允许把任务「延期」到过去
  日期（再次变逾期），而今日页 FR-3.7 横幅（`today_page.dart`）已按 L40
  修复为 `firstDate: today`。TaskTile 被今日页过期任务区、日历选日面板、
  目标详情、科目页共用——同一操作在不同入口行为相反。
- **修复**：① `firstDate` 钳制为今天（`DateUtils.dateOnly`），与横幅口径
  一致；② 顺带把 `DateTime.now()` 改为注入时钟 `ref.read(clockProvider)()`
  （与 `_deferToNextAvailable` 一致，测试可固定日期）。
- **测试**：today_page_test 新增「延期到指定日期禁止改期到过去」回归。

### #2 进度页「目标剩余工作量」口径与今天页不一致
- **位置**：`lib/features/progress/presentation/progress_page.dart`
  （`progressOverviewProvider`）
- **问题**：进度页概览卡用 `allTodoTasksProvider`（全部未完成任务）计算
  「目标剩余工作量」，未按进行中目标过滤；今天页已按 `activeGoalIds`
  过滤（L13）。已结束/归档目标残留的 todo 任务在两页显示不同数字，且与
  倒计时（terminated 停止计数）口径矛盾。
- **修复**：概览卡 `remainingMinutes` 按进行中目标过滤；燃尽/甘特图保持
  全局趋势（有意保留，代码注释说明）。
- **测试**：progress_page_test 新增「目标剩余工作量只统计进行中目标」回归。

---

## 二、健壮性与口径问题（已修复）

### #3 日历周视图/周导航的日期算术用 `Duration(days:)`，与全库 `addLocalDays` 不一致
- **位置**：`calendar_view.dart`（`_mondayOf`/周翻页/周标题/周格/ISO 周号）、
  `task_repository_provider.dart`（`tasksByWeekProvider`）
- **问题**：全库其余日期计算（statistics/gantt/recurrence/load/today）刻意用
  `addLocalDays` 防 DST 切换日偏移一天；周视图是 v1.12 新功能未沿用，DST
  切换周里周起点/周格日期可能错位一天。
- **修复**：全部改为 `addLocalDays`；ISO 周号（`_isoWeekNumber`）同时
  用纯日历加法 + UTC 归一化天数差（算法本身正确，仅消除 DST 偏差）。
- **测试**：既有 calendar_views_widget_test「第 32 周」断言继续覆盖。

### #4 `generateDue` 遇脏 `generatedThroughDate`/startDate 拖垮全部模板滚动生成
- **位置**：`lib/features/tasks/data/recurrence_repository.dart`（`generateDue`）
- **问题**：`generatedThroughDate` 为 `''`（旧备份恢复 codec `?? ''` 兜底、
  手工改库）时 `_plusDays('')` 抛 `FormatException` → 整个 `generateDue`
  事务中止 → 所有 active 模板都不生成缺失实例，且 `recurrenceBootstrapProvider`
  的错误被 `ref.listen` 吞掉，每次启动重犯；`startDate` 非法虽被 registry
  兜底为空列表，但会静默推进窗口永久跳过（同 M16 语义）。
- **修复**：生成前对 `generatedThroughDate`/`startDate` 做日期格式校验，
  非法则跳过该模板且不推进窗口（下次启动重试）。
- **测试**：recurrence_repository_test 新增 2 项（脏 generatedThroughDate 不
  中断其余模板 / 脏 startDate 跳过且不推进窗口）。

### #5 `updateRule`「仅修改模板」缩短 endDate 后窗口记账越界
- **位置**：`lib/features/tasks/data/recurrence_repository.dart`（`updateRule`）
- **问题**：template 应用保留旧 `generatedThroughDate`；结束日缩短到旧窗口
  之前时，窗口记账「越过结束日」且超窗实例残留（语义上不动实例可接受，
  但记账不一致）。
- **修复**：template 应用时把 `generatedThroughDate` 钳制到新结束日
  （endDate 为空/未缩短时保持原窗口）；实例不受影响。
- **测试**：recurrence_repository_test 新增「仅修改模板缩短 endDate 钳制窗口」回归。

### #6 `SyncMeta.fromJson` 用 `as int?` 强转，非 int 远端 meta 抛 TypeError
- **位置**：`lib/features/sync/data/webdav_sync_service.dart`（`SyncMeta.fromJson`）
- **问题**：远端 meta 由第三方/手工构造产生 double（如 `5.0`）时强转抛
  `TypeError`（Error，上层只 catch `WebDavException` 捕不到，冒泡为未处理
  异步错误）。
- **修复**：改 `is int` 类型判定，非 int 统一返回 null → 上层转「元数据
  版本不兼容，已停止同步」可读错误。

---

## 三、轻微/口径（已修复或确认可接受）

| # | 位置 | 处理 |
|---|---|---|
| #7 | `task_repository_provider.dart` completedTasksProvider UTC 时间窗 | 确认充足（26 周 + 1 天 ≥ 热力图 26 周网格），无需修改 |
| #8 | `calendar_view._isoWeekNumber` | 算法结构正确，仅 DST 口径修正（并入 #3） |
| #9 | `recurrence_task_dialog._plusDays` | 预览日期算术统一 `addLocalDays` |
| #10 | `plan_import_dialog` 示例 JSON 日期 | 示例日期算术统一 `addLocalDays`（纯展示） |

---

## 四、验证

- `dart analyze`：0 问题。
- `flutter test`：全绿（含新增 5 项回归测试：延期下界 / 进度页口径 /
  generateDue 脏数据 ×2 / updateRule 窗口钳制）。
- 上一轮 S1/S2/S3/M1~M16 整改未回归（日历/同步/进度/导入相关测试全绿）。
