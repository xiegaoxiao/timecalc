# TimeCalc Flutter Windows — 架构与可测试性专项审查报告

审查日期：2026-08-16
审查范围：`lib/` 全部 106 文件（约 2.58 万行，含生成代码；手写约 2.33 万行）+ `test/`（61 个非生成测试文件 + 14 个 generated_migrations）
基线确认：`dart analyze` 0 问题；`flutter test` 603/603 通过。
排除项：`database.g.dart`、`ui-template/`。

> 说明：用户基线估计「lib/ 约 5 万行」偏高。实测 `find lib -name '*.dart' | grep -v database.g.dart | wc -l` ≈ 25,774 行，其中 `core/database/migration.dart`（2486 行）与 `database.g.dart` 是 **drift_dev 生成代码**，实际手写约 2.3 万行。这与「migration.dart 是上帝文件」的判断直接相关，见发现 F5。

---

## 一、整体架构评估

### 1.1 依赖关系图（文字版）

```
┌─────────────────────────────────────────────────────────────┐
│ main.dart（启动接线：开库→桌面控制器→同步/备份调度→容器→runApp）   │
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
sync ────────► backup（data：BackupService 导出/覆盖恢复）
sync ────────► settings（data：SettingsRepository/凭据）
backup ──────► settings（data：AutoBackupService 读配置）
plan_import ─► tasks（domain：recurrence_rule/registry）
```

**跨 feature 依赖（presentation 层，单向组合，无环）：**
`today → goals·tasks·settings`、`plan/calendar_view → goals·tasks·settings`、`progress → goals·tasks·settings`、`goals → tasks·settings`、`tasks/task_tile → goals·settings`、`settings → backup·sync·tasks`。均为页面级组合（首页/日历/进度聚合多域数据），属正常 feature 化布局，不构成环。

### 1.2 分层结论

- **分层清晰、依赖方向正确**。`core` 零向上依赖；`services` 层纯 Dart、无 Flutter/DB 依赖，是可单测的干净 domain（这是本项目最强的架构资产）；`features` 内 domain/data/presentation 分层一致；presentation 不直接摸数据库（**未发现** presentation 引用 `AppDatabase`/`databaseProvider` 的实例，仅 import 数据类模型），全部写入经 repository provider + `runDbAction` 守卫。
- **无环依赖**。跨 feature 依赖单向，data 层无反向。
- **事务纪律好**。所有跨表写（级联删除、批量、替换导入、备份恢复）都在单事务内，失败回滚，注释与测试互为印证。
- **状态刷新收敛良好**。`invalidateAppData`/`invalidateAllAppData`（app_refresh.dart）已收敛历史 7 份逐字重复副本；`ref.listen`（shell 订阅 3 个重数据源）避免根壳重建；`clockProvider` 覆盖 UI 层与若干派生 provider。
- **测试纪律好**。603 个测试按 service/repository/presentation 分层，widget 测试全走真实 app + 固定时钟（clockProvider override）+ 内存库，并有 `performance/` 目录做渲染性能回归。

### 1.3 总体评价（先给结论）

> 这是一个**分层规范、可测性高于同类个人项目平均水平**的代码库：domain/services 纯逻辑干净、依赖方向正确、无环、事务与刷新机制设计用心。主要可测性短板集中在**数据层时间不可注入**（repository 大量裸 `DateTime.now()`）、**少数失败分支无测试**（WebDAV 推送失败、合并恢复回滚、>500 分批路径）、以及**几个 presentation 子页无 widget 测试**。不存在「上帝类」——最大的三个文件（progress 1791 行、calendar 1506 行、today 926 行）虽长，但均已拆成 9–15 个私有组件类，是「长文件」而非「单类上帝」。被点名 2486 行的 `migration.dart` 是 drift 生成代码，非审查对象。
> 总体架构维度评分：**分层 9/10 · 依赖方向 9/10 · 可测性 8/10 · 测试覆盖 8.5/10 · 职责粒度 7/10（长文件/跨 feature 组合）**。

---

## 二、按严重级别列发现

### 🔴 高（真实可测性/健壮性缺陷）

**H1. 数据层时间不可注入：repository 全用裸 `DateTime.now()`**
- 文件:行号：`task_repository.dart:182,220,262,363,381,393–394,428,450,481,597`；`goal_repository.dart:39,62,101`；`milestone_repository.dart:39,68`；`subject_repository.dart:30,49,61,71`；`checklist_item_repository.dart:42,76,89,121,129`；`settings_repository.dart:25,137`；`plan_import_repository.dart:49`；`backup_codec.dart:112,135,155,190,228,280,301`；`webdav_sync_service.dart:166,397,404,439`。
- 问题描述：`clockProvider` 只接了 UI 层（today/calendar/progress/task_tile 等）和 3 个派生 provider（`completedTasksProvider`、`nextUpcomingMilestoneProvider`、`recurrence` 的 `today` 参数）。**所有写库路径的 `createdAt/updatedAt/completedAt/archivedAt` 时间戳直接用 `DateTime.now()`**。后果：无法在测试中固定 repository 写入的精确时间 → 「完成任务并断言 completedAt 具体值」「跨午夜写库」「completedAt 归日」等时间敏感断言只能靠相对断言，或干脆测不到。`RecurrenceRepository.create/generateDue/updateRule` 已提供 `today` 注入参数（好先例），其余 repository 未跟进。
- 建议：给 repository 构造函数加 `DateTime Function()? clock`（默认 `DateTime.now`），provider 里接 `ref.watch(clockProvider)`；替换内部所有 `DateTime.now()`。改动面 7 个 repository + 其 provider，收益是精确时间断言与跨天边界测试。这是**本次审查最高价值的小重构**。

**H2. WebDAV 推送失败分支无测试（含部分失败不一致状态）**
- 文件:行号：`webdav_sync_service.dart:427–469`（`_push` 的 `on Exception → '推送失败：$e'`，且先传快照再传 meta）；`test/features/sync/data/webdav_sync_service_test.dart`（无 PUT 500 / meta 500 用例）。
- 问题描述：同步测试已覆盖「拉取下载失败 500 后不残留抑制窗口」（392 行）、401/403 testConnection、meta 损坏拒推等，但**没有任何用例覆盖推送失败**。特别是「快照 PUT 成功、meta PUT 失败」的部分失败路径：远端留下新快照 + 旧 meta，本地 `lastPushedSeq` 不推进——下次同步按 meta 判新旧，可能把该不一致静默带过，且该分支无测试保护。
- 建议：补 3 个用例：① meta GET 正常但快照 PUT 500 → 返回 `pushed=false`、`error` 非空、`lastPushedSeq` 不变；② 快照 PUT 成功但 meta PUT 500 → 远端不一致状态断言（最好断言服务把该情况暴露为 error）；③ 推送失败后 `_hasLocalChanges` 不被误清（`_changeCount` 语义）。MockClient 基础设施已就绪，成本低。

### 🟠 中（健壮性/可测性缺陷，或显著维护风险）

**M1. 同步失败重试完全依赖 main.dart 的 `Timer.periodic(5min)` 接线，且无测试**
- 文件:行号：`main.dart:110–111`；`webdav_sync_service.dart`（`syncOnce` 无内建重试）。
- 问题描述：拉取/推送失败后没有退避重试，只能等下一个周期（5 分钟）或手动/下次启动。逻辑本身「尽力而为」可接受，但整个接线（启动拉取、周期复查、变更防抖推送、退出推送带 5s 超时）全部在不可测试的顶层 `main()` 里，无任何单测。`_invalidateDataProviders`（main.dart:126–143）与 `invalidateAllAppData`（app_refresh.dart:38–48）是**两份手工维护的 provider 清单**，注释称「对齐」但无测试保证一致——漏一个就是「拉取恢复后某页残留陈旧数据」类回归（注释里自己记载过此类事故）。
- 建议：把启动/周期接线抽成可构造的 `AppBootstrap` 类（注入 syncService/container），使 `syncOnce` 调度、退出推送超时、provider 清单一致性可单测；或至少补一个「两份清单集合相等」的断言测试。

**M2. 跨午夜刷新 `_armMidnightTimer` 用裸 `DateTime.now()` 且无测试**
- 文件:行号：`app_router.dart:236–246`。
- 问题描述：桌面托盘常驻跨天是真实场景（M4 曾为此加午夜定时器），但该 Timer 用 `DateTime.now()` 计算到午夜的时长，无法注入，且无测试。若时钟被 override（widget 测试固定时钟），该定时器会按真实时间触发——测试中不可控。
- 建议：将「下个本地午夜 +1s」的时长计算抽为纯函数（入参 now，出参 Duration）单测；timer 逻辑接受可注入 now。至少补纯函数测试（跨年午夜、闰年 2/29）。

**M3. presentation 残留的裸时钟写库：`goal_list_page.dart:598`**
- 文件:行号：`goal_list_page.dart:595–600`（`repo.update(... completedAt: DateTime.now().toUtc())`）；另有 `goal_form_dialog.dart:62`、`milestone_form_dialog.dart:75`、`recurrence_task_dialog.dart:72`（对话框初始日期用 `DateTime.now()`，应改用 `ref.read(clockProvider)()`）。
- 问题描述：`goal_list_page` 的「标记完成」直接把 `DateTime.now()` 塞进 repository 调用，绕过 clockProvider——widget 测试即使固定时钟也无法断言该目标 completedAt，且与 H1 同源。其余三处是初始日期，测试固定时钟时首帧日期可能与预期不符。
- 建议：`goal_list_page:598` 改为 `ref.read(clockProvider)().toUtc()`；对话框初始日期统一从 `clockProvider` 取。

**M4. 超长 presentation 文件（职责混杂，非单类上帝）**
- 文件:行号：`progress_page.dart`（1791 行，15 个类 + **5 个 provider 定义在文件内**：`progressTasksProvider` 等，71–176 行）；`calendar_view.dart`（1506 行，14 个类）；`today_page.dart`（926 行，9 个类）。
- 问题描述：已拆分为多个私有 widget，**不是「上帝类」**，但单文件超过 900 行带来：① provider 定义（数据派生）与 widget 混放，违背「provider 在 data 层」的自身约定，数据门逻辑散落在页面文件；② 私有组件无法独立测试（只能整页导航测）；③ 代码导航成本高。`migration.dart` 2486 行是 **drift_dev 生成代码（文件头 `GENERATED BY drift_dev, DO NOT MODIFY`）**，不属手写职责问题。
- 建议：把 progress_page 内 5 个 provider 抽到 `features/progress/data/progress_providers.dart`（calendar 的 `_viewAsync`/聚合可酌情下移）；长文件按「区块组件」拆目录为后续独立 widget 测试铺路。属可维护性/风格，非功能缺陷。

**M5. `settings.get()` 惰性 seed 的并发竞态仅有注释承诺，无并发测试**
- 文件:行号：`settings_repository.dart:21–35`（`insertOrIgnore` 注释称并发安全）。
- 问题描述：设计正确（insertOrIgnore 保证只有一个写入成功），但无并发用例验证「并发首次调用不抛 UNIQUE 冲突、其余走读路径」。`_update` 内部又调 `get()`（132–139 行），两层嵌套语义未被测试。
- 建议：补 `Future.wait([...get()×N])` 并发首次调用用例。

**M6. `sync → backup` 数据层耦合（用户点名项）**
- 文件:行号：`webdav_sync_service.dart:6–11`（import backup_service/manifest/credential_store/webdav_client）、`webdav_sync_service_provider.dart`。
- 问题描述：同步复用备份的 zip 快照格式与覆盖恢复全链路。**可接受**（快照即备份格式，代码复用合理、S0 无新增依赖），但语义上把「同步」与「备份格式」绑死：backup 格式/版本演进会直接破坏同步，两 feature 的 schema 守卫（appSchemaVersion）需要协同演进。非缺陷，属需要刻意管理的耦合。
- 建议：保持现状，但为 backup 的 `RestoreMode.overwrite` 保留「运行时配置不覆盖」语义加一条显式回归（已有 4 条 M8/M9/M10 回归测试，足够）。文档注明两 feature 需同版本演进。

**M7. WebDAV 抑制窗口用真实时钟，测试依赖时序**
- 文件:行号：`webdav_sync_service.dart:396–397`（`_suppressWatchUntil = DateTime.now()+15s`），`pushIfNeeded` 166 行。
- 问题描述：抑制窗口（防「拉取→回推」乒乓）用裸时钟；现有测试（392 行）靠 15s 窗口内完成执行规避。若改为可注入时钟，可测「窗口内 pushIfNeeded 被抑制 / 窗口外放行」两个明确分支（当前无窗口内被抑制的正向用例）。
- 建议：`WebDavSyncService` 构造注入 `DateTime Function() now`（默认 `DateTime.now`），补抑制窗口内/外两个用例。

**M8. 备份服务职责过载（669 行单类）**
- 文件:行号：`backup_service.dart`（exportBackup/restoreBackup/resetData/_merge/_overwrite/_unpack/安全副本/清扫 全部一个类）。
- 问题描述：文件 IO（zip 编解码）+ DB 事务 + 安全副本策略混合。可测性尚可（700 行测试覆盖充分），但「安全副本清扫」「zip 打包」「恢复映射」彼此独立，任一演进都要改动同一类。
- 建议：`_mergeRestore`/`_overwriteRestore` 的 id 映射逻辑可抽纯函数；`exportSafetyCopy` 的清扫独立成 `SafetyCopyManager`。低优先级风格改进。

### 🟡 低（风格 / 观察项）

- **L1. 全局可变状态**：`main.dart:122` 全局 `ProviderContainer? _container`、`desktop_controller.dart:214` 静态 `scaffoldMessengerKey`。务实（跨树取 messenger/容器失效），但属全局可变，多实例/测试隔离下有隐患。可接受。
- **L2. widget 测试断言粒度**：测试全部经 `nav_helper` 走完整 app + `find.text` 断言，对文案/布局敏感、运行慢。风格偏好；配套已有数据层/服务层单测，风险可控。
- **L3. repository 层混入业务校验**：`task_repository.dart:212–219`（`ArgumentError` 防御 dateIntervalDays）、`recurrence_repository.dart:61–68`（规则校验）。校验应在调用方/domain，防御性校验留在仓库可接受但属混合。
- **L4. `Random(`/`Process.`/`dart:io` 业务散落**：全库**无 `Random(`、无 `Process.`**；`dart:io` 集中在 backup/sync/desktop/errors（文件 IO 合理位置），presentation 仅 backup_page:431 有文件复制 IO（导出后拷到所选目录，合理）。结论：副作用隔离良好，无需处理。
- **L5. presentation 跨 feature 导入数量**：today_page/calendar_view 各 import 6–7 个跨 feature 模块。是首页聚合的正常代价；若在意可引入「feature 门面」或把共享卡片（TaskTile）下沉 shared。风格。

---

## 三、测试覆盖盲区清单

> 总体覆盖优秀：603 测试覆盖了 service 全量纯逻辑、repository 事务/级联/幂等、备份 24 个用例（含损坏/计数不符/字段类型损坏/运行时配置保留）、迁移 33 个用例（含半迁移幂等、迁移失败恢复、v14→v12 降级）、同步 16 个用例 + 2 个 loopback e2e、日历/今日/进度/目标 widget 全覆盖。以下是**明确盲区**：

| # | 盲区 | 现状 | 严重度 |
|---|------|------|--------|
| B1 | **WebDAV 推送失败**（PUT 500 / meta 500 / 部分失败快照成功 meta 失败） | 仅拉取下载失败 500 有测试 | 高 |
| B2 | **同步调度接线**（启动拉取/周期/退出推送超时/`_invalidateDataProviders` 清单一致性） | main() 顶层，无测试 | 高 |
| B3 | **合并恢复失败回滚** | 仅「覆盖恢复失败原库可用」1 个（backup_service_test:216）；`_mergeRestore` 失败回滚无测试 | 中 |
| B4 | **`buildEnabledTargets` 的 WebDAV 分支**（含密码缺失计入 `outIncomplete`） | `auto_backup_service_test` 只测 run() 的「仅本地目的地」；该函数零测试 | 中 |
| B5 | **deferMany/deleteMany 超过 `kMaxInListSize=500` 的分批路径** | 测试只用 2 元素列表，`_chunkIds` 分批分支未触发 | 中 |
| B6 | **跨午夜刷新 `_armMidnightTimer`** | 无测试（见 M2） | 中 |
| B7 | **repository 写入时间戳精确值**（H1 的测试面） | 无（不可注入所致） | 中 |
| B8 | **settings.get 并发首次 seed**（见 M5） | 无并发用例 | 中 |
| B9 | **pushIfNeeded 抑制窗口内被抑制的正向用例**（见 M7） | 只有「失败后不残留抑制窗口」的反向用例 | 低 |
| B10 | **无 widget 测试的 presentation 页**：`CloseBehaviorPage`、`ResetDataPage`、`ShortcutsPage`（settings 子页） | 三个路由无任何导航测试（app_router_test 只测非法 id 重定向） | 低 |
| B11 | **`SubjectTaskPage` 深度交互** | 有 1 条进入用例（task_crud_widget_test:513），增删/归日联动未覆盖 | 低 |
| B12 | **年视图跨年/闰年网格** | 覆盖跨月周（calendar_views_widget_test:70）；跨年周（12 月末–1 月初）未明确覆盖 | 低 |
| B13 | **DST 分支实际不可触发** | `countdown_service_test:125` 标称 DST，但 CI/开发机为固定时区（无 DST），`_dayDiff` 的 UTC 归一化使代码本身安全，该用例是「名义覆盖」——真实 DST 切换日行为仍无验证 | 观察 |

补充：性能测试 3 个（navigation/calendar/goal_card）覆盖渲染回归；`today_page` 有 22 条 widget 用例，深度与广度俱佳。

---

## 四、可测试性改进建议（按投入产出排序）

1. **（高价值/小改动）Repository 层时钟注入** — 见 H1。为 7 个 repository 加 `clock` 参数并由 provider 接 `clockProvider`；这是把「UI 层已建立的可注入时钟约定」延伸到数据层的唯一缺口。
2. **（高价值/小改动）补 WebDAV 推送失败 3 用例** — 见 H2，MockClient 基建已就绪。
3. **（中价值/中改动）抽 `AppBootstrap` 类** — 见 M1，把 main() 的同步接线与 provider 清单收敛为可测对象，并补「`invalidateAllAppData` ≡ `_invalidateDataProviders`」一致性断言。
4. **（中价值/小改动）`_armMidnightTimer` 纯函数化** — 见 M2/M6，抽出「到下一个本地午夜 +1s 的 Duration」纯函数并单测（跨年/闰年）。
5. **（中价值/小改动）`goal_list_page:598` 与对话框初始日期改走 clockProvider** — 见 M3。
6. **（中价值/小改动）补 B3/B4/B5/B8 四组边界测试**：合并恢复回滚、`buildEnabledTargets` WebDAV 分支、>500 分批路径、settings 并发 seed。均为既有基建上补用例，无重构。
7. **（维护性）provider 下沉** — 把 progress_page 内 5 个 provider 与 calendar 聚合逻辑移到对应 feature 的 `data/` 目录（见 M4）。
8. **（低）`WebDavSyncService`/`WebDavClient` 时钟与超时参数化** — 补抑制窗口正/反向用例（见 M7）。
9. **（低）补 3 个无测试的 settings 子页 widget 测试** — CloseBehaviorPage / ResetDataPage / ShortcutsPage（见 B10）。ResetDataPage 有「重置 + 安全副本」的重要数据销毁路径，建议优先补。

---

## 五、结论

- **架构**：分层规范、依赖单向无环、domain/services 纯净、事务与刷新纪律优秀。无「上帝类」；被点名的 migration.dart 为生成代码。仅有的架构级注意力应放在**长 presentation 文件**（可维护性）与 **sync→backup 格式耦合**（需刻意协同演进），二者均非缺陷。
- **可测性**：优于同类项目。核心缺口是**数据层时钟不可注入**（H1，一处小重构即可消除）与**少数失败分支无测试**（H2/B1–B5）。
- **测试覆盖**：603 测试覆盖了主路径与大量错误/回滚/幂等分支，盲区集中在 WebDAV 推送失败、合并恢复回滚、>500 分批、跨午夜与 settings 子页，合计约 12 处，大多可用既有基建低成本补齐。
- 本报告未发现任何「真实架构缺陷级」问题；H1–H2 是可测性缺口，M1–M8 是健壮性/维护性风险，其余为风格。
