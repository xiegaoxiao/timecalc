# 计划页三视图设计：周视图（格子）· 月视图 · 年视图（12 月网格）

> 状态：设计稿（待评审）｜ 关联：PRD FR-3（任务与日历）｜ 参考：滴答清单（TickTick）日历视图
> 日期：2026-08-14

## 1. 背景与目标

当前计划页（`PlanPage` → `CalendarView`）**只有月视图**：手写月历网格 `_MonthGrid`（周一开头）+ 选日任务面板 `_DayPanel`。用户希望补充**周视图、年视图**，并参考滴答清单的交互。

目标：

1. **周视图（格子样式）**：7 列网格展示当周 7 天，聚焦一周内的任务安排；
2. **月视图**：保留现有能力，补充滴答式增强（隐藏已完成、回到今天更醒目）；
3. **年视图（12 月网格概览）**：3×4 十二个月格，每月显示完成数/负载强度，点击跳转对应月视图；
4. **视图切换器**：周 / 月 / 年三态切换 + 上下文头部（当前周/月/年 + 前后切换 + 「今天」）。

非目标（本期不做）：

- 滴答「时间轴样式」周视图（需任务新增开始/结束时间字段，属另一量级改动，见 §7 后续迭代）；
- 跨天任务、时间段任务、全天任务；
- 双指缩放（桌面端无触控板场景优先级低）。

## 2. 滴答清单调研要点

来源：滴答清单官方帮助中心（周视图 / 月视图 / 年视图三篇）与功能介绍页。

### 2.1 周视图

- **桌面端**：全天任务栏（未设置时间/全天/跨天任务）+ 竖向时间轴（设置了时间的任务按时段排布）；左右箭头或键盘方向键切周；「今天」回本周；拖动任务块改期、拖块边缘调时长。
- **移动端另有两种样式**：
  - 时间轴样式（同桌面）；
  - **格子样式**：八宫格——第一格是迷你月历（提示当前周处于本月第几周），其余 7 格为一周 7 天，对应日期任务显示在格内。
- 无日期任务可在「安排任务」栏集中拖入日历。

> 本项目任务无「开始/结束时间」字段，时间轴样式需先扩展数据模型；格子样式与现有月视图网格同构，**作为本期周视图形态**。

### 2.2 月视图

- 整月网格全局概览；上下滑动切月；双指捏合缩放显示周数（多周视图）；
- 长按起始日拖动到结束日 → 创建跨天任务；
- 右上角「···」可筛选清单、隐藏已完成、显示设置。

### 2.3 年视图

- 从全局视角看一年任务完成情况，**热力图分布**（颜色越深完成越多）；
- **点击月份 → 跳转对应月视图；点击日期 → 跳转周视图并高亮**；
- 视图切换：左上角视图图标选「年」，或快捷键 Y/4；
- 仅显示已设置日期的任务；默认热力图关闭，可在显示设置中开启。

### 2.4 对本项目的取舍

| 滴答能力 | 本项目取舍 | 原因 |
|---|---|---|
| 周视图时间轴 | 不做（本期） | 需新增任务时间字段 |
| 周视图格子样式 | **采用** | 与现有 `_MonthGrid` 同构，改动小 |
| 月视图跨天任务 | 不做 | 数据模型无跨天概念 |
| 年视图热力图 | **简化为 12 月完成强度网格** | 进度页已有 26 周热力图（`completedTasksByLocalDate` + `heatLevel`），年视图做「月粒度」概览避免重复 |
| 年视图点击跳月 | **采用** | 下钻语义清晰 |
| 视图切换器 | **采用**（顶部 `SegmentedButton`） | 桌面端最直观 |

## 3. 现状分析

### 3.1 可复用（已具备）

| 资产 | 位置 | 用途 |
|---|---|---|
| 手写月历网格 `_MonthGrid` | `calendar_view.dart` | 单元格三态视觉（选中/今天/有任务）、不可用星期置灰、负载聚合展示 |
| 负载聚合 `LoadService.calendarAggregate` | `services/load_service.dart` | 每日完成数/总时长/超出分钟 |
| 月任务查询 `tasksByMonthProvider` | `task_repository_provider.dart` | 按 `yyyy-MM` 查整月任务 |
| 日任务查询 `tasksByDateProvider` | 同上 | 选日面板 |
| 日期范围查询 `TaskRepository.byDateRange` | `task_repository.dart` | **周视图数据源**（按周一~周日查询） |
| 完成统计 `StatisticsService.completedTasksByLocalDate` | `services/statistics_service.dart` | 年视图完成数（按完成日期归日） |
| 热力分档 `StatisticsService.heatLevel` | 同上 | 年视图月格强度配色 |
| 选日面板 `_DayPanel` | `calendar_view.dart` | 三视图共用（点击任意日期下钻当日任务） |
| 拖拽改期 `_handleTaskDropped` | `calendar_view.dart` | 周/月视图网格 DragTarget 复用 |

### 3.2 缺口（需新增）

| 缺口 | 说明 |
|---|---|
| 周任务查询 provider | `tasksByWeekProvider`：按周一起点 ~ 周日终点调 `byDateRange` |
| 年完成统计 provider | `tasksByYearProvider`：按年查全部任务（或按年完成区间查），供月格统计 |
| 视图切换状态 | `CalendarView` 内部枚举 `_CalendarViewMode { week, month, year }`（页面级 state，不入库） |
| 周网格组件 | `_WeekGrid`：7 列网格，逻辑同 `_MonthGrid`，日期范围=当周 |
| 年网格组件 | `_YearGrid`：3×4 月格，每格显示完成强度 + 点击跳月 |
| 头部组件泛化 | `_MonthHeader` → 泛化为 `_CalendarHeader`（视图标题 + 前后切换 + 今天） |

## 4. 总体设计

### 4.1 页面结构（`CalendarView` 改造后）

```
CalendarView (ConsumerStatefulWidget)
├─ _CalendarHeader          # 视图切换器 + 标题 + 前后切换 + 回到今天
│   ├─ SegmentedButton<视图>  # 周 / 月 / 年
│   ├─ 标题: 「2026年8月」 / 「2026年第33周」 / 「2026年」
│   ├─ ◀ 上一单元 ▶          # 前一月/周/年、后一月/周/年
│   └─ 「今天」(非当前单元时显示)
├─ [周] _WeekGrid           # 7 列，当前周
├─ [月] _MonthGrid          # 现有实现，保持
├─ [年] _YearGrid           # 3×4 月格
├─ Divider
└─ _DayPanel                # 选日面板（三视图共用，点日期/点月下钻后固定）
```

- 三视图切换用 `AnimatedSwitcher`（沿用现有月切换淡入淡出，keyed by 视图+单元）。
- **选日面板始终保留**：三视图点击日期 → 下方面板展示当日任务（交互与现状一致），年视图点月格则**切换视图到月视图**（滴答语义：年→月下钻）。

### 4.2 状态

```dart
enum _CalendarViewMode { week, month, year }

// state:
late _CalendarViewMode _mode;
late DateTime _month;          // 月视图当前月（现状）
late DateTime _weekStart;      // 周视图当前周（周一）
late int _year;                // 年视图当前年
late String _selectedDate;     // 选中日（现状，三视图共用）
```

- 视图切换保留各自单元位置（切走再切回不丢）；「今天」回到当前视图的当前单元并选中今天。

## 5. 周视图（格子样式）详细设计

### 5.1 布局

```
┌────────────────────────────────────────────┐
│ 一  二  三  四  五  六  日      ← 星期表头    │
├────┬────┬────┬────┬────┬────┬────┤
│ 28 │ 29 │ 30 │ 31 │ 1  │ 2  │ 3  │ ← 日期格
│ 2/3│ 1/2│ 0/1│    │ 3/5│    │ 1/1│   (完成数/总数)
│ 2h │    │    │    │ 3h │    │    │   (负载/超出)
└────┴────┴────┴────┴────┴────┴────┘
```

- 7 列 × 1 行，每列对应周一到周日；
- 单元格视觉完全复用 `_MonthGrid._buildCell` 三态逻辑（选中/今天/有任务）+ 不可用星期置灰 + 负载聚合；
- 跨月的周：日期来自相邻月，格内显示真实日期号（不加灰，滴答同样显示）。

### 5.2 数据

```dart
/// 周任务：按周一 ~ 周日查询（跨月安全）。
final tasksByWeekProvider = FutureProvider.family<List<Task>, String>((ref, weekKey) {
  // weekKey = '2026-W33' 或直接用周一日期 'yyyy-MM-dd'；解析出周一后调 byDateRange(周一, 周日)
});
```

- `CalendarView` watch `tasksByWeekProvider(_weekKey)`，聚合复用 `LoadService.calendarAggregate`（与月视图同口径）。
- 周视图不新增 provider 表结构，纯查询层。

### 5.3 交互

| 交互 | 行为 |
|---|---|
| 点日期格 | 选日面板展示当日任务（现有 `_DayPanel` 复用） |
| 拖任务到格子 | 改期（现有 `_handleTaskDropped` 复用，DragTarget 挂格上） |
| ◀ ▶ | 切换上一周/下一周；标题显示「2026年第33周」 |
| 今天 | 回到本周并选中今天 |
| 换周 | `AnimatedSwitcher` 淡入淡出（keyed by weekKey） |

## 6. 月视图（增强）

现状已满足 FR-3.4/3.5。本期仅增强：

1. **头部泛化**：`_MonthHeader` → `_CalendarHeader`，月视图行为不变（标题「2026年8月」、上一月/下一月、今天）；
2. **隐藏已完成**（可选，滴答 2.2）：月网格右上角「···」→ 显示设置 → 隐藏已完成任务，仅影响月视图单元格统计展示（`aggregate` 计算前过滤 `status == done`）。作为增强项，若首版范围紧张可裁剪。

## 7. 年视图（12 月网格）详细设计

### 7.1 布局

```
┌──────────┬──────────┬──────────┬──────────┐
│  2026年1月  │  2026年2月  │  2026年3月  │  2026年4月  │
│  ●●○○     │  ●●●      │  ○○○      │  ●●       │
│  12 完成   │  18 完成   │   3 完成   │   9 完成   │
├──────────┼──────────┼──────────┼──────────┤
│  5月 …    │  6月 …    │  7月 …    │  8月 …    │
├──────────┼──────────┼──────────┼──────────┤
│  9月 …    │  10月 …   │  11月 …   │  12月 …   │
└──────────┴──────────┴──────────┴──────────┘
```

- 3×4 网格（`GridView` 或 `Wrap`），每格：
  - **月份标题**（点击 → 切到月视图该月）；
  - **完成强度指示**：5 档色点行（复用 `StatisticsService.heatLevel` 语义，按当月完成数分档，`_heatColors` 风格色板）；
  - **完成数**：`本月完成任务 N`（文本，NFR-4 不只依赖颜色）。
- 未到月份（未来月）正常显示（完成 0），当前月高亮边框。

### 7.2 数据

```dart
/// 年视图：按年取全部任务（含完成/未完成），统计在 provider 内完成一次。
final tasksByYearProvider = FutureProvider.family<List<Task>, int>((ref, year) {
  // byDateRange('yyyy-01-01', 'yyyy-12-31')
});

/// 年完成统计：按月分组完成数（依赖 tasksByYearProvider）。
final yearCompletionProvider = Provider.family<Map<int, int>, int>((ref, year) {
  final tasks = ref.watch(tasksByYearProvider(year)).valueOrNull ?? const [];
  // 按 completedAt.toLocal() 归月，status == done 计入
});
```

- 复用 `completedTasksByLocalDate` 的归日逻辑（改归月）或新增 `completedTasksByMonth` 到 `StatisticsService`（保持纯计算可测）。

### 7.3 交互

| 交互 | 行为 |
|---|---|
| 点月格 | 切到月视图并定位该月（滴答语义：年 → 月下钻） |
| ◀ ▶ | 上一年/下一年；标题「2026年」 |
| 今天 | 回当前年 |
| 完成数为 0 的月 | 显示「0 完成」灰字，不可点语义不变（仍可跳月） |

## 8. 数据层改动清单

| 文件 | 改动 |
|---|---|
| `lib/features/tasks/data/task_repository_provider.dart` | 新增 `tasksByWeekProvider`、`tasksByYearProvider` |
| `lib/services/statistics_service.dart` | 新增 `completedTasksByMonth(List<Task>) → Map<int(月), int>`（纯函数 + 单测） |
| 无 schema 迁移 | 三视图纯查询/展示层，不动数据库结构（时间轴周视图才需迁移，见 §10） |

## 9. 组件拆分建议

`calendar_view.dart` 现约 700 行（月网格 + 选日面板 + 头部），三视图后建议按文件拆分（每文件职责单一）：

| 新文件 | 内容 |
|---|---|
| `features/plan/presentation/calendar_view.dart` | 视图壳：状态、头部、三视图切换、选日面板装配（保留现有 `_DayPanel`、拖拽逻辑） |
| `features/plan/presentation/calendar_header.dart` | `_CalendarHeader`（视图切换器 + 标题 + 前后 + 今天） |
| `features/plan/presentation/calendar_week_grid.dart` | `_WeekGrid`（7 列） |
| `features/plan/presentation/calendar_month_grid.dart` | `_MonthGrid`（现文件迁出，含单元格 `_buildCell` 抽为共用） |
| `features/plan/presentation/calendar_year_grid.dart` | `_YearGrid`（3×4） |
| `features/plan/presentation/calendar_day_panel.dart` | `_DayPanel` + `_SectionError`（迁出） |

共用单元格逻辑（三态视觉/置灰/聚合展示）抽为 `CalendarDayCell` 组件，周/月网格共用。

## 10. 后续迭代（不在本期）

- **时间轴周视图**：需 schema 迁移给任务加 `start_time` / `end_time`（或 `all_day` + 跨天 `start_date/end_date`），涉及任务表单、详情、备份 schema、WebDAV 同步版本，独立里程碑。
- 年视图热力图全样式（52 周 GitHub 式）：进度页已有 26 周实现，如需年粒度可扩展 `completedTasksProvider` 时间窗。
- 月视图跨天任务创建（长按拖选多日）。

## 11. 测试计划

| 层级 | 用例 |
|---|---|
| 纯计算（statistics_service_test） | `completedTasksByMonth`：跨年边界、完成态过滤、无完成返回空 |
| provider（task_repository 相关） | `tasksByWeekProvider` 跨月周（如 2026-08-31 周一落在 8 月但周日 9/6）；`tasksByYearProvider` 全年范围 |
| widget（新增 calendar_views_widget_test） | ① 周视图：显示当周 7 天、跨月周正确、点日期下面板出当日任务、拖拽改期复用；② 视图切换：周↔月↔年保留各自单元、切换后标题正确；③ 年视图：3×4 十二格、月完成数正确、点月格跳到月视图该月；④ 「今天」从任意视图回当前单元 |
| 回归 | 现有 calendar_view_test、progress_page_test 全量保持通过 |

## 12. 里程碑拆分建议

- **M-A（周视图 + 切换器）**：`tasksByWeekProvider` + `_WeekGrid` + `_CalendarHeader`（SegmentedButton + 泛化头部）。验收：周视图渲染当周 7 天、跨月周正确、选日/拖拽/今天可用。
- **M-B（年视图）**：`tasksByYearProvider` + `yearCompletionProvider` + `completedTasksByMonth` + `_YearGrid`（3×4 + 点月下钻）。验收：12 月格完成数正确、点月跳月视图、前后切年。
- **M-C（增强与收尾）**：月视图隐藏已完成（可选）、组件拆分重构、测试补齐、CHANGELOG 记录。
