# TimeCalc 撞色 UI/UX 重构 · 验收报告

> 日期：2026-10-05
> 范围：全局设计系统 + 6 大主页面 + 共享组件/对话框/设置/备份
> 设计依据：[ui-refactor-contract.md](ui-refactor-contract.md)（v2.1，已冻结）

## 1. 结论

**通过。** 撞色设计语言已在真机落地并逐页目视验证；静态检查零 issue；
全量测试 **926 通过 / 3 失败**，3 条失败与重构前基线**同名同因**（纯既有问题），
无新增回归；对比度测试 **160 条断言全绿**。

| 门禁 | 结果 | 证据 |
|---|---|---|
| `flutter analyze lib` | ✅ No issues found | 2026-10-05 复跑 |
| 全量 `flutter test` | ✅ 926 / 3（基线 818 / 3） | 3 条失败同基线 |
| 对比度 `contrast_test` | ✅ 160/160（5 方案 × 明暗 × 16 色对） | ≥4.5:1，最紧 4.66:1 |
| 真机视觉（6 主页面 + 外观页） | ✅ 见 `docs/ui-refactor-shots/` | 浅色 + 深色色板均验证 |
| 功能语义（文案/Key/回调/provider） | ✅ 未改动 | 各页面代理逐项自查 + 测试锁定 |
| 数据库 schema / 业务逻辑 | ✅ 未改动（schemaVersion 仍 18） | 仅改列默认值 |

## 2. 交付内容

### 2.1 设计系统（Lead 冻结）

「**暖橙 × 冷藏青**」互补撞色：暖＝品牌主动作、冷＝数据/统计、点缀＝青柠成就、
危险＝逾期/删除。底色由冷灰改**暖奶油**（`#FDF6F0`），卡片纯白，撞色块浮于白卡。

- `lib/core/theme/app_tokens.dart` — 撞色三主色 + 中性暖色阶 + 圆角/间距/暖调投影/动效档位
- `lib/core/theme/accent_palette.dart` — 撞色方案三元组（暖/冷/点缀 × 浅深两套 + 容器配对）；
  注册 5 套：`clash`（默认）/`electric`/`violet` + legacy `green`/`blue`
- `lib/core/theme/app_theme.dart` — **由 `fromSeed` 改为显式构造 `ColorScheme`**：
  `surface` 即页面底色（使对比度断言 == 用户真实所见），并把「主色填充」与
  「主色图标/文字」拆成两个角色（修复深色模式实心按钮白字仅 2.27:1 的真实缺陷）
- `lib/core/theme/app_semantic_colors.dart` — 语义色在暖奶油底上复验
- 新增撞色组件层：`clash_tones.dart`（角色解析 / `tint` / `blend` / `fillHover` /
  `chartSeries` / 渐变）、`clash_hero.dart`、`clash_widgets.dart`
  （`ClashSectionHeader` / `ClashStatTile` / `ClashChip` / `ClashEmptyState`）

### 2.2 页面与组件（8 个并行工作流）

外壳侧栏与标题栏、今天页、计划/日历 + 草稿对话框、课表页、目标模块（列表/详情/科目/里程碑）、
进度页（2 图表 + 热力图 + KPI）、共享组件 + 设置 + 备份、任务组件与全部任务对话框。

集成期由 Lead 直接修复的横切问题：

| 问题 | 处理 |
|---|---|
| `ClashChip` 无截断能力 → 超长目标名溢出 55px | 新增可选 `flexible` / `maxWidth` |
| `ClashStatTile` 内部 Row 占满行宽 → `Wrap` 里永远一块一行 | 新增可选 `dense` / `maxWidth` + 踩坑文档 |
| `AppDialog` 图标底只有暖色、无 tone | 新增可选 `tone`（默认暖，向后兼容） |
| 侧栏 `SingleChildScrollView` 造成双 Scrollable → 全站 `scrollUntilVisible` 失效 | 改为 `ClipRect + OverflowBox`（不产生 Scrollable） |
| 今天页 hero 与倒计时卡倒计时文案重复 / 2× 字号溢出 12px | 由 today-dev 按 Lead 定位修复 |
| 目标页 500×400 首卡被挤出视口 | `dense` + 限宽横排 + compact padding |

## 3. 真机视觉验证

`flutter build windows --debug` → 运行 → ffmpeg gdigrab 截图为「今天 / 计划 / 课表 /
目标 / 进度 / 设置 / 外观」共 7 张（`docs/ui-refactor-shots/`）。

确认要点：

- **今天页**：暖→冷双撞色 hero 渐变 + 大号倒计时；四色统计块（暖实心/冷实心/冷浅底/点缀实心）；
  任务行撞色竖条 + 撞色元信息药丸；danger 逾期横幅。
- **计划页**：今天＝暖实心徽标 + 2px 暖描边；选中＝冷藏青浅底；事件块按目标稳定映射撞色序列；
  右侧面板任务药丸。
- **课表页**：撞色 hero + 暖色实心「本周」压在渐变冷端；当日列冷色底；暖色当前时间线；
  课程色仅作辨识（竖条 + 底纹）未统一成撞色。
- **目标页**：状态→撞色（进行中暖 / 已完成青柠 / 逾期危险）；进度环与进度条随状态换色。
- **进度页**：三色 KPI；燃尽图暖色曲线 + 青柠「今日节点」；热力图冷色单色阶。
- **设置/外观页**：图标底按语义分配暖/冷/青柠/危险；3 套撞色方案可切；预览卡同时展示
  浅色（暖奶油）与深色（暖黑 `#17120F`）双色板 → **深色撞色亦已验证**。

## 4. 已知问题与遗留

### 4.1 既有失败（3 条，与本次重构无关，基线即红）

- `progress_page_test.dart: 新增任务后剩余工作量趋势与任务耗时图及时刷新（回归）`
- `today_page_test.dart: 今日页可快速添加任务（目标下拉默认首个进行中目标）`
- `today_page_test.dart: 空态快捷添加后今日列表立即出现新任务（回归：await 后刷新）`

### 4.2 需要用户决策：老用户的色系偏好

本机库内 `accent_color = blue`（用户旧选择），因此**老用户打开应用仍看到旧的
专业藏蓝，而不是新撞色**。这是刻意设计（不改写用户已保存的偏好）：
`tables.dart` 的**当前**默认值已改为 `clash`（只影响全新安装/新增行），而历史
迁移步骤保持 `DEFAULT 'green'`（迁移步骤是历史产物，不得改写）。
外观页对 legacy 值做「追加当前项为选中项 + 说明文字」的归一显示。

若希望老用户也进入新撞色语言，需要显式决定是否**迁移改写**存量 `green`/`blue`
（会覆盖用户已保存偏好），本次未做。

### 4.3 其他观察（非本次范围）

- **燃尽图轴标签与点位不符（既有缺陷）**：当最晚截止日距今不足 14 天时，
  窗口补足到 14 天，`points.last` 并非截止日，但最右端刻度无条件打印截止日。
  已在报告中留档，未改图表逻辑（超出纯表现层重构范围）。
- **外观页色系选项排版**：`SegmentedButton` 三项标签较长，横向拉满后标签居中、
  左侧留白偏多，观感不够精致；建议后续改为「左对齐 + 色点在前」的自定义行。
- **KPI 大数字失去 tabular figures**（`ClashStatTile` 无 `fontFeatures` 参数），
  数值变化时可能有 1px 级抖动。
- **`pre-plan_draft_dialog.dart.orig` 等 `.orig` 残留**为重构前既有文件，建议清理。
- 「幽灵 300px 溢出」在最终全量测试中**不再复现**（当时处于多代理并发写入的中间态）。

### 4.4 数据安全

视觉验证期间曾临时接管本机数据库做截图（播种样例数据 + 切到 clash 色系），
**已完整回滚**：从 `timecalc.sqlite.pre-uiverify` 恢复，校验 `accent_color = blue`、
业务表为空、文件大小与原始一致（442368 bytes）。

## 5. 新增开发工具（可选保留）

- `tool/clash_palette_solver.dart` — 撞色色值求解（对比度约束下自动求深/求亮）
- `tool/db_tool.dart` — `inspect` / `ddl` / `set-accent` / `seed`，用于真机视觉验收
  （⚠️ `seed` 会清空业务表，仅在确认无真实数据时使用）
