# TimeCalc 时间计算器

TimeCalc 是一款本地优先的个人目标与截止日期管理工具，帮助用户把长期目标转换为今天可以执行的任务。

项目当前处于产品定义和 Windows MVP 规划阶段，尚未发布可用版本。

## 产品方向

- 目标倒计时与里程碑
- 今日任务与日历排程
- 工作量和计划风险提示
- 本地数据存储与备份恢复
- 可选的 AI 计划草稿生成
- Windows 托盘与精简悬浮窗

完整需求和版本范围见 [产品需求文档](docs/requirements.md)。产品与工程参考见 [开源项目借鉴清单](docs/open-source-references.md)。

## 计划技术栈

- Flutter / Dart
- SQLite + drift
- Riverpod
- GoRouter

技术栈仍可能在首个工程里程碑开始前调整，产品验收以数据正确性和用户流程为准。

## 项目状态

当前阶段：M1「数据与目标闭环」已完成，进入 M2「每日执行闭环」规划。

已完成（M1）：

- Flutter Windows 工程与架构骨架（drift + Riverpod + GoRouter）。
- 目标、科目、任务的数据模型、数据库迁移与数据访问层。
- 目标 CRUD 与删除二次确认、今天页倒计时卡片、任务与科目 CRUD。
- 关键边界测试与 Windows 构建冒烟验证通过。

下一里程碑（M2）：

1. 今天页完整闭环：今日任务列表、完成/延期。
2. 日历视图与每日负载提示。
3. 负载计算与目标剩余工作量展示。

里程碑验收记录见 [docs/milestone-records/](docs/milestone-records/)。

## 项目文档

文档以 [产品需求文档](docs/requirements.md) 为需求基线；SOP 定义流程，检查清单用于执行和留存证据。

- [产品需求文档](docs/requirements.md)
- [开源项目借鉴清单](docs/open-source-references.md)
- [开发全流程 SOP](docs/development-sop.md)
- [开发检查清单](docs/checklists.md)
- [贡献指南](CONTRIBUTING.md)
- [行为准则](CODE_OF_CONDUCT.md)

## 参与贡献

欢迎通过 Issue 提交问题、产品建议和实现提案。开始开发前，请先阅读 [贡献指南](CONTRIBUTING.md) 和 [行为准则](CODE_OF_CONDUCT.md)。

为了减少返工，较大的功能变更应先通过 Issue 对范围和交互达成共识。

## 许可证

本项目使用 [MIT License](LICENSE)。
