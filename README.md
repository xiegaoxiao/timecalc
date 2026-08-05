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

当前阶段：Windows MVP 需求基线。

近期计划：

1. 建立 Flutter Windows 工程和基础架构。
2. 实现目标、科目和任务的数据模型。
3. 完成“创建目标 → 安排任务 → 每日执行 → 查看反馈”的 P0 闭环。

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
