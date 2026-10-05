# C：进度页图表 + 视觉 / 动画 / 主题

> 审计范围（task-3）：`lib/features/progress/presentation/progress_page.dart`、`lib/services/statistics_service.dart`、
> `lib/shared/widgets/**`、`lib/core/theme/**`、`lib/core/providers/motion_provider.dart`、
> `pubspec.yaml` 中 fl_chart / flutter_animate / skeletonizer / confetti 四个纯表现层依赖。
>
> 审计方式：**纯静态只读**（未运行 `flutter test` / `flutter build` / `flutter pub get`，未改动任何仓库文件）。
> 所有结论均带 `file:line` 证据；凡涉及运行时行为（性能、对比度实际观感、测试通过与否）无法验证者一律降级置信度。
>
> 行数口径：本报告 LOC 为 read 工具返回的**实际总行数**（含空行与注释）。与任务描述中的概览数字有出入，以本表为准：
> `progress_page.dart` **1876** 行（描述称 1779）、`statistics_service.dart` **369** 行（描述称 333）、
> `lib/core/theme/**` 4 文件共 **1359** 行（描述称 1247）、`lib/shared/widgets/**` 16 文件共 **2867** 行（描述称 2731）。
> 全仓 `lib` 合计 47560 行。

---

## 0 结论摘要

1. **PRD 硬判定的唯一"镀金"是 P2 的甘特图**：`_GanttSection` + `_BarChart` + `progressGanttProvider` + `goalGanttData/ganttWeekStarts` 共约 **516 行生产代码 + 约 13 个测试用例**，而 `docs/requirements.md:205` 原文「甘特图、年份热力图、PNG/PDF 报告导出列为 P2」——已实现的"任务耗时图"就是该 P2 项改了个名字（`progress_page.dart:1507` 类名仍叫 `_GanttSection`）。
2. **第二个高价值发现：燃尽趋势（P1）实际画的是"假曲线"**——`statistics_service.dart:318-323` 中 `remaining` 在数学上恒等于 `ideal`，即整条"趋势"只是由「当前剩余 + 截止日」两个已显示数字推出的直线，不含任何历史实际数据；`BurndownPoint.ideal` 字段因此冗余。
3. **纯装饰 / 零信息机制**：confetti 彩纸屑（87 行 + 1 依赖，`celebration_overlay.dart`）、`ClashHero` 的双 Orb 光斑（约 50 行纯装饰，`clash_hero.dart:69-119`）、`flutter_animate` 全仓仅 1 处使用（`today_page.dart:1336`，与 `progress_page.dart:912` 的 `TweenAnimationBuilder` 重复实现同一效果）、`HoverableCard.hoverShadowOpacity` 参数**声明后从未被读取**（`hoverable_card.dart:26,48` vs `:78-89`）。
4. **重复实现（奥卡姆第 5 条）实证**：`SectionHeader` 与 `ClashSectionHeader`、`ChartEmptyState` 与 `ClashEmptyState` 是两套同功能组件；`ClashTones` 与 `app_theme.dart` 有 **5 处完全相同的硬编码色值**（含 `0xFF0F3D3B`、`0xFFE4F2C0` 等），存在漂移风险；`app_router.dart` 4 处逐字复制的 150ms 淡入代码块与 `app_theme.dart:622` 的主题级淡入过渡并存。
5. **必须保护的部分**：热力图与今日概览是 P0（`docs/requirements.md:200-201`），`contrast_test.dart`（163 行，覆盖 5 套调色板 × 2 模式 × 19 条断言）与 `accessibility_test.dart`（150 行，键盘可达 + 语义标签）正面对应 NFR-4（`docs/requirements.md:342-347`）；`ProgressiveRows`（性能修复，非装饰）、`DurationStepInput`（5 处复用）、`AppSemanticColors`（语义非颜色冗余）都不应动。
6. **四个表现层依赖全部是无传递依赖的叶子包**（`pubspec.lock` 中 fl_chart 1.2.0 / flutter_animate 4.5.2 / skeletonizer 2.1.3 / confetti 0.8.0 均无 `dependencies:` 段），因此删依赖不牵连依赖树；但 **fl_chart 只有在"删甘特图 + 简化燃尽曲线"同时发生时才能移除**，否则需手写 300～450 行 CustomPainter 替代。

---

## 1 条目表

判定取值：必留 / 可留（低成本观察） / 建议简化或合并 / 建议移除。

| ID | 功能或机制 | 用户可见入口 | 代码证据(file:line, LOC) | PRD | 是否重复/装饰性 | 判定 | 删除代价与风险 | 置信度 |
|---|---|---|---|---|---|---|---|---|
| C1 | 今日概览卡（完成 N/M + 已完成时长 + 目标剩余工作量，三块 `ClashStatTile`） | 进度页首屏第一张卡 | `progress_page.dart:551-642`（92）；`progress_page.dart:73-100`（provider）；`clash_widgets.dart:171-293`（123） | P0（FR-7.1，`requirements.md:200`） | 无重复；承载 P0 数据 | **必留** | 删除即失去 FR-7.1 验收项；牵连 `progressOverviewProvider`、`progress_page_test.dart:94-170` | 高 |
| C2 | 热力图（26 周格网 + 单色明度五档 + tooltip + 分桶图例 + 今日描边） | 进度页「完成热力图」卡 | `progress_page.dart:1115-1173`（59）+ `:1218-1404`（187）+ `:1180-1189`（10）+ `:1192-1211`（20）；`statistics_service.dart:140-146, 263-270` | P0（FR-7.2，`requirements.md:201`） | 无重复；格网是 `Container` 非 fl_chart | **必留** | 删除失去 FR-7.2 + `accessibility_test.dart:92-113` 断言 | 高 |
| C3 | 热力图日任务弹窗（点击格子看当天完成任务清单，含目标/科目/时长/完成时刻） | 点击任意热力图格子 | `progress_page.dart:1394-1403`（10）+ `:1408-1496`（89） | FR-7.2 只要求"非颜色信息或提示文本"，tooltip 已满足；弹窗为超配 | 与 tooltip 信息部分重叠 | **可留（低成本观察）** | 删除约 99 行 + `progress_page_test.dart:547-619` 2 个用例；风险低（P0 信息仍由 tooltip 承载） | 中 |
| C4 | 燃尽趋势图（`LineChart` 曲线 + 面积渐变 + 网格 + 45° 日期轴 + tooltip + 语义标签 + 600ms 入场） | 进度页「剩余工作量趋势」卡 | `progress_page.dart:656-812`（157）+ `:825-1104`（280）；`statistics_service.dart:272-333`（62）+ `:353-369`（17） | P1（FR-7.3，`requirements.md:202`） | **数值重复**：`remaining` 恒等于 `ideal`（`:318-323`），`BurndownPoint.ideal` 无独立信息 | **建议简化或合并** | 图表为纯直线，可退化为「当前剩余 + 到 M/d」文字/进度条；可省 ~350 行 + fl_chart 一半用法；风险：FR-7.3 P1 名义上要求"燃尽趋势 + 理想参考线" | 中 |
| C5 | 任务耗时图（原甘特图：按周堆叠柱，完成=暖/计划=冷，`BarChart`） | 进度页「任务耗时图」卡 | `progress_page.dart:1507-1601`（95）+ `:1615-1876`（262）+ `:154-217`（64）；`statistics_service.dart:25-38`（14）+ `:148-165`（13）+ `:167-211`（45） | **P2**（`requirements.md:205` 原文「甘特图…列为 P2」；`requirements.md:79` P2 列「交互甘特图」） | 非装饰（有数据），但与燃尽图共用同一 fl_chart 柱/线配置约 120 行高度同构 | **建议移除** | 约 516 行生产代码；牵连 `progressGanttProvider` 全链路 + `progress_page_test.dart:201-389,515-545,621-739` + `plan_import_widget_test.dart:364-377` + `statistics_service_test.dart:181-270,388-430`；风险：删除后不再有"按周计划 vs 完成"视图（PRD 判为可延后） | 高（PRD 判定）/ 中（测试改动量） |
| C6 | `StatisticsService.minutesLevel`（甘特图五档分桶 0/1-59/60-119/120-299/300+） | 无（无可达 UI 调用点） | `statistics_service.dart:248-257`（10） | 无（随 P2 甘特图产生） | **死代码**：全仓仅测试引用（`statistics_service_test.dart:181-191`），lib 内零调用 | **建议移除** | 10 行 + 1 个测试 group；零风险 | 高 |
| C7 | 折叠式「数据统计说明」（默认收起，`AnimatedSize` 200ms 展开） | 进度页底部 | `progress_page.dart:319-407`（85）；`:373-376`（动画） | FR-7.3/7.4 要求"在界面说明"（`requirements.md:203`） | 无重复；硬编码 200ms 绕过 `motionControllerProvider` | **必留** | 说明文案是 PRD 要求；仅动画时长应改走 motion 开关（见 C20） | 高 |
| C8 | 图例组件（`_LegendDot` 色块 + `_CompactLegend` 五档文本） | 燃尽图/耗时图底部、热力图底部 | `progress_page.dart:409-431`（21）+ `:1192-1211`（20） | NFR-4「不仅依赖颜色表达」（`requirements.md:345`） | 与 `ClashChip` 的 soft 变体职责轻微重叠 | **必留** | 是 NFR-4 的落实点；删除需另找非颜色承载方式 | 高 |
| C9 | 计划偏好入口卡（`HoverableCard` + 暖色实心图标块 + 摘要 + chevron） | 进度页倒数第二张卡，点击进 `/plan-preference` | `progress_page.dart:433-535`（103）；`:305-307`（挂载） | PRD 无此项（计划偏好属 §5.1 首次使用流程，非进度反馈） | 数据源与「今天」页/设置页的偏好展示重复 | **建议简化或合并** | 约 100 行 + `app_router.dart:206-208` 路由；可降级为一行文字链接或移回设置页；风险：进度页少一个入口 | 中 |
| C10 | confetti 彩纸屑庆祝（今日任务全完成时播一次，4s 自动移除） | 今天页：当日任务全部完成瞬间 | `celebration_overlay.dart:1-87`（87）；调用点 `today_page.dart:229-234`；依赖 `pubspec.yaml:53` | 无任何 FR 条目 | **纯装饰** | **建议移除** | 87 行 + 1 个 leaf 依赖 + OverlayEntry/Timer 生命周期维护；零功能损失；风险：失去唯一的完成正反馈 | 中 |
| C11 | `ClashHero` 双装饰光斑（`_Orb` × 2，半透明圆，右上+左下） | 今天页倒计时卡、目标详情头、课表页头 | `clash_hero.dart:45-49`（参数）、`:69-95`（Stack）、`:99-119`（`_Orb`） | 无 | **纯装饰**（注释自称"装饰，纯视觉"，`:45`） | **建议简化或合并** | 约 50 行；渐变与 shadowTinted 保留即可维持撞色观感；风险：hero 卡层次感下降（主观） | 中 |
| C12 | `HoverableCard` hover 上浮 + 阴影 + 边框（桌面可点暗示） | 所有可点卡片（今天页倒计时、目标卡、进度页偏好卡、课表） | `hoverable_card.dart:57-129`（73）；调用点 4 处（`goal_list_page.dart:402-403`、`today_page.dart:1357-1362`、`progress_page.dart:448-453`、`timetable_page.dart`） | 无（桌面可用性） | **参数冗余**：`hoverShadowOpacity` 声明后从不读取（`:26,48` vs `:78-89`） | **可留（低成本观察）**；但应删掉无效参数 | 组件本身是真实可用性收益（4 处复用）；无效参数删除 3 行 + 2 处传参 | 高（参数无效）/ 中（整体去留） |
| C13 | 骨架屏（`Skeletonizer` shimmer 灰块） | 今天/进度/日历/课表页首载 | `page_skeletons.dart:1-120`（120）；import `:2`；依赖 `pubspec.yaml:52` | 无 | **自我重复**：同文件 `:104-119` 的 `goalDetailPage` 已改用静态灰块并注明"shimmer 与过渡动画叠加是掉帧元凶"（`:101-103`） | **建议简化或合并** | 去掉 `Skeletonizer` 3 处包裹（`:16,:38,:57,:77`）改用已有 `_SkeletonBlock`（`:126-145`），可省 1 个依赖 + 约 20 行；风险：首载观感变"静态"（正是同文件已认可的取舍） | 中 |
| C14 | 页面过渡动画（主题级 `_FadePageTransitionsBuilder` + 路由器 4 份 `CustomTransitionPage` 150ms 淡入） | 页面切换（导航栏 6 个主分支 + 4 个子页） | `app_theme.dart:610-617, 622-643`（22+8）；`app_router.dart:145-152, 158-168, 176-185, 193-202`（4×8） | 无（性能取向，注释称"桌面端最省合成"） | **4 份逐字复制的过渡配置**，与主题 builder 两套机制并存 | **可留（低成本观察）**；建议合并为 1 个 helper | 合并 4 处可省约 24 行；删除主题 builder 需先确认 `builder:` 路由（`app_router.dart:85…240`）仍能拿到 150ms 时长（`PageTransitionsTheme` 不管时长） | 中 |
| C15 | 撞色组件体系（`ClashSectionHeader` / `ClashStatTile` / `ClashChip` / `ClashEmptyState`） | 全站卡片标题、KPI、标签、空态 | `clash_widgets.dart:1-485`（485）；`clash_tones.dart:1-187`（187） | M10「浅色/深色主题三选一」已交付（`requirements.md:82`）；组件本身不在 PRD | 部分重复：与 `SectionHeader`/`ChartEmptyState` 功能重叠（见 C16、C17） | **建议简化或合并** | 体系本身是外观语言主干（`ClashTones` 全仓 **161 处**引用），整体不可删；可裁的是重叠组件与 5 处硬编码色（C19） | 中 |
| C16 | `SectionHeader`（旧区块头，仅剩 2 个真实调用点） | 目标列表页、目标分区、折叠区块内 | `section_header.dart:1-71`（71）；调用 `goal_list_page.dart:1`、`goal_section.dart:1`、`collapsible_section.dart:92` | 无 | **与 `ClashSectionHeader` 重复**：后者全仓 28 处引用、功能为其超集（带计数徽标/撞色竖条） | **建议简化或合并** | 迁移 2 个调用点到 `ClashSectionHeader`（+ tone 参数）后删 71 行；风险：`collapsible_section` 需同步改（1 行 import + 1 处构造） | 高 |
| C17 | `ChartEmptyState`（`ClashEmptyState` 的薄封装，仅剩 2 个调用点） | 科目管理、日历页空态 | `chart_empty_state.dart:1-53`（53）；调用 `subject_manager.dart:1`、`calendar_view.dart:1` | 无 | **与 `ClashEmptyState` 重复**（`:38-51` 直接转发） | **建议简化或合并** | 2 处调用点改为直接构造 `ClashEmptyState`，删 53 行；零行为变化 | 高 |
| C18 | 三套撞色方案 + 2 套 legacy 调色板（clash / electric / violet / green / blue） | 外观设置页 SegmentedButton（只展示前 3 个） | `accent_palette.dart:202-347`（约 146 行常量 + 注册表 `:341-347`、`clashPaletteOrder:350`） | M10「主题三选一」已交付（`requirements.md:82`） | legacy 两套**仅为老数据渲染路径**（`:284-285, 312` 注释自述） | **必留（legacy 部分见 §4 存疑）** | 删 legacy 需迁移已持久化的 `settings.accent_color='green'/'blue'`，否则老用户回退默认；同时 `contrast_test.dart:30` 的 5×2 矩阵可缩为 3×2 | 高（现状必留）/ 中（legacy 去留） |
| C19 | `ClashTones` 与 `app_theme.dart` 的硬编码色值重复 | 无直接入口（深色模式撞色块观感） | `clash_tones.dart:77,84,85,93,97` ↔ `app_theme.dart:75,81,84,93,98`（5 对完全相同的 6 位色值） | NFR-4 对比度（`requirements.md:346`） | **重复**：如 `0xFF0F3D3B`＝`scheme.secondaryContainer(dark)` 在 `app_theme.dart:81` 与 `clash_tones.dart:84` 各写一遍 | **建议简化或合并** | 合并为引用 `scheme.*Container` 或 token 常量；约 8 行改动；风险：改动触及深色对比度，必须重跑 `contrast_test.dart`（当前断言不含这些派生对，需人工核验） | 高（重复事实）/ 中（合并安全性） |
| C20 | `motion_provider`「减少动画」开关 + 散点动画时长 | 外观设置页「减少动画」开关 | `motion_provider.dart:1-37`（37）；接入点 12 处；**未接入**：`progress_page.dart:373-376`（200ms 硬编码）、`collapsible_section.dart:118-120`（`motionNormal` 直用）、`completion_checkbox.dart:46,103,126`（180/140ms 硬编码） | NFR-4 可访问性精神（PRD 无显式条款） | 开关语义与 3 处硬编码时长不一致（`completion_checkbox` 的豁免已在 `motion_provider.dart:11` 文档化） | **可留（低成本观察）** | 把 2 处 `AnimatedSize` 时长改走 `motion.duration(...)` 约 4 行；风险极低；`completion_checkbox` 属文档化豁免，可不动 | 中 |
| C21 | `flutter_animate` 单点入场动画（倒计时卡 Fade + Slide） | 今天页倒计时卡入场 | `today_page.dart:2`（import）、`:1336-1352`（17）；依赖 `pubspec.yaml:51` | 无 | **重复**：与 `progress_page.dart:912-924` 的 `TweenAnimationBuilder` 实现同一效果（更少依赖） | **建议移除（依赖）** | 17 行改为 `TweenAnimationBuilder`（同仓已有范本）；删 1 个 leaf 依赖；风险：需保留 `motion.skipEntrance` 分支 | 高 |
| C22 | `CompletionCheckbox` 弹性回弹 + 对勾淡入 | 今天页任务行、里程碑卡 | `completion_checkbox.dart:1-137`（137）；调用 2 处（`task_tile.dart:1`、`milestone_card.dart:1`） | 无（交互反馈） | 与 Flutter `Checkbox` 不同（自绘圆环），非重复 | **可留（低成本观察）** | 已按 `motion_provider.dart:11` 明确豁免 reduce 模式；`semanticLabel` 强制传参落实 NFR-4 | 中 |
| C23 | `ProgressiveRows` 视口驱动懒构建 | 所有长任务/里程碑列表（今天页、目标详情、日历侧栏、计划草稿） | `progressive_rows.dart:1-152`（152）；7 个文件引用 | NFR-1 性能（非装饰） | 无重复 | **必留** | 删除会让 1000+ 行列表首帧卡死（注释记录实测单帧 4s+，`:9-10`） | 高 |
| C24 | `DurationStepInput` 时长步进器（h/m 步进、长按连发、直接输入、`+15/+30/+1h` 快捷键） | 任务表单、批量表单、重复任务、计划偏好页（5 处） | `duration_step_input.dart:1-483`（483）；调用 5 处 | FR-1/FR-3 预估时长（`requirements.md:76`） | 无重复 | **必留** | 5 处复用，删除需重写输入控件；`duration_step_input_test.dart`（99 行）守护长按回归 | 高 |
| C25 | 年份热力图月格（`completedCountsByMonth`） | **计划页**年视图（非进度页） | `statistics_service.dart:85-102`（18）；消费点 `calendar_view.dart:195-199, 304-308, 1726+` | **P2**（`requirements.md:205`） | 口径与热力图重复（同一 `status==done + completedAt` 契约，`:70-72` vs `:87-89`） | **建议移除**（归属日历页范围，仅交叉引用） | 服务方法 18 行 + 年视图 UI 归属 D/日历审计；本报告不越权判定 UI 部分 | 中 |

---

## 2 逐条论证

**C1 今日概览卡（必留）**。对应 `docs/requirements.md:200` 的 FR-7.1 三项数据与 `progress_page.dart:73-100` 的口径实现，是 P0 闭环的数据出口。三块 `ClashStatTile` 的实心/浅底变体（`:598-633`）属表现层，但同一 provider 也只服务这一张卡，不存在可裁剪的第二消费者。唯一可议的是 `IntrinsicHeight`（`:593`，注释称"一次额外测量，开销可忽略"），不构成镀金。

**C2 热力图（必留）**。P0 的 FR-7.2 明确要求"按日期展示完成任务数量，并提供非颜色信息或提示文本"，实现同时给了 tooltip（`progress_page.dart:1368-1369`）、`Semantics` 标签（`:1370-1372`）与带文本图例（`:1164-1167`），是 NFR-4 的正面落实（`accessibility_test.dart:92-113` 有对应断言）。色阶刻意不用 fl_chart，是纯 `Container` 网格（`:1376-1387`），因此**热力图与 fl_chart 依赖无关**——这一点直接影响 §5 的依赖结论。

**C3 热力图日任务弹窗（可留）**。FR-7.2 的信息需求已被 tooltip + 读屏标签满足，弹窗（`progress_page.dart:1408-1496`）是超出 PRD 的增强：它额外提供了一个真实用户价值（"我那天到底完成了什么"），且实现上做了 O(1) 预分桶（`statistics_service.dart:73-83`）。代价是 99 行 UI + 2 个测试用例，另有一处可疑耦合：`_buildTaskTile` 在 `itemBuilder` 内 watch `subjectListProvider`（`:1467-1472`），弹窗打开时按任务数触发 N 次 provider 监听。判定"可留"，但若后续要减表，这是低风险第一个候选。

**C4 燃尽趋势（建议简化或合并，本报告最重要的一条）**。`statistics_service.dart:318-323`：

```dart
final int ideal = idealTotalDays > 0 ? (currentRemaining - idealPerDay * elapsed).clamp(0, currentRemaining).toInt() : 0;
final int remaining = idealTotalDays > 0 ? ideal : currentRemaining;
```

在 `idealTotalDays > 0`（有未来截止日）时 `remaining` **恒等于** `ideal`；`idealTotalDays <= 0`（已过期）时 `ideal` 恒为 0 而 `remaining` 恒为 `currentRemaining`。也就是说 `BurndownPoint.ideal`（`:353-369`）不携带任何独立信息，源码注释本身也承认"理想参考线与本序列取值相同"（`:280-281`）。图表层只画 `remaining`（`progress_page.dart:869-871`），`ideal` 仅用于 Y 轴取最大（`:857`）。结论：这张 280 行的图实际只呈现「当前剩余」沿一条直线衰减——而"当前剩余"和"截止日"都已经在卡头文字里（`progress_page.dart:707-713, 732-758`）。它不是装饰，但**信息量约等于零**，属于典型"为已有数字配一张图"的镀金。建议简化为一句带进度的文字/线性进度条，可连带使 fl_chart 的 LineChart 用法消失。**反方证据**：FR-7.3 明确是 P1 且要求"理想参考线"，我未找到 PRD 允许超出 P1 交付的证据，故此项列入 §4 存疑由用户拍板，而非直接判移除。

**C5 任务耗时图＝甘特图（建议移除）**。`docs/requirements.md:205` 原文："甘特图、年份热力图、PNG/PDF 报告导出列为 P2。MVP 先验证任务执行闭环，避免图表开发挤占核心体验。"代码侧 `_GanttSection`（`progress_page.dart:1507`）名称未改，注释自述"原「甘特图」实为按目标×周的周时长堆叠条形图，无任务时间跨度、非真正甘特图，名不符实"（`:1500-1501`）——即已实现的仍是 PRD 所指的 P2 图表，只是重构为一维柱状图并改名叫「任务耗时图」。规模：UI 95+262 行、provider 64 行（`:154-217`）、服务层约 72 行、测试约 13 个用例。收益侧只有"按周看计划 vs 完成"这一维度，而同类信息在 burn-down 的「当前剩余」与今日概览的「目标剩余工作量」中已有 P0/P1 覆盖。这是本次审计中**唯一由 PRD 直接判定**的镀金项。

**C6 `minutesLevel` 死代码（建议移除）**。`statistics_service.dart:248-257` 定义的五档分钟分桶在 `lib/**` 内**零调用点**（全仓 grep 仅命中定义与 `statistics_service_test.dart:181-191` 的测试）。它随甘特图产生（文档注释仍写"甘特图时长分桶"），`_BarChart` 改用连续高度 + `maxY` 比例（`progress_page.dart:1642-1651`）后即废弃。删除 10 行 + 1 个测试 group，零风险。

**C7 数据统计说明（必留）**。它是 FR-7.3/FR-7.4 唯一落地的"界面说明"（`docs/requirements.md:203` 要求"在界面说明"），文案已核对与渲染一致（`progress_page.dart:385-393` 记录了 3 处纠正）。折叠交互（`:342-372`，85 行）属表现层，可以缩短但不应删除。

**C8 图例（必留）**。`_LegendDot`（12×12 圆角块，`progress_page.dart:411-431`）与 `_CompactLegend`（`:1192-1211`）是 NFR-4「不仅依赖颜色表达」的具体承载：热力图五档如果只有颜色，色觉障碍用户无法区分。删除等于触碰 PRD 硬要求，不建议动。

**C9 计划偏好入口卡（建议简化或合并）**。PRD 中"计划偏好"出现在 §5.1 首次使用流程（`docs/requirements.md:96`）与 FR-5 负载计算，**不属于进度反馈**（FR-7）。该卡在进度页的定位由注释自述为"偏好是解读进度的上下文"（`progress_page.dart:305-306`），属于设计者自证的合理性，缺少 PRD 支撑；同时设置页已把该区块移走（`app_router.dart:204` 注释）。98 行卡 + 独立路由 `/plan-preference` 只为一个入口服务。可降级为一行文字链接（或把摘要并入 C1 概览卡的 hint），不影响任何 FR。

**C10 confetti 彩纸屑（建议移除）**。`celebration_overlay.dart` 87 行只为一次 4 秒的纯装饰效果服务，且需要 OverlayEntry + Timer + `IgnorePointer` + RepaintBoundary 一整套生命周期管理（`:20-29, 43-58, 66-84`），注释里还记录了一次"从侧面洒下"的返工（`:13-14, 74-75`）——这是典型的维护成本大于用户价值。调用点已正确用 `reduceMotion` 门控（`today_page.dart:229-234`），说明"这个效果需要被允许关掉"本身就被承认。PRD 全篇无任何庆祝动效条目。**注意**：这是产品情绪决策而非缺陷，列入建议移除但标注"失去唯一完成正反馈"的代价。

**C11 `ClashHero` 双 Orb（建议简化或合并）**。`clash_hero.dart:45` 的注释直接写着"装饰，纯视觉"；两个 `Positioned` 光斑（`:71-82`）＋ `_Orb` 类（`:99-119`）共约 50 行，作用是"制造层次"。hero 卡的撞色表达主要来自 `ClashGradient.clash`（`clash_tones.dart:164-176`）与 `shadowTinted`（`app_tokens.dart:176-182`），Orb 是可去掉的叠加层。保留渐变、删 Orb 不改变信息与可访问性。风险纯主观（观感变平）。

**C12 `HoverableCard`（可留，但参数必须清理）**。组件本身有真实桌面价值（"这张卡能点"的暗示），4 处复用，且正确地用 `SystemMouseCursors.click` 与 `motion.duration(...)`。但 `hoverShadowOpacity`（`:26` 声明、`:48` 字段）**从未被读取**：`_hoverDecoration` 固定用 `AppTokens.shadowCardHover(isDark)`（`:87`），无视该值。两个调用点（`goal_list_page.dart:403` 传 `0.04`、`today_page.dart:1362` 传 `0.13`）以为自己改了阴影强度，实际完全无效——这是"配置面比行为大"的典型遗留物，应删除参数与两处传参（3 行）。判定"可留"针对组件整体，针对参数则是明确的简化项。

**C13 骨架屏（建议简化或合并）**。`page_skeletons.dart` 同时存在两种骨架：4 个 `Skeletonizer` 包裹的 shimmer 版本（`:16, :38, :57, :77`）和 1 个静态灰块版本（`goalDetailPage`，`:104-119`），后者的注释明确写道"**不用 Skeletonizer 流动动画**——shimmer 动画与页面过渡动画叠加是 Windows 桌面进入卡顿的实测元凶"（`:101-103`）。同文件已给出结论，却只在 1/5 的页面上执行。把其余 4 处换成已有的 `_SkeletonBlock`（`:126-145`）即可删掉 `skeletonizer` 依赖与约 20 行。风险：首载观感由"流动"降为"静态"，而这正是同文件已认可的取舍。

**C14 页面过渡（可留，建议合并重复）**。`_FadePageTransitionsBuilder`（`app_theme.dart:622-643`）与 `app_router.dart` 的 4 份 `CustomTransitionPage`（`:145-152, 158-168, 176-185, 193-202`）不是纯重复：主题 builder 只替换过渡曲线（`PageTransitionsTheme` 不控制时长），而 4 份 CustomTransitionPage 的真正作用是"150ms 而非 MaterialPage 默认时长"。但 4 份逐字相同（含 `reverseTransitionDuration: 120`），应抽为 1 个 helper（可省约 24 行）。整体不应删——纯淡入是文档化的性能结论（`app_theme.dart:610`）。

**C15 撞色组件体系（建议简化或合并）**。`ClashTones` 全仓 161 处引用、`ClashSectionHeader` 28 处、`ClashChip` 27 处，这是应用外观的主干，不是镀金。可裁的是体系内部的冗余：C16/C17 两个被超集组件替代的旧组件，以及 C19 的硬编码重复。注意 `ClashStatTile` 的 `dense`/`maxWidth` 参数（`clash_widgets.dart:198-201`）有大量踩坑注释与真实调用点（`dense:` 全仓 26 处），属于有效复杂度，不应动。

**C16 `SectionHeader`（建议简化或合并）**。仅剩 2 个页面级调用点，而 `ClashSectionHeader`（`clash_widgets.dart:12`）是其超集：多出撞色竖条、计数徽标、`dense`、`foreground`。两个类各自维护图标底/标题/副标题布局，是奥卡姆第 5 条的直证。迁移调用点（含 `collapsible_section.dart:92`）后删 71 行，无行为变化。

**C17 `ChartEmptyState`（建议简化或合并）**。`chart_empty_state.dart:38-51` 是纯转发：把 `icon/title/caption/actionLabel` 映射到 `ClashEmptyState`（固定 `tone: cool, compact: true`）。仅剩 2 个调用点，且 `ClashEmptyState` 自身已有 23 处引用。删 53 行、改 2 处调用，零行为变化。

**C18 调色板（现状必留）**。M10 已交付"跟随系统/浅色/深色三选一"（`docs/requirements.md:82`），UI 只展示 3 套（`clashPaletteOrder`，`accent_palette.dart:350`），另 2 套 legacy（`:286, :313`）存在的唯一理由是"为已持久化该值的老数据保留渲染路径"（注释自述）。这属于**数据兼容**而非镀金，删除前必须确认迁移策略（见 §4）。附带成本：`contrast_test.dart:30` 遍历 5 套方案 × 2 模式 × 19 条断言 = 190 个断言。

**C19 5 处硬编码色重复（建议简化或合并）**。实测 `app_theme.dart` 与 `clash_tones.dart` 有 5 对完全相同的 6 位色值：`app_theme.dart:75/81/84/93/98` ↔ `clash_tones.dart:77/84/85/93/97`（如 `0xFF0F3D3B` 同时是 `scheme.secondaryContainer` 深色值与 `ClashTone.cool.soft` 深色值）。同一语义在两处各写一遍，任一改动都会造成深浅模式下的撞色块与 M3 容器色不一致。合并方案：`ClashTones.of` 的深色分支改为引用 `scheme.secondaryContainer` / `onSecondaryContainer` / `tertiaryContainer` 等，或提升为 `AppTokens` 常量。**风险须明说**：`contrast_test.dart` 断言的色对清单（`:41-137`）不覆盖 `ClashTones.soft/onSoft` 组合，合并后的实际对比度需人工核验，不能仅凭测试通过判定安全。

**C20 reduce-motion 覆盖缺口（可留）**。`motion_provider.dart:11` 明确豁免"勾选回弹、hover 光标等短交互"，所以 `completion_checkbox.dart:46,103,126` 的硬编码时长是**设计意图而非疏漏**。真正的缺口是 2 处 `AnimatedSize`：`progress_page.dart:373-376`（200ms 硬编码）与 `collapsible_section.dart:118-120`（`motionNormal` 直用），它们不属于"必要操作反馈"却无视开关。修 2 处约 4 行。

**C21 `flutter_animate`（建议移除依赖）**。全仓唯一使用点是 `today_page.dart:1336-1352`，效果为 `FadeEffect(320ms) + SlideEffect(begin: (0,-0.04))`。同一代码库在 `progress_page.dart:912-924` 已经用 `TweenAnimationBuilder` + `Opacity` + `Transform.translate` 实现了等价的"淡入 + 上移"，且明确记录了不用 `ClipRect` 的原因。用同仓范本替换 17 行即可删掉一个依赖；`motion.skipEntrance` 分支（`today_page.dart:1339-1341`）可原样保留。

**C22 CompletionCheckbox（可留）**。自绘圆环 + `elasticOut` 回弹（180ms）+ 对勾淡入（140ms），带 `Semantics(checked:, label:)`（`completion_checkbox.dart:83-85`）且 `semanticLabel` 为必填——这是 NFR-4 的正面落实。它不与 Material `Checkbox` 形成重复（视觉语言不同且为主题服务），保留。

**C23 ProgressiveRows（必留）**。这是**性能修复而非装饰**：`progressive_rows.dart:9-10` 记录"大任务量目标（批量/JSON 导入 1000+）一次性全量 build，进入页面首帧卡死（实测单帧 4s+）"，实现细节（从 `RenderAbstractViewport` 取真实滚动偏移，`:87-119`）有明确的技术理由。`test/shared/widgets/progressive_rows_test.dart`（121 行）守护它。不属于镀金候选。

**C24 DurationStepInput（必留）**。483 行、5 处复用（任务表单/批量/重复/计划偏好/快捷对话框），实现包含长按连发这一有真实痛点的交互（`:107-121` 含一个 P0 回归修复的详细注释），并有 `duration_step_input_test.dart`（99 行）覆盖。属核心输入控件。

**C25 年份热力图（建议移除，但越权提示）**。`docs/requirements.md:205` 把"年份热力图"与甘特图并列判 P2。其数据入口是 `statistics_service.dart:85-102`（本报告范围内），但 UI 在计划页 `calendar_view.dart:195-199, 304-308, 1726+`（**非本审计范围**）。本报告只标注服务层方法与 P2 冲突，UI 层去留交由日历/计划页审计者判定，避免越权。

---

## 3 明确不建议动的部分

- **P0 反馈闭环**：今日概览（C1）、热力图网格 + tooltip + 图例 + Semantics（C2/C8）、`_StatNote` 说明（C7，唯一落实 FR-7.4"界面说明"）。删除任一项都会击穿 FR-7.1/7.2 或 NFR-4。
- **`test/core/theme/contrast_test.dart`（163 行）与 NFR-4 相关实现**：它把"用户真实看到的色对"固化为 190 条断言（`contrast_test.dart:30-140`），是 PRD `requirements.md:346`「对比度以 WCAG 2.1 AA 为目标」唯一的可执行证据。任何主题色改动都必须先跑它（本次审计为只读，未运行）。
- **`test/core/accessibility/accessibility_test.dart`（150 行）**：覆盖"状态不只靠颜色"（`:57-71`）、读屏标签（`:73-90, 92-113`）、键盘可达（`:115-134`），直接对应 `requirements.md:344-347`。
- **`ProgressiveRows`（C23）与 `DurationStepInput`（C24）**：性能修复与高复用核心控件，均为"已被真实缺陷验证过"的复杂度。
- **`AppSemanticColors`（`app_semantic_colors.dart` 173 行）**：warning/success/info 与 `scheme.error` 分离是为了让"过载"与"逾期"不共用红色（`:5-8` 自述），且 5 套方案 × 2 模式全部验过对比度。删除会把两种语义压回同一个红，直接违反 NFR-4 精神。
- **`motion_provider` 开关本身（C20）**：可访问性收益明确，接入 12 处；问题只是覆盖不全，不是机制多余。
- **纯淡入页面过渡（C14）**：有文档化的性能结论支撑（`app_theme.dart:610`），不是审美偏好。
- **`completion_checkbox` 的弹性回弹（C22）**：`motion_provider.dart:11` 已文档化豁免，属有意设计。
- **PNG/PDF 报告**：全仓 grep `pdf|Png|screenshot|exportReport` 在 `lib/**` 内**零命中**，即 PRD 列为 P2 的该项从未实现——不存在可裁剪的代码，不列入条目表。

---

## 4 存疑项（需要用户拍板）

**S1 燃尽趋势图（C4）——保留"假曲线"还是退化为数字？**
- 选项 A（保留现状）：符合 FR-7.3 P1 的字面要求（"燃尽趋势 + 理想参考线"），但图上只有一条由「当前剩余 + 截止日」确定的直线，不含任何历史实际完成量；代价是 280 行图表代码 + fl_chart 的 LineChart 用法，以及"看起来像数据、其实不是数据"的误导风险。
- 选项 B（简化为文字/进度条）：省约 350 行，卡头已有的"当前剩余 X · 计划燃尽到 M/d"（`progress_page.dart:707-713, 732-758`）即为全部信息；代价是名义上未交付 FR-7.3 的"趋势"形态，且若将来要做真·实际燃尽（按每日快照统计剩余），需把现在删掉的图表框架重建。
- 我需要用户决定：**是否认为"由两个数字推出的直线图"算作 FR-7.3 的达标交付**。若认为不达标，正确做法可能是补真实历史数据而不是删图——那属于功能补做，超出本次"找镀金"的范围。

**S2 legacy 调色板 green/blue（C18）——删还是留？**
- 选项 A（保留）：老数据 `settings.accent_color='green'/'blue'` 仍能正确渲染（`accent_palette.dart:352`）；代价是 2×22 个色值常量 + `contrast_test` 断言数从 114 增到 190、`app_theme` 需为它们维护亮/暗两套中性色映射。
- 选项 B（删除 + 迁移）：删除时把已知 id 映射到 `clash`（`accentPaletteById` 已有 `?? clashAccent` 兜底，`:353`），老用户视觉会变化但功能不受影响；代价是需要确认是否接受"老用户升级后配色被换掉"，以及 `settings.accent_color` 是否需一次性数据迁移（本报告未查 DB 迁移路径，属低置信度）。
- 我未能确认的点：**仓库中是否存在依赖 green/blue 的迁移测试或已有用户数据假设**，需 D/设置页审计者或用户确认。

**S3 甘特/任务耗时图（C5）——直接删除还是冻结？**
- 选项 A（删除）：PRD 判 P2，省 516 行 + 13 个测试用例；代价是删掉一个已经写好、测试齐全的功能，且需同步改 `plan_import_widget_test.dart:377`（断言 `BarChart`）等跨模块测试。
- 选项 B（冻结不修）：代码留在仓库但标注 P2 实验状态，后续不再投入；代价是继续承担 fl_chart 依赖与每次主题/布局重构时的连带维护（本报告已见 4 处 fl_chart 配置级注释补丁，如 `progress_page.dart:1766-1771`）。
- 这本质是"沉没成本 vs 范围纪律"，需用户决定。

**S4 骨架屏 shimmer（C13）——统一为静态灰块还是保留 shimmer？**
- 选项 A（统一静态）：删 `skeletonizer` 依赖，与 `goalDetailPage` 的既有结论一致（`:101-103`）；代价是 4 个页面的首载观感变"静态"。
- 选项 B（保留 shimmer）：观感更"专业"；代价是 1 个依赖 + 已记录的"shimmer 与过渡动画叠加掉帧"风险仍在其余 4 个页面上。
- 我未能确认：**掉帧结论是针对"详情页 150ms 过渡 + shimmer"的特例，还是所有页面的普遍现象**（注释只写了详情页场景）。

**S5 计划偏好入口卡位置（C9）——留进度页、移设置页，还是并入概览卡？**
- 选项 A（留）：现状，进度页多一个入口，98 行；选项 B（移回设置页）：设置页注释显示该区块曾被主动移除（`app_router.dart:204`），移回等于回退一次设计决策；选项 C（并入 C1）：把"每日可用 X · 每周 N 天"作为概览卡的一个 hint，删掉整卡与独立路由，约省 100 行。
- 取决于用户是否认为"进度数据需要偏好做上下文"这一设计者自证的理由成立。

---

## 5 可移除依赖评估

四个依赖**全部为 direct main 且无传递依赖**（`pubspec.lock` 中四项均无 `dependencies:` 段），因此任一项移除都不会连带其它包；`pubspec.yaml` 对应行分别为 `:50`（fl_chart `^1.2.0`）、`:51`（flutter_animate `^4.5.2`）、`:52`（skeletonizer `^2.1.3`）、`:53`（confetti `^0.8.0`）。锁定版本：fl_chart 1.2.0、flutter_animate 4.5.2、skeletonizer 2.1.3、confetti 0.8.0。

### 5.1 confetti ^0.8.0 —— 建议移除（成本最低）

- **被谁用**：仅 `lib/shared/widgets/celebration_overlay.dart`（`import:4`、`ConfettiController:42,48`、`ConfettiWidget:71-82`）；调用点仅 `today_page.dart:229-234`。
- **用了哪些 API**：`ConfettiController(duration:)`、`.play()`、`.dispose()`、`ConfettiWidget(confettiController:, colors:, blastDirectionality:, blastDirection:, gravity:, emissionFrequency:, numberOfParticles:, shouldLoop:)` —— 共约 9 个参数，无一不可替代。
- **移除后替代方案**：(a) 直接删除庆祝效果（87 行 + 调用点 6 行），零替代代码；(b) 若必须保留情绪反馈，用 `AnimationController` + `CustomPaint` 画 20～30 个短线段，约 80～120 行，等于用自研换依赖——不划算，建议直接选 (a)。
- **行数代价**：删除 87 行；调用侧需清理 `today_page.dart` 的 `_celebratedDone` 状态机，已核实共 **6 处引用**：字段声明 `:92`，置位判断 `:225-226`，触发 `:229`，复位分支 `:232-233`。若庆祝效果整个删除，`:232-233` 的复位分支也随之失效（其唯一作用是允许下一次"全部完成"再次触发），因此调用侧净删约 10～12 行。

### 5.2 flutter_animate ^4.5.2 —— 建议移除

- **被谁用**：全仓唯一 import 与唯一使用点 `today_page.dart:2`、`:1336-1352`。
- **用了哪些 API**：`Animate(effects:)` + `FadeEffect(duration:, curve:)` + `SlideEffect(begin:, end:, duration:, curve:)`。
- **移除后替代方案**：同仓已有等价实现范本 `progress_page.dart:912-924`（`TweenAnimationBuilder` → `Opacity` + `Transform.translate`），17 行改写，且 `motion.skipEntrance` 的"effects 为空即静止"语义可直接映射为 `duration: motion.duration(...)`。
- **行数代价**：净减少约 15 行（等量替换）并删 1 个依赖；无测试直接依赖（全仓测试未 import flutter_animate）。

### 5.3 skeletonizer ^2.1.3 —— 建议移除（与 S4 联动）

- **被谁用**：仅 `lib/shared/widgets/page_skeletons.dart`（`import:2`；`Skeletonizer` 包裹 4 处：`:16, :38, :57, :77`）。
- **用了哪些 API**：仅 `Skeletonizer(child:)` 一个构造，无 `SkeletonizerConfig`、无 `Bone`、无自定义效果——即**只用了包的默认 shimmer 包裹能力**。
- **移除后替代方案**：同文件已有 `_SkeletonBlock`（`:126-145`，20 行，静态圆角灰块，颜色取 `scheme.surfaceContainer`）与 `goalDetailPage` 的完整范本（`:104-119`）。把 4 处 `Skeletonizer(child: X)` 改为直接返回 `X` 并把内部 `Text('骨架卡片占位')` 换成 `_SkeletonBlock` 即可。
- **行数代价**：净减少约 20 行（删除 4 层包裹，替换占位容器），并删 1 个依赖。风险：`page_skeletons` 的 6 个调用点（`goal_detail_page.dart:51`、`calendar_view.dart:136`、`progress_page.dart:247,253`、`timetable_page.dart:92`、`today_page.dart:126`）无一处断言 shimmer 存在——`test/features/progress/presentation/progress_page_test.dart` 只断言内容文本，未断言骨架结构（低～中置信度：我未逐行读完该 739 行测试文件，仅按检索到的断言列表判断）。

### 5.4 fl_chart ^1.2.0 —— 有条件移除（唯一"重"依赖）

- **被谁用**：`lib/features/progress/presentation/progress_page.dart:3`（`LineChart:925`、`BarChart:1734`，以及 `FlGridData/FlTitlesData/FlBorderData/LineTouchData/BarTouchData/FlDotData/BarChartRodStackItem` 等约 25 个类型）；测试侧 `test/features/progress/presentation/progress_page_test.dart:3,225,300,358,435,640` 与 `test/features/plan_import/presentation/plan_import_widget_test.dart:2,377` 直接 import 并断言 `find.byType(BarChart)` / `find.byType(LineChart)`。
- **用了哪些 API**：本次实际只用了两种图表——`LineChart`（燃尽，C4）与 `BarChart`（耗时图，C5）。热力图（C2）完全不用 fl_chart。注意 `num` 型刻度的全部定制（`reservedSize`、`space`、`interval`、`FittedBox` 防溢出）都是绕开 fl_chart 自动布局的补丁，`progress_page.dart:958-987` 与 `:1762-1790` 两处注释分别记录了"刻度贴线重叠"与"文字压到柱状图"的真实故障——即**该依赖的集成成本高于其配置便利**。
- **移除后替代方案**：
  - 若 C5（甘特/耗时图）与 C4（燃尽曲线）都被删/简化 → **fl_chart 零用法，可直接删依赖，替代代码为 0 行**（热力图、图例、KPI 均不依赖它）。
  - 若只删 C5 而保留 C4 → 仍需要 `LineChart`。手写替代需要 `CustomPaint` + 自算刻度/网格/45° 轴标签/hover hit-test + tooltip 浮层，按现有 280 行配置的复杂度估算，**约 200～300 行**（且要重做 tooltip 越界不裁剪的处理，`progress_page.dart:1036-1042`），不建议。
  - 若两者都保留 → 无法移除。
- **行数代价**：删除依赖本身 0 行；连带删除 UI+provider+service 约 **870 行**（C4 的 437 + C5 的 516，去重后），以及约 **15 个测试用例**需删除或改写（`progress_page_test.dart` 中 8 个含 `BarChart/LineChart` 断言的用例、`plan_import_widget_test.dart:364-377`、`statistics_service_test.dart` 的 gantt 与 minutesLevel 共 4 个 group、`test/performance/navigation_performance_test.dart:36` 的场景注释需同步）。
- **结论一句话**：fl_chart 的"可移除"完全取决于 C4+C5 的取舍——**单独讨论 fl_chart 没有意义，它是一个被 P2 功能拖进来的重依赖**。

---

## 附：本次审计未能确认的点（低置信度声明）

1. **未运行任何测试**（硬约束禁止 `flutter test`），因此"删除后测试是否通过"全部为静态推断。`test/features/progress/presentation/progress_page_test.dart` 共 739 行，我只读了前 120 行并用检索列出了断言点，未逐条核对每个用例的 fixture 依赖。
2. **`_celebratedDone` 的 6 处引用已核实**（`today_page.dart:92, 225, 226, 229, 232, 233`，见 §5.1）；但 `today_page.dart` 全文 1543 行我只读了约 1/4，其余与庆祝无关的交互未通读。
3. **未验证 `contrast_test.dart` 是否会捕获 C19 的合并改动**：从 `:41-137` 的断言清单看，`ClashTones.soft/onSoft` 组合不在其中，因此合并硬编码色后测试**可能仍然通过**，实际对比度需人工核验或补断言。
4. **未确认 legacy 调色板是否有 DB 迁移/测试锁定**（S2），该问题跨越设置页与数据层，不在本审计范围的写权限内。
5. **`docs/requirements.md` 为唯一 PRD 依据**；未发现任何"设计契约"文档（`docs/ui-refactor-contract.md` 存在但未在本次范围内通读），因此 C9/C13/C14 这类"无 PRD 依据"的判定只表示"PRD 未要求"，不等于"规约未要求"。
