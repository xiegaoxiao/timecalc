# TimeCalc 开源项目借鉴清单

> 调研日期：2026-08-05
>
> 复核规则：实际采用项在引入或升级前重新核实；超过 90 天的调研记录不得单独作为重要依赖决策依据
>
> 用途：记录 TimeCalc 在产品设计、Flutter 桌面工程、本地数据、进度反馈和 AI 排程方面值得借鉴的开源项目。

## 1. 使用原则

本清单用于学习成熟项目的产品思路和工程实践，不代表 TimeCalc 将直接 Fork、依赖或复制这些项目。

- 优先借鉴问题拆解、交互流程、数据边界、测试策略和发布体系。
- 引入第三方依赖前，必须重新检查维护状态、平台支持、许可证和已知问题。
- 复制代码前，必须确认许可证兼容性并保留要求的版权和许可证声明。
- 不因参考成熟项目而扩大 MVP；所有实现仍以 [产品需求文档](requirements.md) 的 P0/P1/P2 范围为准。
- 不复制项目名称、品牌资产、插图、截图、文案或具有明显辨识度的视觉设计。

## 2. 推荐项目总览

| 项目 | 主要用途 | 技术/许可证 | 借鉴优先级 |
|---|---|---|---|
| [Mhabit / Table Habit](https://github.com/FriesI23/mhabit) | 本地优先、热力图、导入导出、跨平台发布 | Flutter / Apache-2.0 | 高 |
| [Super Productivity](https://github.com/super-productivity/super-productivity) | 今日任务、时间盒、延期、托盘与快捷操作 | TypeScript / MIT | 高 |
| [LocalSend](https://github.com/localsend/localsend) | Flutter 桌面工程、CI、打包、国际化 | Flutter / Apache-2.0 | 高 |
| [Drift](https://github.com/simolus3/drift) | SQLite、事务、migration、响应式查询 | Dart / MIT | 高 |
| [Riverpod](https://github.com/rrousselGit/riverpod) | 异步状态、依赖注入、状态隔离与测试 | Dart / MIT | 高 |
| [DeyWeaver](https://github.com/Deyweaver/DeyWeaver) | AI 日程生成和智能排程交互 | TypeScript / MIT | 中 |
| [AppFlowy](https://github.com/AppFlowy-IO/AppFlowy) | 大型 Flutter 桌面架构和复杂交互 | Flutter / AGPL-3.0 | 中，阅读为主 |
| [flutter_gantt](https://github.com/insideapp-srl/flutter_gantt) | P2 甘特图组件与时间轴交互 | Flutter / BSD-3-Clause | 低，需求确认后再评估 |

Star 数和活跃度会变化，不作为唯一选择依据。优先级表示对 TimeCalc 当前阶段的参考价值，不代表项目质量排名。

## 3. 重点借鉴项目

### 3.1 Mhabit / Table Habit

仓库：[FriesI23/mhabit](https://github.com/FriesI23/mhabit)

这是目前与 TimeCalc 产品原则最接近的 Flutter 项目：本地优先、无账号、注重隐私，同时覆盖 Windows、macOS、Linux、Android 和 iOS。

值得借鉴：

- 热力图、成长趋势与完成反馈如何服务日常使用，而不是单纯堆叠统计图表。
- SQLite 本地存储、JSON 导入导出、备份和恢复的完整用户流程。
- Windows MSIX、Microsoft Store、Scoop 等发布渠道的组织方式。
- 多平台文件选择、路径管理、通知、时区和安全存储的兼容处理。
- 深浅色主题、国际化、RTL 和无账号隐私产品的 README 表达方式。
- 自动化测试、代码生成、CI 和 Release 工作流的组织方式。

不应照搬：

- 习惯连续打卡和评分模型不等同于截止日期计划，不应直接成为 TimeCalc 的目标进度算法。
- 项目依赖较多，TimeCalc MVP 不应一次引入其全部 UI、同步和发布依赖。
- WebDAV 同步属于 TimeCalc P2，首版只需要借鉴其数据边界和备份格式设计。

建议行动：实现热力图、备份恢复、跨平台路径或 Windows 打包前，针对性阅读相应模块；不要以整个仓库为应用模板。

### 3.2 Super Productivity

仓库：[super-productivity/super-productivity](https://github.com/super-productivity/super-productivity)

虽然不是 Flutter 项目，但它在个人任务执行和桌面生产力流程上比普通 Todo 示例成熟得多。

值得借鉴：

- 工作视图如何突出当前任务和下一步行动。
- 任务预估、时间盒、计时和工作总结之间的关系。
- 子任务、项目、标签和日历集成如何避免破坏快速操作。
- 未完成任务、延期任务和计划变更的交互语义。
- 键盘快捷键、托盘、桌面通知和本地数据管理。
- 无账号、隐私优先产品如何提供可选同步，而不让同步成为核心功能前置条件。

不应照搬：

- 它面向通用工作管理，功能密度远高于 TimeCalc MVP。
- Jira、GitHub、CalDAV、插件和计时报告等集成暂不符合 TimeCalc 核心范围。
- 只能借鉴产品流程和信息架构，不能把 TypeScript/Electron 实现直接映射成 Flutter 架构。

建议行动：设计“今天”页、任务延期、快捷添加和托盘流程时进行竞品走查，并记录 TimeCalc 为降低复杂度而主动删除的步骤。

### 3.3 LocalSend

仓库：[localsend/localsend](https://github.com/localsend/localsend)

LocalSend 业务与 TimeCalc 不同，但它是成熟度很高的 Flutter 跨平台桌面应用，适合作为工程和发布参考。

值得借鉴：

- 多平台目录结构与平台差异的隔离方式。
- Windows、macOS、Linux 和移动端的构建及 Release 自动化。
- 版本号、变更日志、签名、安装包和发布资产管理。
- 国际化、主题、响应式布局和桌面窗口适配。
- 面向开源贡献者的 Issue、Pull Request、CI 和文档组织。

不应照搬：

- 网络发现和文件传输架构与 TimeCalc 无关。
- 不应为追求跨平台完整度而提前开发非 Windows 平台。

建议行动：在 M4 发布候选阶段对照其 CI、Release 和 Windows 安装包流程，而不是在业务开发初期复制其工程复杂度。

### 3.4 Drift

仓库：[simolus3/drift](https://github.com/simolus3/drift)

Drift 是 TimeCalc 计划采用的数据持久化组件，应优先参考官方示例和测试，而不是从第三方应用推断正确用法。

值得借鉴：

- 类型安全表定义、关联查询和响应式查询流。
- 数据库事务，特别是 AI 草稿批量应用和恢复合并；整库替换采用「临时库校验 + 原子替换」而不是把文件替换误当作数据库事务。
- schema version、migration strategy 和 migration 测试。
- Windows 下 SQLite FFI 的初始化、连接生命周期和并发规则。
- DAO/Repository 边界与内存数据库测试。

TimeCalc 必须落实：

- 目标删除、任务延期、AI 草稿应用等多表写入使用事务。
- 每次 schema 变更都提供 migration、升级前备份/快照和自动化失败恢复测试。
- 备份恢复先在临时库完成校验，失败时不触碰当前正式数据库。
- 统计尽量由可验证的查询产生，避免在多个状态对象中维护重复计数。

### 3.5 Riverpod

仓库：[rrousselGit/riverpod](https://github.com/rrousselGit/riverpod)

Riverpod 应用于状态和依赖管理，不应承担数据库或业务规则本身。

值得借鉴：

- Provider 按功能模块组织，避免建立全局万能状态对象。
- Repository、时钟、网络状态和 AI Provider 的依赖注入。
- `AsyncValue` 的加载、空数据、失败和重试状态表达。
- Provider override 与业务逻辑测试。
- 页面离开后的生命周期和资源释放。

TimeCalc 建议边界：

- 数据事实保存在 Drift；Riverpod 订阅并组合数据。
- 排程、负载和倒计时规则放在可单元测试的纯 Dart service 中。
- Widget 只负责展示状态和发送用户意图，不直接执行 SQL 或调用 AI。

## 4. 特定能力参考

### 4.1 AI 排程：DeyWeaver

仓库：[Deyweaver/DeyWeaver](https://github.com/Deyweaver/DeyWeaver)

可参考任务输入、日程生成和人工调整之间的流程。TimeCalc 的实现必须继续遵守 PRD 中的限制：AI 只生成草稿，输出经过结构校验和负载校验，用户确认后才通过单次事务落库。

不要直接借用其提示词作为 TimeCalc 的核心资产。提示词必须围绕 TimeCalc 自己的目标、截止日、每日可用时长和不可用日期设计，并建立测试样例和版本号。

### 4.2 大型桌面应用架构：AppFlowy

仓库：[AppFlowy-IO/AppFlowy](https://github.com/AppFlowy-IO/AppFlowy)

可研究复杂 Flutter 桌面界面的模块划分、窗口管理、编辑状态和大型项目协作方式。

AppFlowy 体量远超 TimeCalc，且采用 AGPL-3.0。TimeCalc 当前使用 MIT License，因此默认只阅读其公开实现和架构思路，不复制其代码。任何代码级复用必须先单独进行许可证评估。

### 4.3 甘特图：flutter_gantt

仓库：[insideapp-srl/flutter_gantt](https://github.com/insideapp-srl/flutter_gantt)

可在 P2 甘特图正式进入版本计划后，评估其拖动、滚动时间轴、层级活动和自定义构建能力。

引入前需要验证：

- Windows 鼠标、触控板和高 DPI 下的交互。
- 1,000 条以上任务的滚动和重绘性能。
- 键盘操作与屏幕阅读器支持。
- 日期边界、缩放范围和任务更新回调是否满足 TimeCalc 数据模型。

在 MVP 阶段不引入该依赖，避免甘特图挤占今日任务闭环的开发资源。

## 5. 功能与参考项目映射

| TimeCalc 能力 | 首选参考 | 重点观察 |
|---|---|---|
| 今天页与快速执行 | Super Productivity | 信息优先级、完成、延期、快捷操作 |
| 热力图与完成反馈 | Mhabit | 无任务、少数据、连续使用和深色主题状态 |
| 本地数据与 migration | Drift | 事务、查询、升级测试、Windows FFI |
| 状态管理 | Riverpod | 依赖边界、异步状态、测试替换 |
| 备份与恢复 | Mhabit + Drift | 文件版本、预览、校验、覆盖前安全副本 |
| Windows 打包与发布 | LocalSend + Mhabit | CI、安装包、版本号、Release 资产 |
| 托盘与桌面体验 | Super Productivity | 关闭语义、托盘菜单、通知、快捷键 |
| AI 计划草稿 | DeyWeaver | 输入收集、草稿预览、人工调整 |
| 大型 Flutter 架构 | AppFlowy | 模块划分和复杂交互，避免复制体量 |
| P2 甘特图 | flutter_gantt | 拖动、时间轴、性能、可访问性 |

## 6. 许可证边界

TimeCalc 当前计划采用 MIT License。参考或引入其他开源项目时遵循以下规则：

| 许可证 | 默认处理方式 |
|---|---|
| MIT / BSD-3-Clause | 可在满足版权和许可证声明要求后使用或修改代码 |
| Apache-2.0 | 可使用，但需保留许可证、版权和 NOTICE 要求，并关注专利条款 |
| GPL-3.0 / AGPL-3.0 | 默认仅作研究参考，不复制代码；确需使用时先评估是否需要调整整个项目的分发许可证 |
| 未声明许可证 | 不复制、不修改、不分发代码，只可阅读公开页面了解产品思路 |

第三方 Dart/Flutter 包应由依赖管理工具引入，并在发布包或关于页面中提供第三方许可证信息。许可证判断以实际使用版本仓库中的 `LICENSE`、`NOTICE` 和依赖条款为准，不能只依据 GitHub 搜索结果。

## 7. 实施建议

1. M1 数据层优先阅读 Drift 官方文档和示例，建立 migration 测试模板。
2. M2 今天页以 Super Productivity 为产品参考，以 Mhabit 为 Flutter 交互参考，但保持 TimeCalc 更轻量。
3. M3 备份、热力图和 Windows 发布分别对照 Mhabit 与 LocalSend 的实现和发布流程。
4. AI 功能进入开发前，先形成自己的输入 schema、输出 schema、失败样例和负载校验，不从其他项目直接复制提示词。
5. 每次实际引入第三方代码或依赖时，在 Pull Request 中记录项目、版本、用途、许可证和替代方案。

## 8. 后续维护

在以下时点更新本清单：

- 引入或移除重要第三方依赖。
- 某参考项目停止维护、改变许可证或不再支持 Windows。
- TimeCalc 的 MVP 范围或技术栈发生变化。
- 开始开发同步、甘特图、AI 或移动端等后续能力。

调研信息具有时效性，采用任何实现前都应重新核实项目最新状态。
