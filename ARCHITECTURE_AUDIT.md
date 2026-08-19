# TimeCalc Flutter Windows — 架构与可测试性专项审查报告

审查日期：2026-08-16
审查范围：`lib/` 全部 111 文件（约 2.5 万行，含生成代码；手写约 2.5 万行）+ `test/`（59 个非生成测试文件 + 15 个 generated_migrations）
基线确认：`dart analyze` 0 问题；`flutter test` 557/557 通过。
排除项：`database.g.dart`、`ui-template/`。

> 说明：lib 实测 111 个 `.dart` 文件、约 2.54 万行手写代码；其中 `core/database/migration.dart` 与 `database.g.dart` 是 **drift_dev 生成代码**。项目曾交付 WebDAV 整库同步（v1.15 移除）与 AI 草稿排程（已移除），两功能移除后仅剩 schema 降级清理代码保留（`database.dart` 的 `downgradeCleanup`，属功能性迁移代码），本报告不含已移除功能。

---

## 一、整体架构评估

### 1.1 依赖关系图（文字版）

```
┌─────────────────────────────────────────────────────────────┐
│ main.dart（启动接线：开库→桌面控制器→备份调度→容器→runApp）      │
└───────────────┬─────────────────────────────────────────────┘
                │ ProviderContainer overrides
┌───────────────▼─────────────────────────────────────────────┐
│ core（无向上依赖，仅被各层引用）                                 │
│  ├─ database/    tables.dart ← database.dart ← migration.dart│
│  │               database.g.dart（生成）                      │
│  ├─ providers/   clockProvider · app_refresh(invalidateAll)  │
│  ├─ router/      app_router.dart（GoRouter + Shell + 午夜定时）│
│  ├─ desktop/     desktop_controller · window_state/restore   │
│  ├─ errors/      app_guard(runDbAction) · diagnostics · 错误屏 │
│  ├─ theme/ · utils/date_text.dart · app_version.dart          │
└───────────────┬─────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────┐
│ services/（纯 Dart，不依赖 DB/UI，单测充分）                    │
│  recurrence · countdown · defer · load · statistics · 工具    │
└───────────────┬─────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────┐
│ features/<feature>/{domain,data,presentation}                 │
│  data 层仓储依赖 core/database + 自身 domain + services        │
│  presentation 层经 provider watch/read 仓储，经 runDbAction 写  │
└─────────────────────────────────────────────────────────────┘
```

**跨 feature 依赖（data/domain 层，均为单向、无环）：**

```
backup ──────► settings（data：AutoBackupService 读配置）
plan_import ─► tasks（domain：recurrence_rule/registry）
```

**跨 feature 依赖（presentation 层，单向组合，无环）：**
`today → goals·tasks·settings`、`plan/calendar_view → goals·tasks·settings`、`progress → goals·tasks·settings`、`goals → tasks·settings`、`tasks/task_tile → goals·settings`、`settings → backup·tasks`。均为页面级组合（首页/日历/进度聚合多域数据），属正常 feature 化布局，不构成环。

### 1.2 分层结论

- **分层清晰、依赖方向正确**。`core` 零向上依赖；`services` 层纯 Dart、无 Flutter/DB 依赖，是可单测的干净 domain（这是本项目最强的架构资产）；`features` 内 domain/data/presentation 分层一致；presentation 不直接摸数据库（**未发现** presentation 引用 `AppDatabase`/`databaseProvider` 的实例，仅 import 数据类模型），全部写入经 repository provider + `runDbAction` 守卫。
- **无环依赖**。跨 feature 依赖单向，data 层无反向。
- **事务纪律好**。所有跨表写（级联删除、批量、替换导入、备份恢复）都在单事务内，失败回滚，注释与测试互为印证。
- **状态刷新收敛良好**。`invalidateAppData`/`invalidateAllAppData`（app_refresh.dart）已收敛历史 7 份逐字重复副本，并统一补上周/年视图；`ref.listen`（shell 订阅 3 个重数据源）避免根壳重建；`clockProvider` 已覆盖 UI 层、数据层仓储与派生 provider。
- **测试纪律好**。557 个测试按 service/repository/presentation 分层，widget 测试全走真实 app + 固定时钟（clockProvider override）+ 内存库，并有 `performance/` 目录做渲染性能回归。

### 1.3 总体评价（先给结论）

> 这是一个**分层规范、可测性高于同类个人项目平均水平**的代码库：domain/services 纯逻辑干净、依赖方向正确、无环、事务与刷新机制设计用心。可测性短板经本次审查修复后已大幅收敛（数据层时钟已可注入），剩余主要是**少数失败分支无测试**（合并恢复回滚、>500 分批路径）与**几个 presentation 子页无 widget 测试**。不存在「上帝类」——最大的三个文件（progress 1791 行、calendar 1506 行、today 926 行）虽长，但均已拆成 9–15 个私有组件类，是「长文件」而非「单类上帝」。被点名 2486 行的 `migration.dart` 是 drift 生成代码，非审查对象。
> 总体架构维度评分：**分层 9/10 · 依赖方向 9/10 · 可测性 8.5/10 · 测试覆盖 8.5/10 · 职责粒度 7/10（长文件/跨 feature 组合）**。

---

## 二、按严重级别列发现

### 🔴 高（真实可测性/健壮性缺陷）

**H1. 数据层时间不可注入：repository 全用裸 `DateTime.now()` —— 本次已修复 ✅**
- 原状（审查时）：`clockProvider` 只接了 UI 层与 3 个派生 provider，**所有写库路径的 `createdAt/updatedAt/completedAt/archivedAt` 时间戳直接用 `DateTime.now()`**，无法在测试中固定写入的精确时间。
- **本次修复（2026-08-16）**：7 个 repository（goal/milestone/subject/settings/checklist_item/recurrence/task）+ `BackupCodec` 构造函数增加可注入 `DateTime Function()? clock`（默认 `DateTime.now`），provider 接 `ref.watch(clockProvider)`；替换内部所有 `DateTime.now()`。现在可对「完成任务并断言 completedAt 具体值」「跨午夜写库」「completedAt 归日」等做精确时间断言。
- 剩余建议：`plan_import_repository.dart` 若仍用裸时钟可一并跟进（改动极小）。

### 🟠 中（健壮性/可测性缺陷，或显著维护风险）

**M1. 跨午夜刷新 `_armMidnightTimer` 用裸 `DateTime.now()` 且无测试**
- 文件:行号：`app_router.dart:236–246`。
- 问题描述：桌面托盘常驻跨天是真实场景，但该 Timer 用 `DateTime.now()` 计算到午夜的时长，无法注入，且无测试。若时钟被 override（widget 测试固定时钟），该定时器会按真实时间触发——测试中不可控。
- 建议：将「下个本地午夜 +1s」的时长计算抽为纯函数（入参 now，出参 Duration）单测；timer 逻辑接受可注入 now。至少补纯函数测试（跨年午夜、闰年 2/29）。

**M2. presentation 残留的裸时钟写库 —— 本次已修复 ✅**
- 原状（审查时）：`goal_list_page.dart:595–600`（`repo.update(... completedAt: DateTime.now().toUtc())`）绕过 clockProvider；`goal_form_dialog.dart:62`、`milestone_form_dialog.dart:75`、`recurrence_task_dialog.dart:72` 对话框初始日期用裸 `DateTime.now()`。
- **本次修复（2026-08-16）**：`goal_list_page`「标记完成」改为 `ref.read(clockProvider)().toUtc()`；各对话框初始日期统一从 `clockProvider` 取。

**M3. 超长 presentation 文件（职责混杂，非单类上帝）**
- 文件:行号：`progress_page.dart`（1791 行，15 个类 + **5 个 provider 定义在文件内**：`progressTasksProvider` 等，71–176 行）；`calendar_view.dart`（1506 行，14 个类）；`today_page.dart`（926 行，9 个类）。
- 问题描述：已拆分为多个私有 widget，**不是「上帝类」**，但单文件超过 900 行带来：① provider 定义（数据派生）与 widget 混放，违背「provider 在 data 层」的自身约定，数据门逻辑散落在页面文件；② 私有组件无法独立测试（只能整页导航测）；③ 代码导航成本高。`migration.dart` 2486 行是 **drift_dev 生成代码（文件头 `GENERATED BY drift_dev, DO NOT MODIFY`）**，不属手写职责问题。
- 建议：把 progress_page 内 5 个 provider 抽到 `features/progress/data/progress_providers.dart`（calendar 的 `_viewAsync`/聚合可酌情下移）；长文件按「区块组件」拆目录为后续独立 widget 测试铺路。属可维护性/风格，非功能缺陷。

**M4. `settings.get()` 惰性 seed 的并发竞态仅有注释承诺，无并发测试**
- 文件:行号：`settings_repository.dart:21–35`（`insertOrIgnore` 注释称并发安全）。
- 问题描述：设计正确（insertOrIgnore 保证只有一个写入成功），但无并发用例验证「并发首次调用不抛 UNIQUE 冲突、其余走读路径」。`_update` 内部又调 `get()`，两层嵌套语义未被测试。
- 建议：补 `Future.wait([...get()×N])` 并发首次调用用例。

**M5. 备份服务职责过载（669 行单类）**
- 文件:行号：`backup_service.dart`（exportBackup/restoreBackup/resetData/_merge/_overwrite/_unpack/安全副本/清扫 全部一个类）。
- 问题描述：文件 IO（zip 编解码）+ DB 事务 + 安全副本策略混合。可测性尚可（测试覆盖充分），但「安全副本清扫」「zip 打包」「恢复映射」彼此独立，任一演进都要改动同一类。
- 建议：`_mergeRestore`/`_overwriteRestore` 的 id 映射逻辑可抽纯函数；`exportSafetyCopy` 的清扫独立成 `SafetyCopyManager`。低优先级风格改进。

### 🟡 低（风格 / 观察项）

- **L1. 全局可变状态**：`main.dart:67` 全局 `ProviderContainer? _container`、`desktop_controller.dart` 静态 `scaffoldMessengerKey`。务实（跨树取 messenger/容器失效），但属全局可变，多实例/测试隔离下有隐患。可接受。
- **L2. widget 测试断言粒度**：测试全部经 `nav_helper` 走完整 app + `find.text` 断言，对文案/布局敏感、运行慢。风格偏好；配套已有数据层/服务层单测，风险可控。
- **L3. repository 层混入业务校验**：`task_repository.dart`（`ArgumentError` 防御 dateIntervalDays）、`recurrence_repository.dart`（规则校验）。校验应在调用方/domain，防御性校验留在仓库可接受但属混合。
- **L4. `Random(`/`Process.`/`dart:io` 业务散落**：全库**无 `Random(`、无 `Process.`**；`dart:io` 集中在 backup/desktop/errors（文件 IO 合理位置），presentation 仅 backup_page 有文件复制 IO（导出后拷到所选目录，合理）。结论：副作用隔离良好，无需处理。
- **L5. presentation 跨 feature 导入数量**：today_page/calendar_view 各 import 6–7 个跨 feature 模块。是首页聚合的正常代价；若在意可引入「feature 门面」或把共享卡片（TaskTile）下沉 shared。风格。

---

## 三、测试覆盖盲区清单

> 总体覆盖优秀：557 测试覆盖了 service 全量纯逻辑、repository 事务/级联/幂等、备份（含损坏/计数不符/字段类型损坏/运行时配置保留）、迁移（含半迁移幂等、迁移失败恢复、降级清理）、日历/今日/进度/目标 widget 全覆盖。以下是**明确盲区**：

| # | 盲区 | 现状 | 严重度 |
|---|------|------|--------|
| B1 | **合并恢复失败回滚** | 仅「覆盖恢复失败原库可用」1 个（backup_service_test）；`_mergeRestore` 失败回滚无测试 | 中 |
| B2 | **deferMany/deleteMany 超过 `kMaxInListSize=500` 的分批路径** | 测试只用 2 元素列表，`_chunkIds` 分批分支未触发 | 中 |
| B3 | **跨午夜刷新 `_armMidnightTimer`** | 无测试（见 M1） | 中 |
| B4 | **repository 写入时间戳精确值**（H1 的测试面） | 时钟注入已就绪，具体断言用例待补 | 中 |
| B5 | **settings.get 并发首次 seed**（见 M4） | 无并发用例 | 中 |
| B6 | **无 widget 测试的 presentation 页**：`CloseBehaviorPage`、`ResetDataPage`、`ShortcutsPage`（settings 子页） | 三个路由无任何导航测试（app_router_test 只测非法 id 重定向） | 低 |
| B7 | **`SubjectTaskPage` 深度交互** | 有 1 条进入用例，增删/归日联动未覆盖 | 低 |
| B8 | **年视图跨年/闰年网格** | 覆盖跨月周；跨年周（12 月末–1 月初）未明确覆盖 | 低 |
| B9 | **DST 分支实际不可触发** | `countdown_service_test` 标称 DST，但 CI/开发机为固定时区（无 DST），`_dayDiff` 的 UTC 归一化使代码本身安全，该用例是「名义覆盖」——真实 DST 切换日行为仍无验证 | 观察 |

补充：性能测试 3 个（navigation/calendar/goal_card）覆盖渲染回归；`today_page` 有 20+ 条 widget 用例，深度与广度俱佳。

---

## 四、可测试性改进建议（按投入产出排序）

1. **（已完成）Repository 层时钟注入** — 见 H1/M2。本次已为 7 个 repository + `BackupCodec` 接入 `clockProvider`，消除「数据层时间不可注入」这一最大可测性缺口。
2. **（中价值/小改动）`_armMidnightTimer` 纯函数化** — 见 M1，抽出「到下一个本地午夜 +1s 的 Duration」纯函数并单测（跨年/闰年）。
3. **（中价值/小改动）补 B1/B2/B5 三组边界测试**：合并恢复回滚、>500 分批路径、settings 并发 seed。均为既有基建上补用例，无重构。
4. **（维护性）provider 下沉** — 把 progress_page 内 5 个 provider 与 calendar 聚合逻辑移到对应 feature 的 `data/` 目录（见 M3）。
5. **（低）补 3 个无测试的 settings 子页 widget 测试** — CloseBehaviorPage / ResetDataPage / ShortcutsPage（见 B6）。ResetDataPage 有「重置 + 安全副本」的重要数据销毁路径，建议优先补。

---

## 五、结论

- **架构**：分层规范、依赖单向无环、domain/services 纯净、事务与刷新纪律优秀。无「上帝类」；被点名的 migration.dart 为生成代码。仅有的架构级注意力应放在**长 presentation 文件**（可维护性，见 M3）。
- **可测性**：优于同类项目。本次审查已修复数据层时钟不可注入（H1/M2），剩余缺口为少量失败分支无测试（B1/B2/B5）。
- **测试覆盖**：557 测试覆盖了主路径与大量错误/回滚/幂等分支，盲区集中在合并恢复回滚、>500 分批、跨午夜与 settings 子页，合计约 9 处，大多可用既有基建低成本补齐。
- 本报告未发现任何「真实架构缺陷级」问题；M1–M5 是健壮性/维护性风险，其余为风格。
