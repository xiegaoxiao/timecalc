# TimeCalc 撞色重构 · 设计契约（v2.0，已冻结）

> 本文件是本次 UI/UX 重构的**唯一设计依据**。设计系统层已由 Lead 冻结，
> 所有页面代理必须按此契约改造，不得自行发明色值/圆角/阴影。

## 1. 设计语言

**「暖橙 × 冷藏青」互补撞色**：两套主色互为补色方向，形成**结构性对冲**
而非单色深浅。

| 角色 | 情绪 / 用途 | token |
|---|---|---|
| **暖（warm）** | 品牌、主动作、今日、倒计时、导航选中、当前时间线 | `ClashTone.warm` |
| **冷（cool）** | 数据、统计、图表、课表、日历选中、次要动作 | `ClashTone.cool` |
| **点缀（citrus）** | 里程碑、成就、完成徽标、图表第三序列 | `ClashTone.citrus` |
| **危险（danger）** | 逾期、超载、删除、重置 | `ClashTone.danger` |

底色由冷灰改为**暖奶油**（`AppTokens.neutralBgLight = #FDF6F0`），
卡片保持纯白 —— 「白卡浮于暖奶油底」，撞色块浮于白卡上对比最强。

## 2. 唯一取色入口（必须用）

```dart
import '../../shared/widgets/clash_tones.dart';

final t = ClashTones.of(context, ClashTone.warm);
t.fill;    // 实心填充底（按钮/选中块/徽标底）—— 配 t.onFill 文字
t.onFill;  // 填充上的文字/图标（白字，保证 ≥4.5:1）
t.ink;     // 直接压在页面底/卡片上的文字或图标色（保证 ≥4.5:1）
t.soft;    // 浅色容器底（标签底/内嵌块/选中行）—— 配 t.onSoft 文字
t.onSoft;  // 浅色容器上的文字
t.deep;    // 该撞色的深色变体（渐变深端/描边）

ClashTones.tint(color, alpha: 0.10);      // 统一透明底（hover/选中行）
                                          // 密集导航项用 0.08（二选一，别引第三个数）
ClashTones.fillHover(t.fill);             // 实心块 hover 加深（配 onFill 仍达标）
ClashTones.fillPressed(t.fill);           // 实心块 pressed 再深一档
ClashTones.chartSeries(context);          // 图表三序列撞色（暖/冷/点缀）
ClashGradient.clash(context);             // 暖×冷双撞色渐变（hero）
ClashGradient.header(context);            // 单撞色品牌渐变
ClashGradient.soft(context, tone);        // 柔和渐变（浅底块）
```

### 硬规则

1. **实心色块上必须用 `onFill`，压底文字必须用 `ink`**。深色模式下
   `scheme.primary` 是「填充色」，直接拿它当图标色会导致对比不足 ——
   这正是 Lead 拆分色彩角色的原因，不要绕过。
2. **禁止硬编码颜色**（`Color(0x...)`、`Colors.orange`、`Colors.white`
   用作文字色等）。除 `Colors.white` 配合 `onFill`/hero 渐变外，
   一律从 `ClashTones` / `scheme` / `AppTokens` 取。
3. **禁止写死间距/圆角**：用 `AppTokens.space*` / `AppTokens.radius*`
   （旧代码里的裸数字只在「不改动就会破坏布局」时才保留）。
4. **状态不能只靠颜色**（NFR-4）：新增的任何撞色状态都要保留原有文字/
   图标承载，`Semantics` 标签与 tooltip 一律不得删改。

## 3. 撞色组件库（优先复用，不要重造）

```dart
import '../../shared/widgets/clash_hero.dart';
import '../../shared/widgets/clash_widgets.dart';

// 大面积撞色头图（页面第一眼区块）
ClashHero(
  tone: ClashTone.warm,
  child: Column(children: [...]),
)

// 撞色区块头（撞色竖条 + 撞色图标底 + 标题 + 计数徽标 + 尾部动作）
ClashSectionHeader(
  icon: Icons.check_circle_outline,
  title: '今日待办',
  tone: ClashTone.warm,
  count: 3,
  trailing: IconButton(...),
)

// 撞色统计小块（大号数字 + 标签 + 辅助说明）
ClashStatTile(value: '3', label: '待办', tone: ClashTone.warm, icon: Icons.list)

// 撞色药丸（状态/分类标签）
ClashChip(label: '英语', tone: ClashTone.cool, variant: ClashChipVariant.soft)

// 撞色空态
ClashEmptyState(icon: Icons.inbox_outlined, title: '今天还没有任务',
                message: '...', tone: ClashTone.cool, action: FilledButton(...))
```

其余共享组件：`SectionHeader`（旧签名兼容，新增 `tone` 参数）、
`HoverableCard`、`AppDialog`、`CompletionCheckbox` 等已改为撞色语言，
调用方一般无需改动，**但要检查是否传了硬编码颜色**。

## 4. 主题层已提供的档位（不要覆盖）

`AppTheme._base` 已配置：`filledButton`（暖色实心）、`outlinedButton`
（冷色描边）、`textButton`（冷色文字）、`card`（18px 圆角 + 暖调边框 +
暖投影）、`inputDecoration`（聚焦冷色描边）、`checkbox`/`switch`/`radio`/
`slider`（暖色选中）、`chip`/`segmentedButton`/`tabBar`/`navigationRail`/
`navigationBar`/`dialog`/`snackBar`/`tooltip`/`scrollbar`。
页面直接用组件默认样式即可，**不要再包一层 `styleFrom` 覆盖颜色**。

## 5. 色值参考（已由 `contrast_test` 锁定 ≥4.5:1）

| 用途 | 浅色 | 深色 |
|---|---|---|
| 页面底色 | `#FDF6F0` | `#17120F` |
| 卡片 | `#FFFFFF` | `#201A16` |
| 次级底 | `#F7EDE6` | `#2A2320` |
| 主文字 | `#1C1917` | `#F5EFE9` |
| 次级文字 | `#57534E` | `#C4B8AE` |
| 边框 | `#EADFD7` | `#3A2F28` |
| 暖橙 | `#C63D0F` | `#FF8A4C` / 填充 `#8A3009` |
| 冷藏青 | `#0E6E6B` | `#4FD1C5` |
| 青柠 | `#4D7C0F` | `#BBD65C` |

其它撞色方案（`electric` 电光青×青柠、`violet` 紫罗兰×暖橙）会自动跟随
`ClashTones` 换色 —— 页面**不需要**为某套方案写特例。

## 6. 不可触碰的约束

- **禁止改**：数据库 schema、repository、service、provider、业务规则、
  路由路径、`ValueKey`/`Key`、文案字符串、`Semantics` 标签、交互回调。
- 这是**纯表现层重构**。若发现某处必须改业务逻辑才能达成视觉目标，
  停下来在报告里写清楚，不要自行改。
- **禁止改测试来让测试通过**。测试失败先判断是「颜色断言」还是
  「行为/布局断言」：颜色断言按新契约修正期望值是允许的；行为断言失败
  说明你改坏了功能，必须改代码而不是改断言。已知 3 个**重构前既有失败**
  （与本次无关，不要试图修）：
  - `progress_page_test.dart: 新增任务后剩余工作量趋势与任务耗时图及时刷新（回归）`
  - `today_page_test.dart: 今日页可快速添加任务（目标下拉默认首个进行中目标）`
  - `today_page_test.dart: 空态快捷添加后今日列表立即出现新任务（回归：await 后刷新）`

## 7. 验证方式

```powershell
flutter analyze lib/<你的文件或目录>
flutter test test/<对应测试文件>   # 只跑你自己的测试，禁止跑全量（会与其他代理抢资源）
```

每个代理交付前必须：① `flutter analyze` 自己改的文件零 issue；
② 跑通自己文件对应的测试；③ 报告里给出「改了什么 / 测试结果 / 遗留问题」。

## 8. 已知环境注意

- Windows + Flutter 3.13 SDK（`C:\flutter`）。全量测试约 1 分钟。
- 工作区 `git status` 有 44 个**重构前就存在**的未提交改动，属于基线；
  不要 `git checkout`/`git stash`/`git reset`/`git commit`，也不要靠
  `git diff` 判断自己的改动（基线噪声大）。用 read/edit 精确改文件。
- 若 `write` 报 `FS_STALE_VERSION`，重新 `read` 该文件后重试。
