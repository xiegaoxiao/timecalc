<div align="center">

# ⏱️ TimeCalc 时间计算器

**把长期目标，拆成今天就能执行的事。**

本地优先的个人目标与截止日期管理工具（Windows 桌面）。
目标倒计时 · 今日驾驶舱 · 计划日历 · 学习日负载 · 重复任务（含艾宾浩斯间隔复习）· 进度统计 · 备份与 WebDAV 同步。

[下载 v1.9.0](https://github.com/xiegaoxiao/timecalc/releases) ·
[更新日志](CHANGELOG.md) ·
[产品文档](docs/requirements.md)

[![Release](https://img.shields.io/badge/version-1.9.0-2ea44f)](https://github.com/xiegaoxiao/timecalc/releases)
[![Platform](https://img.shields.io/badge/platform-Windows-blue)]()
[![Framework](https://img.shields.io/badge/framework-Flutter-02569B)]()
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-529%20passing-brightgreen)]()
[![Privacy](https://img.shields.io/badge/privacy-local--first-important)]()

</div>

---

## ✨ 为什么用 TimeCalc

大多数「目标管理」工具帮你设目标，却很少回答一个问题：**今天到底该做什么？**

TimeCalc 把长期目标换算成每天可执行的任务量，并用一张「学习日」的账本告诉你要不要加把劲：

- 一个目标 = 倒计时 + 里程碑 + 科目 + 任务 + 负载预算；
- 「剩余任务时长 ÷ 剩余学习日 = 建议日均」——超出每日可用时长时，提前预警计划风险；
- 任务可以批量排期、按重复规则自动生成，甚至用**艾宾浩斯间隔序列**安排复习；
- 所有数据存本地 SQLite，不依赖云端账号，导出/恢复/多设备同步随时可控。

## ✨ 功能特性

| 模块 | 亮点 |
| --- | --- |
| 🎯 **目标与里程碑** | 截止日倒计时、阶段里程碑（勾选完成）、截止日/学习日双向视角 |
| ✅ **今天驾驶舱** | 目标进度条、今日概览仪表盘、逾期任务集中处理、快捷延期到下一可用日 |
| 📅 **计划日历** | 月历负载热区、按日排程、拖拽改期、历史日期补录 |
| 🔁 **重复任务** | 每天 / 每周指定星期 / 每隔 N 天 / 间隔序列（艾宾浩斯 1,2,4,7,15,30），可扩展规则引擎 |
| ⏱️ **负载与计划风险** | 剩余时长、学习日、建议日均一键算清；超载即预警 |
| 📊 **进度统计** | 燃尽趋势、26 周完成热力图、任务耗时图（fl_chart） |
| 💾 **数据安全** | 一键备份 / 覆盖恢复（自动安全副本）、每日自动备份、**WebDAV 多设备整库同步** |
| 🌗 **明暗主题** | 跟随系统 / 浅色 / 深色，即切即用 |
| 🪟 **桌面体验** | 系统托盘常驻、窗口位置多屏记忆、中文本地化 |
| 🔒 **本地优先** | 数据不出本机；WebDAV 密码存系统凭据库（Windows DPAPI），不进数据库与备份 |

## 🚀 安装

### 免安装便携版（推荐）

1. 前往 [Releases 页面](https://github.com/xiegaoxiao/timecalc/releases) 下载最新版：
   `timecalc-v1.9.0-windows-x64.zip`
2. 解压到任意目录，运行 `timecalc.exe` 即可，无需安装。

### 从源码构建

需要 [Flutter SDK](https://docs.flutter.dev/get-started/install/windows)（3.x）：

```bash
# 调试
flutter run -d windows

# 发布构建
flutter build windows --release

# 一键发布（构建 + 打包 zip + SHA256 校验，见 tool/release.sh）
bash tool/release.sh
```

## 📖 快速上手

应用共四个主页面：

- **今天** —— 打开首页即见「今天该做什么」：目标进度、今日任务、逾期提醒；
- **计划** —— 按月排程：创建目标后，用「批量添加 / 重复任务」一次性铺好未来几周；
- **进度** —— 回答「走得怎么样」：燃尽趋势、完成热力图、任务耗时；
- **设置** —— 关闭行为、外观主题、备份恢复、归档任务、WebDAV 同步。

建议路径：**创建目标 → 设置计划偏好（每日可用时长/每周可用日）→ 排任务 → 看负载预警 → 按节奏执行。**

## 🛠️ 技术栈

| 层 | 选型 |
| --- | --- |
| UI 框架 | Flutter (Windows desktop) |
| 本地数据库 | SQLite + [drift](https://drift.simonbinder.eu/)（schema 化迁移，v12） |
| 状态管理 | Riverpod（全局数据共享，跨页无感刷新） |
| 路由 | GoRouter |
| 图表 | fl_chart（燃尽 / 热力图 / 耗时图） |
| 桌面集成 | window_manager、tray_manager、screen_retriever |
| 凭据安全 | flutter_secure_storage（Windows DPAPI） |
| 备份 / 同步 | archive（zip）+ http（WebDAV 自研薄客户端） |

## 🔐 数据与隐私

- 业务数据（目标 / 科目 / 里程碑 / 任务 / 重复模板 / 检查项）全部存储在本地 SQLite，**不依赖任何云端账号**；
- WebDAV 密码通过系统凭据存储加密保存，**不进入数据库与备份文件**；
- 备份为带版本号的 `.timecalc` 文件，覆盖恢复前自动创建安全副本；
- 需要多设备时可选开启 WebDAV 整库同步（后写者胜），关闭即回到纯本地。

## 📚 项目状态

- **v1.9.0 已发布**（2026-08-09）：全链路 UI 交互打磨，529 项测试通过。
- 里程碑演进（M1~M13）与完整变更记录见 [CHANGELOG.md](CHANGELOG.md) 与 [里程碑记录](docs/milestone-records/)。

## 📂 项目文档

- [产品需求文档](docs/requirements.md) — 需求基线
- [开源项目借鉴清单](docs/open-source-references.md)
- [开发全流程 SOP](docs/development-sop.md)
- [开发检查清单](docs/checklists.md)
- [更新日志](CHANGELOG.md)
- [贡献指南](CONTRIBUTING.md)
- [行为准则](CODE_OF_CONDUCT.md)

## 🤝 参与贡献

欢迎通过 [Issue](https://github.com/xiegaoxiao/timecalc/issues) 提交问题、产品建议与实现提案。开始开发前，请先阅读 [贡献指南](CONTRIBUTING.md) 与 [行为准则](CODE_OF_CONDUCT.md)。

为减少返工，较大的功能变更建议先通过 Issue 对范围与交互达成共识。

## 📄 许可证

本项目使用 [MIT License](LICENSE)。
