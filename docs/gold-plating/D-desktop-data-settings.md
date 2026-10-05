# D：桌面壳 / 数据备份 / 错误处理 / 设置

> 审计范围：`lib/core/desktop/**`（5 文件 / 1028 行）、`lib/features/settings/**`（8 文件 / 1464 行）、
> `lib/features/backup/**`（13 文件 / 2648 行）、`lib/core/errors/**`（5 文件 / 521 行），合计
> **35 文件 / 5661 行**（行数按文件总行数计，含空行与注释；审计工具 `read` 逐文件实测）。
> 参考基线：`docs/requirements.md` §4.2（L80-81）、FR-8（L207-215）、FR-9（L217-223）、§8 异常（L267）、§9 Settings（L313-315）。
> 只读审计，未修改除本文件外的任何仓库文件；未运行 flutter build/test/pub get。

## 0 结论摘要

1. **本范围内最典型的镀金是 1 个死入口 + 1 个死扩展点**：`shortcuts_page.dart`（42 行「即将上线」空态页）与
   `DesktopController.onQuit`（M9 退出推送遗留，生产调用点从未传入），二者都可零风险删除。
2. **备份域的过度分层集中在「抽象壳」而非核心链路**：`backup_target.dart`（113 行，含 `RemoteBackupFile` 远端命名与
   生产零调用的 `download`）、`auto_backup_service.dart:159-168`（死方法 `buildEnabledTargets`）、
   两个 picker 抽象（51+23 行包两次 `file_selector` 调用）合计约 195 行可压缩到 80 行以内；备份核心
   （export / manifest 校验 / 合并 / 覆盖 / 安全副本）属 FR-9.1~9.3 P0，不可动。
3. **错误处理有 4 种形态但只有 1 处真重复**：`_SectionError` 在 `today_page.dart:1240-1278` 与
   `calendar_view.dart:668-703` 各写一遍（75 行近似重复）。对话框 / 启动屏 / 页面级错误视图三者场景不同，建议保留。
4. **设置域真正超纲的是 2 项**：`reduce_motion`（PRD 全文无出处，v15 迁移 + 15 行 UI + 3 用例）与
   `accent_color` 的 legacy `green`/`blue` 渲染路径（PRD 只要求浅色/深色，M10）；`settings` 表 13 列本身不算过量。
5. **最大单点成本是自绘无边框标题栏**（`window_chrome.dart` 297 行 + `TitleBarStyle.hidden` 耦合），
   PRD §4.2 Windows P0 只要求「主窗口」，且该文件无任何测试覆盖；但它同时是 v2.0 撞色视觉的核心表达，属品牌取舍，
   已列入 §4 存疑。
6. 归档任务页（291 行）与重置数据页（202 行）均不在 PRD 内，但承载真实数据安全语义；建议**精简而非整体移除**，
   整页去留交用户拍板（§4 第 4、5 项）。

## 1 条目表

| ID | 功能或机制 | 用户可见入口 | 代码证据(file:line, LOC) | PRD | 是否重复/空壳 | 判定 | 删除代价与风险 | 置信度 |
|---|---|---|---|---|---|---|---|---|
| D-01 | 自绘无边框标题栏（拖动/双击最大化/右键系统菜单/3 按钮 + hover 撞色） | 窗口顶部 48px 标题栏（所有路由） | `window_chrome.dart:11,41,137-228,233-296`（297 行）；`main.dart:31-44` 隐藏原生标题栏；`app.dart:57` 挂载 | 无（§4.2 L80 仅要求「主窗口」） | 否，但属可选美化 | 建议移除（回退原生标题栏，见 §4-1） | 删 297 行 + `main.dart:31-44` + `app.dart:57`；`kTitleBarHeight` 仅本文件使用（grep 全库），无测试引用；风险＝失去撞色品牌观感 | 中 |
| D-02 | DesktopController：托盘图标/菜单 + 关闭行为拦截 + 窗口几何防抖保存 | 托盘图标右键菜单「显示主窗口/退出」；关闭按钮行为 | `desktop_controller.dart:30-38,66-94,113-121,124-150,222-239,388-390`（391 行） | FR-8.1/8.2 P0 | 否 | 必留 | — | 高 |
| D-03 | `onQuit` 退出推送回调（M9 WebDAV 遗留扩展点） | 无（不可见） | `desktop_controller.dart:24-25,55,244-251`（约 12 行） | 无（M9 已移除，requirements.md:403） | 空壳：`main.dart:122-125` 与 `desktop_providers.dart:17-20` 均未传入 | 建议移除 | 删 2 行字段 + 构造参数 + `_quitApp` 内 try/catch；grep 全库无生产/测试调用点 | 高 |
| D-04 | TrayListener 4 个空回调 + `onWindowRestore`/`onWindowUnmaximize` 重复触发保存 | 无（不可见） | `desktop_controller.dart:253-276,280-306`（约 50 行） | 接口要求 | 部分重复 | 可留（低成本观察） | 空回调由接口签名强制，删不掉；`_popUpTrayMenu` 的 try/catch 与注释可精简 | 中 |
| D-05 | 窗口位置/尺寸/最大化/显示器归属恢复规则（多屏不可用时回退主屏可见区） | 启动时窗口落位 | `window_restore_service.dart:60-112,114-174`（175 行） | FR-8.3 P0 | 否 | 必留 | 有 8 个单测（`window_restore_service_test.dart`） | 高 |
| D-06 | 窗口状态 JSON 持久化（独立文件 + 原子写 + 损坏自愈） | 无（隐含） | `window_state_store.dart:12-33,117-143`（144 行） | FR-8.3 P0 / FR-9.5（不入业务备份） | 否 | 必留 | 子项 `trayFirstHintShown`（L32）把「首次提示已展示」塞进几何文件，属轻微职责混杂；有 4 个单测 | 高 |
| D-07 | 桌面 Provider（stateStore + controller） | 无 | `desktop_providers.dart:8-21`（21 行） | 支撑 FR-8 | 否 | 必留 | 极薄，测试靠 override 为 null 隔离平台调用 | 高 |
| D-08 | 快捷键占位页 + 设置页「快捷键 / 全局快捷键 · 即将上线」入口 + 路由 | 设置 → 快捷键 | `shortcuts_page.dart:11-41`（42 行）；`settings_page.dart:64-70`；`app_router.dart:233-236` | FR-8.5 为 P1 **未实现**；§9 Settings 列了 `hotkeysJson?`（L315）但表内无该列 | 空壳（无任何配置项、无写库、无实现） | 建议移除 | 删 42 行 + 1 个菜单项 + 1 条路由；`settings_page_test.dart:74` 断言「快捷键」存在需一并改；风险＝UI 上失去「P1 计划中」信号 | 高 |
| D-09 | 明暗主题三选一（跟随系统/浅色/深色，点击即换肤） | 设置 → 外观 | `appearance_page.dart:46-81,199-219`；列 `tables.dart:335`；迁移 `database.dart:316-324` | M10 / §4.2 P0 | 否 | 必留 | 有 9 个用例覆盖换肤＋持久化 | 高 |
| D-10 | 撞色方案（accent）三选一 + legacy `green`/`blue` 仅渲染路径 | 设置 → 外观 → 撞色方案 | `appearance_page.dart:84-114,238-260,294-303`；`accent_palette.dart:202-350`（5 套方案，`clashPaletteOrder` L350 仅 3 套）；迁移 `database.dart:342-351` | PRD 仅要求浅色/深色（§4.2 L82）；色系不在 FR 内 | 否；legacy 分支为兼容老数据 | 可留（低成本观察） | 3 套方案是 v2.0 设计语言；可零风险清理的是 legacy 渲染分支（`_paletteOptions`/`_isLegacyAccent`/`accent_palette.dart` 中 green/blue 两套，约 80 行），但老库值仍会命中渲染路径 | 中 |
| D-11 | 「减少动画」开关（全局动效时长归零） | 设置 → 外观 → 减少动画 | `appearance_page.dart:116-150,269-283`；列 `tables.dart:354`；迁移 `database.dart:352-361`（v15） | **PRD 全文无出处**（grep「动效/动画/reduce」仅命中 NFR-4 键盘可达） | 否 | 建议移除（仅删 UI；列可保留，见 §4-3） | 删 15 行 UI + 3 个用例；删列需新增 v19 迁移（`dropColumnIfExists`）；风险＝失去一个无障碍/低配设备的可用开关 | 中 |
| D-12 | 外观页预览装饰：`_ThemePreview` + `_Swatch` + `_PaletteDots` | 外观页底部预览卡 + 方案右侧三色圆点 | `appearance_page.dart:314-341,345-388,390-449`（约 135 行 / 449 行） | 无 | 纯装饰 | 可留（低成本观察） | 预览卡标题被测试断言（`appearance_page_test.dart:97-100,156-158`），`_Swatch` 色板无断言（低置信度：仅检查该测试文件）；无行为风险 | 中 |
| D-13 | 关闭行为页（退出 / 最小化到托盘，点击即写库并实时应用） | 设置 → 关闭行为 | `close_behavior_page.dart:33-68,98-135`（139 行） | FR-8.1 P0 | 否 | 必留 | 有 3 个用例（含实时应用断言） | 高 |
| D-14 | 计划偏好页（每日可用时长步进 + 每周可用日 + 全选/全取消） | 进度页 → 计划偏好（**不在设置页**） | `plan_preference_page.dart:49-77,104-114,134-148,175-216`（230 行）；路由 `app_router.dart:206-208`、入口 `progress_page.dart:452` | §5.1 / §6「设置：计划偏好…」（L253） | 否 | 必留 | 小瑕疵：无 `route` 常量，路径字面量在两处重复；有 4 个用例 | 高 |
| D-15 | 「重置数据」页（清空业务数据 / 数据+设置，双确认 + 自动安全副本） | 设置 → 重置数据 | `reset_data_page.dart:46-70,76-171,174-201`（202 行）；`backup_service.dart:283-301` `resetData` | 无（FR-9 未列；注释自称「FR-9 数据管理扩展」） | 与 `_overwriteRestore`（`backup_service.dart:437-445`）清空逻辑重复 | 建议简化或合并 | 建议合并两个互斥选项为 1 个 + 保留安全副本；整页移除需另给清库路径；`resetData` 仅被本页调用（grep） | 中 |
| D-16 | 设置页撞色菜单卡信息架构（分组标题 + `_MenuTile` + 摘要行） | 设置首页 6 项入口 | `settings_page.dart:43-97,101-139,167-224`（225 行） | §6 设置 IA | 否 | 必留 | 建议随 D-08 删「快捷键」项；摘要 `_autoBackupTargetsLabel`（L142-146）恒回「本地目录/未配置目录」，价值有限但成本 5 行 | 高 |
| D-17 | `settings` 单行表 13 列 + `SettingsRepository` 8 个 update + 8 次 settings 迁移步骤 | 各设置子页（见 §5） | `tables.dart:294-368`（13 列：296/299/303/311/316/322/328/335/348/354/362/364/365）；`settings_repository.dart:40-125`（约 90 行）；`database.dart:203-210,221-255,296-315,316-324,325-341,342-351,352-361,374-394` | §9 Settings（L313-315） | 否 | 必留 | 成本已量化：`migration.dart` 全文件 4233 行，是 drift step-by-step 快照（每版本一份 Shape），每次加设置列都会线性放大该文件；列数本身不算过量 | 高 |
| D-18 | 备份核心链路：导出 zip（8 张表快照）+ manifest 版本校验 + 合并（ID 映射/去重）+ 覆盖（保留运行时配置）+ FR-9.3 安全副本 | 备份与恢复页 → 导出备份 / 从备份恢复 | `backup_service.dart:63,84-164,170-177,183-225,232-245,310-430,437-581,584-676`（733 行）；`restore_confirm_dialog.dart` | FR-9.1/9.2/9.3 P0 | 否 | 必留 | 30 个用例覆盖（`backup_service_test.dart`）；删任何一段都会破坏 FR-9 验收或旧备份兼容 | 高 |
| D-19 | 备份域六层分层：service / codec / manifest / target / scheduler / provider（13 文件 2648 行） | 无（结构） | `backup_service.dart`+`backup_codec.dart`+`backup_manifest.dart`+`backup_target.dart`+`auto_backup_service.dart`+`auto_backup_scheduler.dart`+3 个 provider | FR-9 | 部分重复（target 层＋两个 picker） | 建议简化或合并 | 具体落点见 D-20/D-21/D-23（约 195→80 行）；service/codec/manifest/scheduler 四层各有独立职责与测试，不宜再合并 | 中 |
| D-20 | `BackupTarget` 抽象 + `RemoteBackupFile` + `download()` | 无（仅本地目录上传/剪枝用） | `backup_target.dart:6-16,39-113`（113 行） | FR-9.4 | 命名与 `download` 为 WebDAV 遗留（`upload/list/download/delete` 四方法） | 建议简化或合并 | `download` 生产零调用（仅 `backup_target_test.dart:33`）；`RemoteBackupFile` 可改名；`_baseName` 路径穿越防御（L62-70）必须保留 | 高 |
| D-21 | `AutoBackupService`：导出到临时目录→上传→保留 7 份剪枝 | 备份与恢复页「立即备份」/ 开关即时检查 | `auto_backup_service.dart:54-181`（182 行） | FR-9.4 P1 | 含死代码 + 单元素循环假装多目的地 | 建议简化或合并 | `buildEnabledTargets`（L159-168）全库零调用；`targets` 恒为 1 元素（L89）却按复数循环并回传 `uploadedTargets`（`backup_page.dart:288,319` 文案「N 个目的地」）；剪枝逻辑（L174-181）必留 | 高 |
| D-22 | `AutoBackupScheduler`：启动即查 + 每小时复查 + 当日失败去重提示 | 无直接入口（失败时 SnackBar） | `auto_backup_scheduler.dart:15-66`（67 行）；`main.dart:92-114` | FR-9.4 P1「应用运行期间语义」 | 否 | 可留（低成本观察） | `isRunning`/`checkNow` 仅测试用（`auto_backup_scheduler_test.dart`），属公开测试钩子；67 行成本可控 | 中 |
| D-23 | 两个文件选择抽象：`BackupFilePicker`（保存+打开）+ `BackupFolderPicker`（选目录） | 导出/恢复对话框、选择目录按钮 | `backup_file_picker.dart:10-51`（51 行）+ `backup_folder_picker.dart:9-23`（23 行） | 支撑 FR-9.1/9.4 | 两者都只包装 `file_selector`，且只被 `backup_page` 使用 | 建议简化或合并 | 合并为 1 文件 3 方法（74→约 40 行）；需同步改 `settings_page_test.dart:122-137` 的假实现与 `diagnostics_service.dart:21-38` 的同型实现；风险低 | 中 |
| D-24 | 恢复确认对话框（备份时间/目标数/任务数/里程碑/课程数 + 合并或覆盖） | 从备份恢复后弹出 | `restore_confirm_dialog.dart:18-104,107-161`（162 行） | FR-9.2 P0 | 否 | 必留 | 162 行中约 55 行为 `_InfoRow`/`_ModeTile` 复用组件 | 高 |
| D-25 | 备份与恢复页（自动备份区 + 手动区 + 语义化 SnackBar 工厂） | 设置 → 备份与恢复 | `backup_page.dart:101-202,236-301,303-335,337-365,379-430,440-474`（475 行） | FR-9.1~9.4 | 否；`_feedbackSnackBar` 可下沉共享 | 可留（低成本观察） | 475 行偏大但内聚；抽 `_feedbackSnackBar`（L440-474）到 shared 可减约 30 行；有 5 个用例 | 中 |
| D-26 | 已归档任务页 + 批量删除（选择/全选/反选/删除）+ 目标级归档 Provider | 设置 → 已归档任务 | `archived_tasks_page.dart:34-38,53-81,133-151,153-202,221-290`（291 行）；死 Provider `task_repository_provider.dart:79-83`；死方法 `task_repository.dart:478-492` | 无直接 FR；归档语义来自 JSON 导入替换（`tables.dart:148-152`） | 死链路：`archivedTaskListProvider` 只被 invalidate 从不被 watch；`archiveAllActive` 注释自称「仅用于测试/兼容」（`task_repository.dart:478`） | 建议简化或合并 | 建议删批量删除（约 110 行）与死 Provider（约 5 行），保留列表 + 单条「恢复」；需同步删/改 3 个专测批量删除的用例（`settings_archived_section_test.dart:127,159,227`）；整页去留见 §4-4 | 高 |
| D-27 | 4 种错误 UI 形态：写入失败对话框 / 启动错误屏 / 页面级 `AppErrorView` / 区块级 `_SectionError`×2 | 写库失败弹窗、启动失败全屏、页面/区块重试 | `db_error_dialog.dart`、`startup_error_screen.dart`、`app_error_view.dart:15-42`、`today_page.dart:1240-1278`（39 行）、`calendar_view.dart:668-703`（36 行） | §8 L267（数据库异常） | `_SectionError` 两份近似重复（75 行），且与 `AppErrorView` 版式分叉 | 建议简化或合并 | 把两份 `_SectionError` 提升为 `shared/widgets/app_error_view.dart` 内的 `SectionErrorView`；两个调用页（today/calendar）取其 4 个调用点即可；风险低（但会改动本范围外文件） | 高 |
| D-28 | 写库失败对话框（原因 + 导出诊断 + 前往备份恢复） | 任意写操作失败时 | `db_error_dialog.dart:14-19,22-65`（83 行）；`app_guard.dart:14-26` | §8 L267 | 与启动屏共享「导出诊断」动作但不重复 | 必留 | 1 个用例；PRO 语境的停止写入提示是本产品可靠性叙事的一部分 | 高 |
| D-29 | 启动错误屏（数据库打不开时替代应用运行） | 开库失败时的全屏 | `startup_error_screen.dart:16-132,137-166`（167 行）；`main.dart:54-64` | §8 L267 | 否 | 必留 | 2 个用例；含独立 `MaterialApp` + `ProviderScope` 包装（无库可用） | 高 |
| D-30 | 诊断服务：全局错误捕获 + 本地日志（256KB 截断）+ 导出诊断文件（版本/schema/行数/日志） | 错误对话框与启动屏的「导出诊断信息」 | `diagnostics_service.dart:55-68,71-76,82-139,170-187`（210 行） | §8 / NFR-3（L338 日志本地、自动清理） | 否 | 必留 | 子项 `recentErrors`（L79）仅测试使用；NFR-3 写「保留不超过 14 天」而实现只有 256KB 字节截断（规格缺口，非镀金） | 高 |
| D-31 | 全局错误处理器（FlutterError + PlatformDispatcher，防递归） | 无（后台） | `global_error_handlers.dart:12-22`（35 行）；`main.dart:46-49` | §8 / NFR-3 | 否 | 必留 | 35 行成本极低、收益明确；测试不安装（避免污染测试环境） | 高 |

> 判定口径：**必留**＝PRD 明确要求或删除即破坏既有验收；**可留（低成本观察）**＝成本可接受、暂不建议动；
> **建议简化或合并**＝保留语义、削减实现；**建议移除**＝删掉后无 PRD 缺口（需用户确认的已列入 §4）。

## 2 逐条论证

**D-01 自绘无边框标题栏。** PRD §4.2（`requirements.md:80`）对 Windows 的 P0 只写「主窗口、托盘、窗口位置恢复」，
未要求自绘标题栏；`window_chrome.dart` 297 行里，拖动区、双击最大化、右键系统菜单、3 个 hover 状态按钮
（L137-228、233-296）都是在重造 Windows 已内建的能力，且 `main.dart:31-44` 必须额外隐藏原生标题栏来避免双标题栏。
全库 grep 中 `kTitleBarHeight`（L11）只在本文件使用——其文档声称「对话框按窗口高度−标题栏计算，见 AppDialog」，
但 `app_dialog.dart` 并无引用，说明该常量实际不承担跨模块契约。
反向证据：它是 v2.0「撞色语言」在窗口外壳上的唯一表达（L142-191 的暖底 + 渐变 Logo），删除会改变产品观感，故置入 §4-1。
无任何测试覆盖 `CustomTitleBar`、`DesktopChrome`（全库 test 目录 grep 无命中）。

**D-02 DesktopController 托盘 + 关闭行为。** FR-8.1（关闭行为可配置 + 首次说明）与 FR-8.2（托盘菜单显示/退出）
是 P0，实现落在 L113-121（`setPreventClose`）、L124-150（图标/菜单）、L222-239（关闭拦截 + 首次提示）。
注释（L42-45）记录了 Windows 必须用 `.ico` 的实测结论，属有效领域知识，删除即回归风险。
测试通过继承并 override 公开方法（`settings_page_test.dart:144-161`）验证「设置变更实时生效」，
说明该类的公开面已被验收绑定，属必留。

**D-03 onQuit 死扩展点。** 字段声明与构造参数在 `desktop_controller.dart:35,55`，唯一调用点是 `_quitApp`（L246）；
但 `main.dart:122-125` 与 `desktop_providers.dart:17-20` 两处生产构造都没传 `onQuit`，grep 全库亦无其他赋值点。
它的来源是 M9 WebDAV「退出推送」，而 `requirements.md:403` 明确记载该功能已整体移除。
按奥卡姆剃刀，这是「为已删功能保留的接口」：删除后 `_quitApp` 只剩 `windowManager.destroy()`（L250）。

**D-04 TrayListener 空回调与重复保存。** `onTrayIconMouseUp`/`onTrayIconRightMouseUp`/`onTrayMenuItemClick`（L286-306）
是接口签名强制的空实现，删不掉；`onWindowRestore`/`onWindowUnmaximize` 都调 `_saveWindowState()`（L268-276），
与 `onWindowMoved`/`onWindowResized` 的语义重叠，但都走 300ms 防抖（L163-165），无实际重复写盘。
判为可留：成本是注释噪音，收益是显式覆盖事件。

**D-05 WindowRestoreService 多屏恢复。** FR-8.3 要求保存尺寸/位置/显示器信息，并在显示器不可用时回到主屏可见区。
实现以纯 Dart 计算（无平台依赖）覆盖：显示器为空 → 默认尺寸（L73-80）；保存显示器失效 → 主屏（L84-85）；
损坏尺寸钳制到 400×300（L114-120）；`_fitToVisibleArea` 保证至少 100px 可见（L131-168）。
`requirements.md:352,421` 明确要求覆盖多 DPI 与显插拔，此服务正是该风险的唯一防线；8 个单测在案。必留。

**D-06 WindowStateStore。** 独立 `window_state.json` + 原子写（临时文件 + rename，L134-143）+ 读取容错（L117-128）
恰好满足 FR-9.5「窗口状态不进业务备份」。唯一可议之处是 `trayFirstHintShown`（L32）把一次性的 UI 提示状态
放进几何文件，属于「就近存一处」的便利而非错误；拆出会新增一个文件而无收益。必留（子项可留）。

**D-07 桌面 Provider。** 21 行，职责是把 `WindowStateStore` 与 `DesktopController` 变成可 override 的注入点，
widget 测试据此完全绕开平台通道（`settings_page_test.dart:37` 传 null）。成本极低，必留。

**D-08 快捷键占位页 + 入口。** `shortcuts_page.dart:11-41` 全文没有一次写库、没有任何可配置项，只渲染
`ClashEmptyState` + 「即将上线」Chip；设置页入口（`settings_page.dart:64-70`）与路由（`app_router.dart:233-236`）
把它接进了主导航。PRD 侧：FR-8.5 是 P1 且未实现（`requirements.md:213`），§9 Settings 列了 `hotkeysJson?`（L315），
但 `tables.dart` 的 Settings 表 13 列中并没有对应列——也就是说该功能从数据层到 UI 层都是空的。
按判定标准 2（死入口与空壳），这是本范围内最干净的一刀：入口、页面、路由三处合计约 50 行，删后不影响任何 FR。

**D-09 明暗主题。** M10 验收要求「保存即换肤无需重启」，实现为点击即写库 + `ref.invalidate(settingsProvider)`
（`appearance_page.dart:46-81`），并有 9 个用例断言根组件换肤结果。属 P0，必留。

**D-10 撞色方案轴 + legacy 路径。** PRD 的「其他」行（`requirements.md:82`）只承诺浅色/深色主题，未含自定义色系；
`accent_palette.dart` 定义 5 套方案，其中 `green`/`blue` 已不再出现在 UI，仅为老数据保留渲染（`appearance_page.dart:26-28,253-260,294-303`）。
判为可留的理由：三套方案是 v2.0 设计语言的一部分，且 legacy 分支用约 15 行换来了「老库值不会渲染成空白」的兼容性；
若要精简，优先删 `_paletteOptions`/`_isLegacyAccent` 与两套 legacy 色板（约 80 行，但需确认老数据是否仍需渲染）。

**D-11 减少动画。** 该开关在 PRD 中无出处——`requirements.md` 全文 grep「动效/动画/reduce」只命中 NFR-4 键盘可达，
它来自 2026-08-20 的一次内部改造（`tables.dart:350-354`、`database.dart:352-361`）。
成本可量化：1 列 + 1 次迁移步骤 + UI 15 行 + 3 个用例；收益是低配设备/无障碍偏好。
按奥卡姆剃刀它属于「PRD 外的可选项」，但它已交付且几乎零维护成本，且删除列需要新增 v19 迁移，
所以本报告的建议是**只删 UI、保留列**（见 §4-3），以免为一次裁剪引入新的迁移风险。

**D-12 外观页预览装饰。** `_ThemePreview`（L345-388）+ `_Swatch`（L390-449）+ `_PaletteDots`（L314-341）
合计约 135 行，功能是「把当前选择画出来」。它不是空壳：测试断言了预览卡的模式文案
（`appearance_page_test.dart:97-100,156-158`）。剩余成本是 `_Swatch` 的两栏色板渲染，无行为风险也无断言覆盖
（低置信度：仅检查了 `appearance_page_test.dart`）。判为可留：裁剪收益小于视觉叙事价值。

**D-13 关闭行为页。** FR-8.1 的 UI 载体（139 行），点击即写库并调用 `desktopControllerProvider` 实时应用（L53-55），
`settings_page_test.dart:96-118` 用一个记录型替身断言 `applyCalls == 1`。必留。

**D-14 计划偏好页。** 承载 §5.1 的「每周可用日 / 每日可用时长」，是负载与延期计算的数据源
（`requirements.md:96`，§6 L253 把它归入设置）。230 行里 45 行是底部保存栏，其余为步进器 + 7 个 FilterChip
与「全部选中/取消」快捷操作——后者有测试断言（`goal_load_section_test.dart:359`）。必留。
唯一瑕疵是缺少 `route` 常量，路径字面量在 `app_router.dart:206` 与 `progress_page.dart:452` 各写一次。

**D-15 重置数据页。** 202 行 + `backup_service.resetData`（L283-301）。PRD 未列该功能，注释自称「FR-9 数据管理扩展」。
它的清空顺序与 `_overwriteRestore`（L437-445）几乎同构，区别只在「是否删 settings 行」与「是否重建默认行」；
两个互斥选项（仅数据 / 数据+设置）各自再套一层确认对话框（L134-163），是本页最大的实现成本。
建议合并为单一入口（默认留设置）+ 保留安全副本与二次确认，可减去约 80 行；整页是否保留见 §4-5。

**D-16 设置页菜单卡。** 225 行中约 125 行是 `_MenuTile`（L167-224）与 `_GroupHeader`（L101-139）的撞色卡片实现，
被 6 个入口复用，属合理抽取。摘要行有两处低价值：`_autoBackupTargetsLabel`（L142-146）在移除 WebDAV 后
只会返回「本地目录 / 未配置目录」两种常量文案。必留，随 D-08 删一项即可。

**D-17 settings 表与仓库。** 13 列（`tables.dart:296-365`）：3 列业务（计划偏好 2 列 + 学期基准 1 列）、
2 列桌面行为（close_behavior、主题相关不计入）、4 列外观/动效、4 列自动备份（含 last_auto_backup_at）。
列数本身不算过量；真正的成本在 `migration.dart`——4233 行是 drift 每版本快照的必然产物，
且该文件被 8 次 settings 变更（v6/v9/v11/v12/v13/v14/v15/v17，`database.dart:203-394`）持续放大，
其中 v13 专门删除了 v9/v11 引入的 6 个 WebDAV 列（L325-341），即「曾经加过又删掉」的历史包袱仍留在代码里。
建议维持现状；若要抑制膨胀，方向是未来把设备级外观配置从 settings 表移出（而非删列）。

**D-18 备份核心链路。** 733 行覆盖 FR-9.1~9.3 的全部硬要求：带版本 manifest（L106-120）、格式/类型/计数校验
（`backup_manifest.dart:78-92`）、合并去重与旧 ID→新 ID 映射（L310-430）、覆盖前安全副本（L206-207）、
覆盖时保留运行时配置（L513-556，直接服务 FR-9.5）。另有 100MB/512MB 双重上限（L74-79、L589-606）与
`_readObjectList` 显式逐元素校验（L697-715）针对的是外部输入损坏。30 个用例在案，必留。

**D-19 六层分层。** 逐层看：`backup_codec`（377 行）是格式兼容边界（字段命名、UTC 归一、`keepId`），必留；
`backup_manifest`（149 行）承载版本校验与 FR-9.2 摘要，必留；`backup_service` 必留；
`auto_backup_scheduler`（67 行）是 FR-9.4 的「运行期间」语义载体，可留。
真正过度的是「目的地抽象」这一层的三个零件：`BackupTarget`（D-20）、`AutoBackupService` 的多目的地循环（D-21）、
两个 picker 抽象（D-23），三者合计约 190 行，而生产路径只有一个本地目录。
结论：不建议拆掉分层，建议把「多目的地/远端」的抽象外壳收敛为单一本地目录实现。

**D-20 BackupTarget 与 RemoteBackupFile。** 抽象定义 4 个方法（L44-53），而 WebDAV 移除后
`download` 在生产代码中零调用（grep 全库仅 `backup_target_test.dart:33`），`RemoteBackupFile` 的
「远端」命名与 `modifiedAt` 字段是同一遗留。`upload`/`list`/`delete` 被 `AutoBackupService`
（L128、L175、L179）与 `_prune` 使用，必须保留。建议：删 `download` 与其测试断言、`RemoteBackupFile` 更名为
`BackupFileInfo`，或直接把 `LocalBackupTarget` 的 3 个方法内联到 `AutoBackupService`（可减约 60 行）。
注意 `_baseName`（L62-70）的路径穿越防御必须原样保留。

**D-21 AutoBackupService。** `buildEnabledTargets`（L159-168）全库零调用——它是多目的地时代供 UI 展示
「已启用目的地」的入口，WebDAV 移除后成了死方法。`targets` 恒为单元素列表（L89）却保留循环与
`uploadedTargets` 计数，导致 UI 出现「完成：1 个目的地」这类复数文案（`backup_page.dart:288,319`）。
`_prune`（L174-181）的「只删 `timecalc-auto-` 前缀、按文件名时间戳倒序保留 7 份」是 FR-9.4 的实质，
必须保留；`run` 的跳过判据（未启用/未配置目录/距上次 <24h）与「失败不推进时间戳」也是有验收价值的正确性细节。

**D-22 AutoBackupScheduler。** 67 行实现「启动即查 + 每小时复查 + 当日失败只提示一次」（L21,32-52），
对应 M8 退出条件（`requirements.md:397`），4 个用例在案。`isRunning`（L29）与 `checkNow`（L39）是公开测试钩子，
属于可接受的测试友好设计而非镀金。可留。

**D-23 两个 picker 抽象。** `BackupFilePicker`（保存 + 打开）与 `BackupFolderPicker`（选目录）各自
声明接口 + 原生实现 + Provider，合计 74 行只为包装 `file_selector` 的 3 次调用；两者都只被
`backup_page` 使用（grep）。而 `diagnostics_service.dart:21-38` 已经写了第三个同型抽象，
说明这套模式在复制而非复用。建议合并为一个 `FilePickers` 文件（3 方法 3 Provider 或 1 个 Provider 3 方法），
减去约 35 行；测试改动仅限 `settings_page_test.dart:122-137` 的假实现。

**D-24 恢复确认对话框。** FR-9.2 要求恢复前展示备份时间、目标数、任务数并确认合并/覆盖，
实现 L51-63 展示 5 项计数（课程数按 `appSchemaVersion >= 17` 条件显示，避免旧备份误导），L83-101 提供三动作。
162 行中有 55 行是可复用的 `_InfoRow`/`_ModeTile`，没有可裁的机制。必留。

**D-25 备份与恢复页。** 475 行里，自动备份区 100 行（L101-202）、手动区 25 行、开关即时检查的反馈分支 65 行、
立即备份 30 行、导出/恢复流程 90 行，另有 `_feedbackSnackBar`（L440-474，35 行）在页内定义。
功能上都是 FR-9.1~9.4 的入口；可议的是把 `_feedbackSnackBar` 下沉到 shared（它已被其它页面对 SnackBar 的
相似需求暗示可复用）。判为可留：拆分风险大于收益，5 个用例已覆盖关键路径。

**D-26 已归档任务页与批量删除。** 归档机制本身是必要的（JSON 导入替换要保留已完成旧任务，
`tables.dart:148-152`、`task_import_dialog.dart:137`），列表 + 单条「恢复」是其最小闭环。
超出的部分有三块：① 选择模式（L34-38、53-81）与全选/反选/批量删除（L133-151、153-202）约 110 行，
而 PRD 的「批量操作」P1 指的是任务批量操作，归档清理不在其列——但这段**已被 3 个 widget 用例覆盖**
（`settings_archived_section_test.dart:127` 全选删除、`:159` 反选、`:227` 空列表不进入选择模式），
删除需同步处理这些用例，成本高于纯死代码；② `archivedTaskListProvider`
（`task_repository_provider.dart:79-83`）只被 invalidate 从不被任何 widget watch——它是「目标详情页历史任务区」
被移除后的残留（`goal_load_section_test.dart:318` 记录了该迁移）；③ `TaskRepository.archiveAllActive`
（`task_repository.dart:478-492`）注释自认「仅用于测试/兼容」，但它同时是归档用例的造数工具
（`settings_archived_section_test.dart:58` 的 `seedArchived` 被 7 个用例复用），删除意味着重写测试脚手架。
合计可减约 115 行（①+②），页面与恢复能力不变。

**D-27 错误 UI 四形态。** 逐形态核对场景：`db_error_dialog`＝写操作失败（弹窗，含导出诊断/去恢复）、
`startup_error_screen`＝数据库打不开（独立 app，无库可用）、`app_error_view`＝页面级加载失败（带重试）、
`_SectionError`＝区块级加载失败（不建议打断整页）。四者场景不同，只有最后一项是真重复：
`today_page.dart:1240-1278`（圆角 `radiusLg` + 边框）与 `calendar_view.dart:668-703`（`radiusSm` 无边框）是
同一控件的两份分叉实现，75 行。建议在 `app_error_view.dart` 中新增 `SectionErrorView` 并由两处调用，
同时统一两者的圆角/边框（当前分叉意味着同一错误在两页观感不同）。此改动会触及本范围外文件，需 Lead 排期。

**D-28 写库失败对话框。** PRD §8（L267）要求「停止继续写入，提示从备份恢复或导出诊断信息」，
实现精确对应三个动作（L47-62）。它由 `runDbAction`（`app_guard.dart:14-26`）统一触发，
26+83 行换取全部写路径的一致提示，性价比很高。必留。

**D-29 启动错误屏。** 开库失败时 `main.dart:54-64` 不再裸崩，而是跑一个自含 `MaterialApp` + `ProviderScope`
的错误屏（L137-166），并允许注入共享诊断实例以导出真正的启动错误日志（L116-131）。有 2 个用例。必留。

**D-30 诊断服务。** 210 行承担：内存环 200 条 + 本地日志文件（256KB 上限、尾部截断）+
导出文件（应用版本/schema/数据库路径/7 张表行数/最近日志），其中数据库路径走 `PRAGMA database_list`
而不猜 drift 目录（L147-150）。PRD §8 与 NFR-3（L338）都要求日志本地保存并自动清理，
此实现是唯一载体；唯一冗余是 `recentErrors`（L79）仅测试使用，删除可减 3 行，无实际收益。

**D-31 全局错误处理器。** 35 行挂 `FlutterError.onError` 与 `PlatformDispatcher.instance.onError`，
并用 `_captureSafe` 防止诊断服务自身抛错造成递归（L24-35）。成本极低、对应 NFR-3 的「错误不静默丢失」。必留。

## 3 明确不建议动的部分

- **FR-9.1~9.3 手动备份/恢复全链路**（`backup_service.dart:84-245,584-676`）：zip + 版本 manifest + 计数校验 +
  安全副本，是「数据归用户所有」（`requirements.md:39`）与 M3/M4 退出条件的直接实现，30 个用例覆盖。
- **备份对 FR-9.5 的取舍细节**（`backup_service.dart:513-556`、`backup_codec.dart:90-94`）：settings 段只带
  计划偏好与学期基准，覆盖恢复时保留本设备的关闭行为/备份配置/主题/色系；`localBackupFolder` 等运行时字段
  即便出现在手工构造的 JSON 里也被刻意优先使用——这段「反直觉」的代码是正确性要求，不是复杂度。
- **WindowRestoreService 的钳制与可见区校正**（`window_restore_service.dart:114-168`）：对应 §12 风险表的
  「Windows 多屏与 DPI 差异」（`requirements.md:421`），删掉不报错但会重现「窗口不可见」故障。
- **zip bomb 双重上限与 `_readObjectList` 显式校验**（`backup_service.dart:74-79,589-606,697-715`）：
  备份文件是外部输入，这里的防御对应 NFR-2。
- **`LocalBackupTarget._baseName` 路径穿越防御**（`backup_target.dart:62-70`）。
- **诊断导出与全局错误处理器**（`diagnostics_service.dart`、`global_error_handlers.dart`）：PRD §8 表格
  「数据库异常」一行的两个动作之一。
- **归档机制本身**（`Tasks.archivedAt`、`tasks.archived_at` 索引、导入替换的归档分流）：JSON 导入替换的语义基础
  （`task_import_dialog.dart:137`、`tables.dart:148-152`），删列即破坏导入兼容与备份往返（`backup_codec.dart:60`）。
- **settings 迁移的幂等 helper**（`addColumnIfMissing`/`dropColumnIfExists`/`CREATE INDEX IF NOT EXISTS`，
  `database.dart:174,213,258-294,385-388`）：半迁移与重复升级安全，属 NFR-2。
- **FR-8.6 类「托盘动态图标」未实现**：P2（`requirements.md:215`），静态 `.png`/`.ico` 双资源
  （`desktop_controller.dart:40-48`）是当前正确形态，不存在镀金。
- **`isRunning`/`checkNow`/`recentErrors` 等测试钩子**：删除只会降低可测性，不产生结构收益。

## 4 存疑项（需要用户拍板）

1. **自绘标题栏（D-01）去留。**
   - 选项 A（删，省 297 行 + `main.dart:31-44`）：回退原生标题栏，得到系统级拖动/双击/snap/键盘菜单；
     代价＝撞色品牌观感丢失，窗口外壳与内容区不再「连成一片暖底」。
   - 选项 B（留）：保留 v2.0 视觉语言；代价＝持续维护自绘按钮的 hover/最大化状态同步，且该文件无测试覆盖。
2. **快捷键占位页（D-08）去留。** 选项 A（删）：立刻消除死入口（约 50 行），但 UI 上不再透露 P1 计划；
   选项 B（留）：保留「即将上线」信号，代价是每个版本都要解释它，且 `settings_page_test.dart:74` 继续为
   「无实现的入口」背书。若选 B，建议至少把入口置灰且不进路由（减少空页维护）。
3. **减少动画（D-11）处理方式。** 选项 A（只删 UI、保留列）：省 15 行 + 3 用例，无需迁移；
   选项 B（UI + 列一并删）：需新增 v19 迁移删除 `reduce_motion`，并核对备份/覆盖恢复路径；
   选项 C（保留现状）：接受一个 PRD 外但已交付的开关。
4. **已归档任务页（D-26）范围。** 选项 A（精简，本报告推荐）：删批量删除 + 死 Provider（约 115 行），
   保留列表与「恢复」；代价是同步删除/改写 3 个专测批量删除的用例（`settings_archived_section_test.dart:127,159,227`）。
   选项 B（整页移除）：设置页少一项，但用户失去跨目标回看/恢复归档任务的唯一入口，
   且 `settings_archived_section_test.dart`（8 用例中 7 个依赖 `archiveAllActive` 造数）需整体重写。
5. **重置数据页（D-15）形态。** 选项 A（合并选项）：单入口 + 安全副本 + 确认（省约 80 行）；
   选项 B（整页移除）：清库只能靠「覆盖恢复一个空备份」，对普通用户不可达；选项 C（保留现状）。
6. **撞色 legacy 渲染路径（D-10）清理。** 选项 A（删 `green`/`blue` 色板与 legacy 分支，约 80 行）：
   需先确认没有仍存 `green`/`blue` 的老库（或接受其回退到默认方案）；选项 B（保留）：兼容成本约 15 行 UI + 两套色板。

## 5 设置项清单（`settings` 表 13 列 → UI 入口 → 实现 → 判定）

| 列（`tables.dart`） | 引入版本 | 对应 UI 入口 | 是否有真实实现 | 判定 |
|---|---|---|---|---|
| `id`（L296） | v2 | 无（单行表主键，恒为 1） | 是（`settings_repository.dart:17`） | 必留（内部） |
| `dailyAvailableMinutes`（L299） | v2 | 计划偏好 → 每日可用时长步进器（`plan_preference_page.dart:104-114`） | 是（L198-205 写库） | 必留（§5.1） |
| `availableWeekdays`（L303） | v2 | 计划偏好 → 7 个 FilterChip + 全选/取消（`plan_preference_page.dart:134-170`） | 是（L203 写库，写/读双侧过滤非法值） | 必留（§5.1） |
| `closeBehavior`（L311） | v6 | 设置 → 关闭行为 分段（`close_behavior_page.dart:116-132`） | 是（写库 + `applyCloseBehavior` 实时生效） | 必留（FR-8.1 P0） |
| `autoBackupEnabled`（L316） | v9 | 备份与恢复 → 「启用每日自动备份」开关（`backup_page.dart:143-149`） | 是（开关即写库并立即检查一次） | 必留（FR-9.4 P1，已交付） |
| `localBackupFolder`（L322） | v9 | 备份与恢复 → 「选择目录…」（`backup_page.dart:170-173`） | 是（原生目录对话框 + 写库） | 必留（FR-9.4） |
| `lastAutoBackupAt`（L328） | v9 | 备份与恢复 → 「上次成功：…」（`backup_page.dart:432-436`） | 是（仅展示/判据，非用户可编辑） | 必留（FR-9.4 的 24h 判据） |
| `themeMode`（L335） | v12 | 设置 → 外观 → 明暗分段（`appearance_page.dart:199-219`） | 是（点击即写库并整树换肤） | 必留（M10 P0） |
| `accentColor`（L348） | v14 | 设置 → 外观 → 撞色方案分段（`appearance_page.dart:238-252`） | 是；`green`/`blue` 仅保留渲染路径（L253-260,294-303） | 可留（低成本观察；legacy 分支可按 §4-6 清理） |
| `reduceMotion`（L354） | v15 | 设置 → 外观 → 「减少动画」开关（`appearance_page.dart:271-282`） | 是（写库 + 全局时长归零） | 建议移除 UI（PRD 无出处，详见 D-11/§4-3） |
| `semesterStartDate`（L362） | v17 | **不在设置页**：课表页设置/导入时写入（`timetable_page.dart:242-258`、`timetable_import_dialog.dart:146-150`） | 是（参与教学周换算与排程扣减） | 必留（FR-10.3 P1，且随备份往返） |
| `createdAt`（L364） | v2 | 无 | 是 | 必留（内部） |
| `updatedAt`（L365） | v2 | 无 | 是（`settings_repository.dart:132` 每次写更新） | 必留（内部） |

> PRD §9（`requirements.md:315`）列出的 `theme`、`language`、`backupPath?`、`autoBackup`、`hotkeysJson?` 与实现的映射：
> `theme`→`themeMode`+`accentColor`（拆分）、`backupPath?`→`localBackupFolder`、`autoBackup`→`autoBackupEnabled`；
> **`language` 与 `hotkeysJson?` 在表内不存在**——前者对应 P1「英文界面」未交付（无 UI 入口，不构成镀金），
> 后者对应 FR-8.5 未交付，仅以 D-08 的空壳页占位。
> 另注：窗口状态（D-06）不在本表，而是独立 `window_state.json`，符合 FR-9.5。

---

### 方法与证据说明

- 行数口径：`read` 工具返回的文件总行数（含空行/注释）。任务书中的 912/1375/2446/475 行为非空行口径
  （例如 `core/desktop` 按总行数为 1028 行），本报告统一以总行数计并在表中标注。
- 死代码判定均由全库 grep 确认调用点：`onQuit`（无生产调用）、`buildEnabledTargets`（零调用）、
  `BackupTarget.download`（仅测试）、`archivedTaskListProvider`（仅 invalidate）、`TaskRepository.archiveAllActive`
  （注释自认仅测试/兼容）、`recentErrors`（仅测试）、`kTitleBarHeight`（仅 `window_chrome.dart`）。
- 测试面（本范围相关，实测 `test/` 下用例数）：`backup_service_test` 30、`settings_repository_test` 24、
  `appearance_page_test` 9、`window_restore_service_test` 8、`auto_backup_service_test` 8、
  `settings_archived_section_test` 8、`backup_target_test` 5、`backup_page_test` 5、
  `auto_backup_scheduler_test` 4、`plan_preference_page_test` 4、`window_state_store_test` 4、
  `diagnostics_service_test` 3、`settings_page_test` 3、`startup_error_screen_test` 2、
  `db_error_dialog_test` 1，合计约 118 用例 / 3074 行。
- **零覆盖区域（新增/改动需格外小心）**：`CustomTitleBar`/`DesktopChrome`（无测试）、
  `shortcuts_page`（无测试）、`reset_data_page` 的 UI（无 widget 测试；仅 `resetData` 服务层被
  `backup_service_test.dart:810-855` 覆盖，页面入口由 `settings_page_test.dart:75` 断言存在）。
  已归档任务页相反：列表/恢复/批量删除均有 widget 用例（`settings_archived_section_test.dart`），改动前必须同步改测试。
- 本报告为只读审计产物，未删除任何代码；§4 中的裁剪建议均需用户拍板后再执行。
