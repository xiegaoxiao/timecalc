# A：计划 / 日历 / 智能重排

> 审计员：audit-plan（task-1，只读审计）｜审计基线：已发布 v1.18.0（`lib/core/app_version.dart:6` = `1.18.0`，`pubspec.yaml:19` = `1.18.0+1`）+ 工作区 94 处未提交改动（v1.19 进行中，`CHANGELOG.md` 尚无 v1.19 条目）。
> LOC 口径：全文行数（含注释与空行），由 `(Get-Content <file>).Count` 实测；任务书中给出的数字为「非空行数」，两者会差 15% 左右。所有行号取自当前工作区快照。
> 本次审计除本报告外**未修改、新建、删除任何仓库文件**；未运行 flutter build / test / pub get；未执行任何 git 写操作。

## 0 结论摘要

1. **智能重排草稿（A1）不建议以当前形态进入 v1.19 发布。** 它对应 PRD §5.3 第 3 条的 P1「均匀重排未完成任务草稿」（`docs/requirements.md:112`），不是无据镀金；但生产代码约 2.9k 行 + 测试约 1.46k 行，且把 v1.19 一并拖进 schema v18、备份格式与跨模块耦合（课表作息、后台 isolate）。
2. **`tasks.schedule_locked`（A2，schema v18）建议移除。** 为服务的只是一个 P1 可选功能，却引入永久 DB 列、v17→v18 迁移、备份字段，并使 v18 备份**无法被回退版本恢复**（`lib/features/backup/data/backup_service.dart:194` 的 `appSchemaVersion > schemaVersion` 守卫）——这是全部候选里唯一有数据后果的一项。
3. **计划页年视图（A3）建议移除。** `_YearGrid`（161 行）只展示「当月完成数 + 完成强度」，是进度页热力图（FR-7.2 P0）的月粒度复刻，与 §7「计划回答『我打算做什么』」的排程语义相悖，删除不触及 DB/备份。
4. **任务 JSON 导入（A6）建议并入完整计划导入或降级保留。** 它与「批量添加」和「完整计划导入」是同一需求的三份实现，PRD 中除课表 `.ics`/JSON 外没有任何导入要求。

## 1 条目表

| ID | 功能或机制 | 用户可见入口 | 代码证据(file:line, LOC) | PRD | 是否重复 | 判定 | 删除代价与风险 | 置信度 |
|---|---|---|---|---|---|---|---|---|
| A1 | 智能重排草稿整体（范围选择 → 预览 → 应用 → 撤销基线） | 计划页头部「重新安排」；目标详情负载区「重新安排」 | `lib/services/planning_service.dart:40-637`（1324 行）；`lib/features/plan/presentation/plan_draft_dialog.dart:61-1134`（1134 行）；`lib/features/plan/data/planning_repository.dart:1-147`；`planning_repository_provider.dart:1-26`；`plan_draft_undo_controller.dart:1-42`；落库 `lib/features/tasks/data/task_repository.dart:650-778`（约 130 行）；测试 767+359+334 行/33+14+13 项 | §5.3-3「P1 可提供『均匀重排未完成任务』草稿」（:112）；FR-5.5（:172） | 与 FR-5.1 拖拽改期（:168）、FR-3.3 延期（:145）同为「调整任务日期」的第三种实现 | **建议简化或合并** | 无 DB 层代价（若同时按 A2 移除锁定列）；删掉后用户失去「一次批量摊平」能力，退化为逐条拖拽/延期 | 中高 |
| A2 | `tasks.schedule_locked`（schema v18）+ v17→v18 迁移 + 备份字段 + 任务菜单锁定项 | 任务行「⋯」→「锁定排期 / 解除锁定排期」 | `lib/core/database/tables.dart:163-173`；`lib/core/database/database.dart:154, 395-405`；`database.g.dart:2542-2575`；`lib/features/backup/data/backup_codec.dart:62-63, 200-202`；`lib/features/tasks/presentation/task_tile.dart:362-376, 421-427, 583-603` | 未列（FR-5.5 只要求「建议不自动改」） | 无 | **建议移除** | 需回退 schemaVersion 18→17 并清理列；`drift_schemas/drift_schema_v18.json`、`test/generated_migrations/schema_v18.dart` 需同步删；已产出的 v18 备份将无法恢复 | 高 |
| A3 | 年视图（12 月完成热力格，点月下钻月视图） | 计划页头部「周 / 月 / 年」→「年」 | `lib/features/plan/presentation/calendar_view.dart:34`（枚举）、`:192-203`（`completedCountsByMonth`）、`:238-247`（年导航）、`:1726-1886`（`_YearGrid`，161 行）；`tasksByYearProvider` | 未列；FR-3.4（:146）只要求日历展示每日任务数/完成数/预估时长 | 与进度页热力图（FR-7.2 P0）（:201）语义重复；`docs/plan-calendar-views-design.md:57` 自述「避免重复」 | **建议移除** | 无 DB/备份影响；`calendar_views_widget_test.dart`（332 行/6 项）含年视图用例需改；失效清单里年视图条目可一并删 | 中高 |
| A4 | 4 个重排范围 + 3 类跳过原因 + 3 类未安排原因 + 双容量 80%/100% | 重排对话框第一步单选组 + 预览分区 | `planning_service.dart:639-690`（枚举）、`:261-295`（范围收窄）、`:391-488`（落位）、`:492-574`（风险文案）、`:1108-1302`（`_DayLedger`）；`plan_draft_dialog.dart:250-374`（范围步）、`:955-1134`（未安排/跳过分区） | §5.3-3 只描述一种「均匀重排未完成任务」 | 是：同一需求 4 个变体 + 3+3 种失败态文案 | **建议简化或合并** | 无（纯算法/UI 收缩）；保留「仅安排未排期任务」单档即可覆盖 §5.3 场景 | 中高 |
| A5 | 课程占用扣减每日容量 | 无独立入口（草稿内隐式规则，仅风险文案提及） | `planning_service.dart:66-73`（`courses`/`semesterStartDate` 入参）、`:516-521`（课程扣减文案）、`:1272-1295`（教学周/单双周换算）；耦合 `planning_repository.dart:116-146`（`ClassPeriods` + `CourseRepository`） | FR-10.6（:234）「课程不参与任务负载」；§7（:255）「课表与计划互补而不重叠」 | 与 `lib/services/load_service.dart:39-166`（180 行，FR-5.2 P0 口径）算两套容量 | **建议简化或合并** | 无 DB 代价；删掉后重排只看每日可用时长，与 `LoadService`/日历「超出 X 分钟」口径完全一致 | 中 |
| A6 | 任务 JSON 批量导入（含替换/合并模式） | 目标详情任务区「更多操作」→「JSON 导入」 | `lib/features/tasks/domain/task_import_parser.dart:1-309`；`lib/features/tasks/presentation/task_import_dialog.dart:1-413`；入口 `task_section_actions.dart:63-91`；测试 151 行/17 项 | 未列（§4.2 任务 P1「批量操作」可涵盖） | 与「批量添加」`batch_task_form_dialog.dart`（437 行）、与 A7 完整计划导入重复 | **建议简化或合并** | 无 schema/备份影响；删除后重度用户失去 JSON 通道，但 A7 与「批量添加」仍在 | 中 |
| A7 | 完整计划导入（JSON + `.ics` → 目标+里程碑+科目+任务+重复模板，单事务） | 目标页区块头「导入完整计划」 | `lib/features/plan_import/domain/plan_import_parser.dart:1-761`；`ics_plan_parser.dart:1-133`；`presentation/plan_import_dialog.dart:1-516`；`data/plan_import_repository.dart:1-167`；`data/plan_file_picker.dart:1-70`；测试 795+168+379+148 行 | 未列 | 与 A6 部分重叠（任务写入路径同源） | **可留（低成本观察）** | 有真实使用证据（`CHANGELOG.md:469`「导入用户实际 JSON」端到端回归），不建议现在动 | 中 |
| A8 | `.ics` 导出（任务 + 里程碑 → 日历） | 计划页头部导出图标按钮 | `lib/features/calendar_io/data/ics_export_builder.dart:1-79`；`ics_export_service.dart:1-71`；`ics_file_picker.dart:1-41`；`ics_codec.dart:423-585`（serialize 侧约 160 行）；入口 `calendar_view.dart:790-794` | 未列（§4.2 课表 P0 只要求 `.ics`/JSON **导入**，:78） | codec 与 A7、课表导入共用，非重复实现 | **可留（低成本观察）** | 若紧缩可删约 310 行并去掉界面入口；不触 DB | 中 |
| A9 | `IcsCodec`（RFC 5545 子集：解析 + 序列化，552 非空行） | 无独立入口（被 A7、A8、课表导入共用） | `lib/features/calendar_io/domain/ics_codec.dart:84-585`；消费者 `ics_plan_parser.dart:24, 30, 43`、`timetable_import_parser.dart:22, 107, 131`、`ics_export_builder.dart:13-18` | FR-10.4（:232）课表 P0 | **不是重复**：三处消费者共用同一底层 codec，各自的差异是「事件 → 领域对象」的适配层 | **必留** | — | 高 |
| A10 | 月视图「隐藏已完成」开关 | 计划页月视图头部 chip | `lib/features/plan/presentation/calendar_view.dart:58, 69, 166-170, 260-263, 833-858`（chip 约 26 行） | 未列；`plan-calendar-views-design.md:169` 自标「可选，可裁剪」 | 无 | **可留（低成本观察）** | 无；属纯展示筛选 | 中高 |
| A11 | 今天页「重新安排」跳转按钮 | 今天页「今日任务」区块头 trailing | `lib/features/today/presentation/today_page.dart:390-402`（`onPressed: () => context.go('/plan')`） | §5.2-4（:106）只要求「集中提示用户选择延期、重新安排或保留原日期」 | 与 A1 在计划页头部的同名按钮重复，且标签像动作实为导航 | **建议简化或合并** | 无；建议删除或改为直接 `PlanDraftDialog.show(context)`（保留可达性） | 中高 |
| A12 | 5 秒批量撤销 FAB + 完成批次控制器（勾选不立即写库） | 今天页右下角圆形倒计时 FAB（仅「过期任务」区勾选时出现） | `lib/features/today/presentation/today_page.dart:486, 1083-1189`（约 107 行）；`lib/features/tasks/data/task_completion_controller.dart:17-131`（131 行）；`task_tile.dart:45, 110, 171-181`；触发点 `today_page.dart:1064` | FR-3.7（:149）要求「必须由用户确认，不自动改变原计划」 | 无 | **可留（低成本观察）** | 无 DB 代价（批次只改 `status`）；触发面窄（今日任务区 `enableCompleteUndo=false`，只有过期区启用），可观测后再定 | 中 |
| A13 | 月/周网格 + 拖拽改期 + 负载条 + 完成徽标 + 选日面板 | 计划页主体 | `calendar_view.dart:890-1340`（`_MonthGrid`/`_WeekGrid`）、`:1569-1734`（`_CompletionBadge`/`_TaskPills`/`_DayLoadBar`）、`:514-532`（FR-5.1 拖拽） | FR-3.2/3.4/3.5（:144-147）P0、FR-5.1（:168）P0 | 无 | **必留** | P0 验收项，删除即闭环保不住 | 高 |
| A14 | 三视图切换器 + 周导航 + 「回到今天」 | 计划页头部 SegmentedButton | `calendar_view.dart:34, 769-778, 217-248` | 周视图未明列（`plan-calendar-views-design.md` 为设计依据）；月视图对应 FR-3.4 | 与月视图同构，非重复实现 | **可留（低成本观察）** | 无；年视图移除后保留「周/月」两项即可 | 中 |

## 2 逐条论证

### A1 智能重排草稿整体 —— 建议简化或合并（不建议以当前形态发布）

- **先给明确表态**：它不是凭空的镀金。PRD §5.3 第 3 条写了「P1 可提供『均匀重排未完成任务』草稿」（`docs/requirements.md:112`），而 FR-6 的 AI 草稿在 v1.8.0 已整体回退（`CHANGELOG.md:525`）；`planning_service.dart:56-257` 的确定性算法正好补上这个 P1 空位，且严格遵守 FR-5.5「只建议不自动改」（`plan_draft_dialog.dart:494-505` 需用户点「应用草稿」才写库）。
- **但相对核心闭环不必要**：闭环是「倒计时 → 今天做什么 → 完成/延期 → 进度反馈」，四条腿全部由 P0 组件承担——今天页任务列表、`TaskTile` 完成、`defer` 延期（FR-3.3）、进度页图表。删掉重排后用户**仍然**能改期（日历拖拽 FR-5.1，`:514-532`）与延期，只是失去「一次批量摊平」，闭环成立。
- **成本与收益严重不对称**：生产代码 1324 + 1134 + 147 + 26 + 42 = **2673 行**，加落库 130 行、任务行锁定 UI 约 60 行，合计约 **2.9k 行**；测试 767 + 359 + 334 = **1460 行 / 60 项**。同时它还把 v1.19 拖进 schema v18（见 A2）、跨模块耦合课表作息（见 A5）与后台 isolate（`planning_repository.dart:76-80`）。
- **删掉它用户会失去什么**：失去「一键把逾期/超载任务摊到截止日前」的批量能力，需逐条拖拽或延期。这确实是效率损失，但属于「更好用」而非「不可用」；且 PRD 把它定位为 P1，§M5（`requirements.md:385`）明确要求「P1 不应在缺少用户验证时同时全部启动」。
- **核心闭环是否还成立**：成立（依赖它为零）。用户仍能通过 FR-5.3/FR-5.4 的建议日均时长与「计划风险」文案（`goal_detail_page.dart:333-360`）知道该调整，再手动拖拽。
- **「已写好但不发布 / 先留着」这个选项的评估**：**不建议**以「留在工作区/同分支」的方式保留。理由有三：(1) 它与 schema v18 纠缠，若 v18 列随 v1.19 发布而 UI 不发布，就变成纯死 schema（最坏组合）；(2) 同一批文件正被并行的 v2.0 撞色重构改写（`calendar_view.dart`、`today_page.dart`、`task_tile.dart` 在工作区各有 1190/1238/419 行 diff），留而不发必然产生冲突与长期 rebase；(3) 工作区已有 4 个 `.orig` 残留（`plan_draft_dialog.dart.orig` 1069 行、`planning_service.dart.orig`、`planning_repository.dart.orig`、`plan_draft_widget_test.dart.orig`），说明它对工作区卫生已经在产生成本。**可行做法**是整体抽到独立分支/补丁文件，工作区回到只含 v1.19 必要改动的状态；项目在 v1.8.0 有同类先例（未提交的 AI 工作区改动全量回退，`CHANGELOG.md:525`）。

### A2 schema v18 `tasks.schedule_locked` —— 建议移除

- **删掉它用户会失去什么**：失去「把某条任务固定住、不让重排移动它」的开关。因为 A1 若不同时发布，该开关本身就无用——它唯一的作用是给 `PlanningService` 提供持久保护（`planning_service.dart:117-123, 732`）。
- **核心闭环是否还成立**：完全成立。锁定不是任何 FR 的要求，FR-5.5 只要求「系统只提出建议」。
- **删除代价与风险（本报告最高的一项）**：要回退 `schemaVersion` 18→17（`database.dart:154`）、删 `from17To18` 迁移块（`:395-405`）、删生成的 `task_tile` 锁定入口、`task_repository.setScheduleLocked`（`:767-778`）与备份字段（`backup_codec.dart:62-63, 200-202`）。关键风险是 `backup_service.dart:194-199` 的守卫——**由 v18 应用写出的备份不能被 schema 17 的应用恢复**，所以「先发布再移除」会留下无法恢复的备份；而**现在移除（v1.19 尚未发布、无 v18 备份流入用户手中）代价接近零**。项目已有降级清理的成熟先例可复用（`database.dart:49-90` 的 `downgradeCleanup`，v1.8.0 AI / v1.15 WebDAV 均走此路径）。
- **置信度**：高。证据全部是 schema/迁移/备份的硬事实，无需推测使用频率。

### A3 年视图 —— 建议移除

- **删掉它用户会失去什么**：失去「一眼看全年哪几个月完成得多」。这不是排程信息，而是**回看型进度信息**，与进度页热力图（FR-7.2 P0，`requirements.md:201`）职责重叠；`calendar_view.dart:194-199` 用的是 `StatisticsService.completedCountsByMonth`（按 `completedAt` 归月），口径注释也自陈「与进度页热力图一致」。
- **核心闭环是否还成立**：成立。FR-3.4 只要求日历显示「每日任务数、完成数和预估总时长」，月/周视图已完整覆盖；年视图连未来的任务负载都不显示（`gridAggregate = const {}`，`:200`），对「我打算做什么」零贡献。
- **删除代价**：`_YearGrid` 161 行 + 枚举分支 + `tasksByYearProvider` + `calendar_views_widget_test.dart`（332 行/6 项，含年视图用例）。不触 DB、不触备份、不触公开 API。设计稿本身留了退路（`plan-calendar-views-design.md:57`「进度页已有 26 周热力图……避免重复」）。
- **置信度**：中高。「年视图算不算重复」含一点产品判断，但与 §7 信息架构的分工（`:249-255`）方向一致。

### A4 四个重排范围 + 三×三类失败原因 —— 建议简化或合并

- **删掉它用户会失去什么**：失去「只动超载日」「只动某个目标」「动所有活跃目标」的粒度选择，退化为单一「均匀重排未来未完成任务」。
- **核心闭环是否还成立**：成立。§5.3 原文只有一种语义（「均匀重排未完成任务」），4 档范围是实现发明；`planning_service.dart:261-279` 的 `_applyScope` 只是过滤，`unscheduledOnly` 还需额外一轮「先算超载日再收窄」（`:285-295`）。
- **成本**：范围枚举 13 行、范围 UI 约 60 行、`PlanSkipReason` 2 档 + `PlanUnscheduledReason` 3 档（`:671-690`）+ `_buildNotes` 6 组文案（`:492-574`）+ 预览侧「未安排区/跳过区」两个组件（`plan_draft_dialog.dart:955-1134`，约 180 行）。这些都是为「多范围 × 多失败态」的组合矩阵付的维护费，测试 60 项里相当比例在锁这 3×3 文案。
- **建议**：若 A1 决定保留并发布，先只上「仅安排未排期任务」一档（最小扰动、最易解释），把其余三档与课程扣减一起后置。
- **置信度**：中高（基于代码结构与 PRD 文本；「4 档是否都有人用」无法用现有证据证明，故不写死为事实）。

### A5 课程占用扣减每日容量 —— 建议简化或合并

- **删掉它用户会失去什么**：重排时不再避开上课时段，可能把任务排到有课的那天（但仍遵守每日可用时长）。
- **核心闭环是否还成立**：成立，且更一致。FR-5.2 定义的负载口径只有一条：「当日未完成任务预估时长之和」（`:169`），`LoadService`（`lib/services/load_service.dart:39-166`，180 行）是它的 P0 实现；`PlanningService` 另起一套 `_DayLedger`（195 行，`:1108-1302`）并叠加课程分钟，等于同一概念两套账。
- **与 PRD 的张力**：FR-10.6 明写「课程为外部给定的固定作息：不参与任务负载与完成度统计」（`:234`），§7 也强调「课表与计划互补而不重叠」（`:255`）。把课表折进计划容量属于解释空间内的扩权，至少需要用户拍板（见 §4）。
- **删除代价**：无 DB 代价，只需去掉 `PlanningRequest.courses/semesterStartDate` 与 `planning_repository.dart:116-146` 的换算；`ClassPeriods`/教学周换算本身仍被课表页使用，不受影响。
- **置信度**：中（「不参与任务负载」是否覆盖「不参与排程容量」有解释余地，我不把它写成事实）。

### A6 任务 JSON 批量导入 —— 建议简化或合并

- **删掉它用户会失去什么**：失去「往已有目标灌一批 JSON 任务」的通道（含「替换/合并」模式）。但同一份数据仍有两条路：手写「批量添加」（`batch_task_form_dialog.dart`，437 行）与 A7「导入完整计划」。
- **核心闭环是否还成立**：成立，导入不是任何闭环环节；PRD §4.2 任务行只有 P1「批量操作」（`:76`），而 `task_import` 与课表的 `.ics`/JSON 导入（FR-10.4，唯一被 PRD 点名的导入）不是一回事。
- **重复的具体形态**：`plan_import_parser.dart:4` 直接 `import '../../tasks/domain/task_import_parser.dart' show ImportIssue`，说明两者共用校验词汇却各自维护一套解析与预览（`plan_import_dialog.dart:48` 注释也自陈「与 TaskImportDialog 同构」）。两个对话框 516 + 413 行、两个 parser 761 + 309 行，是同一需求的同构实现。
- **建议**：二选一——把 `task_import` 收敛为 A7 的一个「导入到已有目标」模式，或明确保留 `task_import` 而把 A7 的 JSON 分支降级。不建议两个都留在发布面上。
- **置信度**：中（重叠是事实；「哪个该留下」取决于用户实际拿到的是哪种 JSON，需用户拍板）。

### A7 完整计划导入 —— 可留（低成本观察）

- **删掉它用户会失去什么**：失去把一份已有 JSON 计划（目标 + 里程碑 + 科目 + 任务 + 每天例行）一次性落库的能力，且这是**用户实际使用过的路径**：`CHANGELOG.md:469` 记录了「导入用户实际 JSON」的端到端回归测试（`plan_import_widget_test.dart`，379 行/8 项），`:455-463` 还专门为它补了预估时长。
- **核心闭环是否还成立**：成立（导入是加速器不是环节）。但它是「首次使用」（§5.1，`:93-99`）的捷径，删掉的体验损失大于 A6。
- **为什么不判镀金**：它不在 PRD 里，但 PRD 也没禁止；有真实入口（`goal_list_page.dart:64`）、完整可达路径、事务纪律（`plan_import_repository.dart:54` 单事务）与使用证据。按奥卡姆剃刀它属于「可留但要观察」，不建议本轮动。
- **置信度**：中（使用频率只有 1 条变更日志证据，非量化数据）。

### A8 `.ics` 导出 —— 可留（低成本观察）

- **删掉它用户会失去什么**：失去把计划推送到 Google 日历 / Outlook / 手机日历的单向通路（`calendar_view.dart:790-794` 一个图标按钮，含可读失败提示 `:95-98`）。
- **核心闭环是否还成立**：成立；导出不参与任何闭环，PRD §4.2 课表行只要求**导入**（`:78`）。
- **成本**：导出侧约 310 行（builder 79 + service 71 + file picker 41 + codec 的 serialize/折行/转义约 160 行，`ics_codec.dart:410-585`），无新依赖（`file_selector` 已在 `pubspec.yaml:46`）。
- **存疑点**：`ics_export_builder.dart:20-22` 为任务生成了稳定 UID，但 `ics_plan_parser.dart:57-87` 导入时不按 UID 归并，而是新建目标 + 追加任务；因此「导出 → 再导入」会把同一批任务复制一份（UID 只对第三方日历有意义）。若判定为「假往返」，A8 的性价比会下降——列入 §4 拍板。
- **置信度**：中。

### A9 `IcsCodec` 不是重复实现 —— 必留（纠正任务书假设）

- 任务书假设「两套 ICS 解析（`ics_plan_parser` 与 `ics_codec`）」是重复。**代码不支持这个假设**：`ics_codec.dart:84-585` 是唯一的底层编解码器，`ics_plan_parser.dart:24, 30, 43` 与 `timetable_import_parser.dart:22, 107, 131` 都通过构造函数注入并调用 `codec.parse(...)`，两者只是「通用事件 → 各自领域对象」的适配层（133 行 / 711 行，其中后者大部分是 JSON 与节次换算）。
- **删掉它会怎样**：会产生三份各自的 RFC 5545 折行/转义/日期解析实现，是复杂度增加而非减少。
- **置信度**：高。

### A10 「隐藏已完成」开关 —— 可留（低成本观察）

- **删掉它用户会失去什么**：月视图里已勾选任务仍占位显示（`calendar_view.dart:166-170` 只影响聚合与展示）。属纯筛选偏好。
- **核心闭环是否还成立**：成立，且 FR-3.6「为历史日期补录/查看」并不要求隐藏。
- **成本**：约 26 行的 chip + 1 个 `bool` 状态；设计稿已把它标为「可选，若首版范围紧张可裁剪」（`plan-calendar-views-design.md:169`）。**不建议现在动**——它可见、可达、零风险，是典型的「留着不贵」；如果本轮要压缩 UI 选项数量，它是 A3 之后第 4 顺位。
- **置信度**：中高。

### A11 今天页「重新安排」按钮 —— 建议简化或合并

- **删掉它用户会失去什么**：今天页少一次点击。因为该按钮的实现是 `onPressed: () => context.go('/plan')`（`today_page.dart:396`），**它不打开重排对话框**，只跳到计划页，用户还要在计划页再点一次同名按钮（`calendar_view.dart:784-789`）。
- **核心闭环是否还成立**：成立。§5.2 第 4 条确实要求次日集中提示「延期、重新安排或保留原日期」（`:106`），但该提示由 `_UnfinishedBanner`（`today_page.dart:868-976`）承担，与这个按钮无因果。
- **判定理由**：标签（「重新安排」+ `auto_fix_high` 图标）承诺一个动作，实际是导航，属误导性入口 + 与计划页入口重复。二选一：删除，或改为直接 `PlanDraftDialog.show(context)`（若 A1 保留）。
- **置信度**：中高（实现是硬事实；「误导」是设计判断）。

### A12 5 秒批量撤销 FAB —— 可留（低成本观察）

- **删掉它用户会失去什么**：失去误勾选过期任务后的整批撤回；届时 `TaskCompletionController.finalize`（`task_completion_controller.dart:62-85`）会退化为即时写库。
- **核心闭环是否还成立**：成立（完成路径本就更短）。但 FR-3.7「必须由用户确认，不自动改变原计划」（`:149`）与这个「勾选后 5 秒内可撤回」是同一设计意图的两次实现，撤销窗口算是给该条款加了保险。
- **成本与观察点**：控制器 131 行 + FAB 约 107 行 + `TaskTile` 三处接线，零 DB 代价。**触发面比看起来窄**：`enableCompleteUndo` 只在过期任务区为 true（`today_page.dart:1064`），今日任务区即时写库（`:458-461` 注释）。因此它的真实出现频率取决于「昨日未完成任务」的数量——建议按实际观测决定去留，不急于删。
- **置信度**：中。

### A13 月/周网格 + 拖拽 + 负载条 + 完成徽标 —— 必留

- **删掉它用户会失去什么**：整个日历与改期能力，即 FR-3.2/3.4/3.5 与 FR-5.1 的 P0 验收项（`requirements.md:144-147, 168`）。`calendar_view.dart:514-532` 的 `_handleTaskDropped` 还实现了「已完成不可拖 + 失败保持原日期 + 明确提示」的 P0 细节。
- **核心闭环是否还成立**：不成立——「安排任务 → 调整计划」直接断链。
- **置信度**：高。

### A14 三视图切换器与周导航 —— 可留（低成本观察）

- **删掉它用户会失去什么**：失去按周聚焦的窗口（`calendar_view.dart:1340-1568` 的 `_WeekGrid`）。
- **核心闭环是否还成立**：成立（月视图足够满足 FR-3.4）。
- **为什么不判镀金**：周视图与月视图**同构复用**同一套单元格/聚合并共享 `LoadService.calendarAggregate`（`:184-188`），增量成本远小于新建一套视图；PRD 也未禁止。若 A3 移除年视图，切换器降为「周/月」两项即可，无需一并删除。
- **置信度**：中。

## 3 明确不建议动的部分

1. **A13 的 P0 主干**：`_MonthGrid` / `_WeekGrid` / `_DayPanel` / 拖拽改期 / `_DayLoadBar` / `_CompletionBadge` / `_TaskPills`——逐项对应 FR-3.2、FR-3.4、FR-3.5、FR-5.1，删任何一项都会打破 P0 验收（`docs/checklists.md:64, 268`）。
2. **`lib/services/load_service.dart`（180 行）**：FR-5.2/5.3/5.4/3.5 的唯一口径实现，是「每日负载提示」的 P0 基础，且被今天页、日历、目标详情共用。
3. **`IcsCodec` 的单实现结构与三处适配层（A9）**：这不是重复，拆分才是增加复杂度。
4. **`plan_page.dart`（22 行）**：纯壳，删它没有收益。
5. **`plan_file_picker.dart`（70 行）**：`CHANGELOG.md:42` 表明它与课表导入共用同一文件选择器，是**减少**重复的基础设施，不是镀金。
6. **A7 完整计划导入**：有真实使用证据与事务纪律，本轮不列为裁剪对象（只列为「观察」）。
7. **工作区内与本报告无关的 v1.19 改动**：本报告只给清单，不动任何代码，也不对并行的 v2.0 撞色重构改动作出取舍（那由 `audit-visual` 覆盖）。

## 4 存疑项（需要用户拍板）

1. **A1 智能重排的去留（最高优先）**
   - 选项甲（推荐）：**不随 v1.19 发布，抽到独立分支**。代价：v1.19 需要把 schema 回退到 v17、摘掉重排入口，今天/目标页各少一个按钮；收益：v1.19 只承载撞色重构，schema/备份回到 v17 单线。若日后要做，按 A4 只上「仅安排未排期任务」单档、不引入持久锁定列。
   - 选项乙：**完整发布 v1.19**。代价：承担 2.9k 行 + 60 项测试的长期维护、schema v18 与 v18 备份不可回退（`backup_service.dart:194`）、以及 P1「缺少用户验证时不同时全量启动」的 PRD 风险（`:385`）。收益：用户获得批量摊平能力。
   - 需要用户回答的**一个事实问题**：你（或目标用户）每周实际会点几次「重新安排」？现有仓库没有任何使用数据可支撑这个判断，我不把推测写成结论。

2. **A5 课表是否应折进重排容量**
   - 选项甲：去掉课程扣减，重排与 `LoadService` 口径完全统一（FR-5.2 单一口径）。代价：可能把任务排到有课的日子。
   - 选项乙：保留课程扣减，同时在 PRD 里补一条「排程容量 = 每日可用时长 − 课程占用」，显式认可课表参与排程。代价：计划模块永久依赖课表作息与学期基准（`planning_repository.dart:116-146`），并需回答 FR-10.6「不参与任务负载」（`:234`）的边界。

3. **A8 `.ics` 导出是否算「假往返」**
   - 选项甲：保留导出，接受单向推送（UID 只服务第三方日历）。代价：约 310 行长期存续。
   - 选项乙：作为「日历互通」的一部分补齐导入侧 UID 归并，使导出→导入幂等。代价：新增一套 UID ↔ 任务 ID 映射（很可能又要一个 schema 列），与本报告的裁剪方向相反——**不建议**，除非用户明确需要双向往返。

4. **A10 / A12 的观察指标缺失**
   - 两者都「留着不贵、删了也不致命」，但判断真实频率所需的既有证据（遥测/日志）为零。若本轮必须继续压缩 UI 选项，建议顺序为：A3 年视图 → A11 今天页按钮 → A10 隐藏已完成 → A12 撤销 FAB。

5. **A6 与 A7 的合并方向**
   - 选项甲：把「JSON 导入任务」并入完整计划导入（保留一个导入对话框）。
   - 选项乙：保留任务导入、把完整计划导入的 JSON 分支去掉（保留 `.ics` 分支）。
   - 拍板依据是「用户手上到底是哪种 JSON」——`CHANGELOG.md:469` 只证明了完整计划 JSON 被用过，任务导入（`:930-931`）没有同类证据。

6. **范围外但相邻的一处（供 Lead 转 `audit-shell`）**：`lib/features/settings/presentation/shortcuts_page.dart:6` 自述「快捷键页占位（P1 功能，后续迭代提供）」，属「占位页 = 死入口」形态，不在本次 A 范围，未纳入上表。
