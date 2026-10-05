import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../shared/widgets/clash_tones.dart';
import '../theme/app_tokens.dart';

/// 自定义标题栏高度（48px）。
///
/// 原生标题栏隐藏后由 [CustomTitleBar] 占据顶部；对话框等浮层按
/// 「窗口高度 − 标题栏」计算可用空间（见 AppDialog），避免内容被裁切。
const double kTitleBarHeight = 48;

/// 桌面窗口外壳：自定义标题栏 + 内容区。
///
/// 原生标题栏已在 main.dart 用 [TitleBarStyle.hidden] 隐藏，这里经
/// `MaterialApp.builder` 挂到所有路由之上（主页面 + 详情子页共用同一
/// 标题栏）。对话框/SnackBar 走 Overlay，不受本层影响。
class DesktopChrome extends StatelessWidget {
  const DesktopChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const CustomTitleBar(),
        Expanded(child: child),
      ],
    );
  }
}

/// 自绘 48px 标题栏：品牌标识 + 拖动区 + 窗口控制按钮。
///
/// 左侧 Logo/名称，右侧最小化/最大化/关闭。标题栏主体可拖动窗口
/// （`startDragging` 走 WM_SYSCOMMAND SC_MOVE|HTCAPTION，保留 Windows
/// Aero snap 特性），双击切换最大化，右键弹出系统窗口菜单。最大化状态
/// 经 [WindowListener] 同步，图标随状态切换。所有平台调用 try/catch
/// 包裹：widget 测试无插件时静默跳过。
class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({super.key});

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    // addListener 仅注册本地监听，不触碰平台通道，测试安全。
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted && maximized != _maximized) {
        setState(() => _maximized = maximized);
      }
    } catch (_) {
      // 平台不可用（widget 测试）：保持默认未最大化。
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted && !_maximized) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted && _maximized) setState(() => _maximized = false);
  }

  @override
  void onWindowRestore() {
    if (mounted && _maximized) setState(() => _maximized = false);
  }

  Future<void> _toggleMaximize() async {
    try {
      if (_maximized) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // 平台不可用时静默降级。
    }
  }

  Future<void> _startDrag() async {
    try {
      await windowManager.startDragging();
    } catch (_) {
      // 平台不可用时静默降级。
    }
  }

  Future<void> _showWindowMenu() async {
    try {
      await windowManager.popUpWindowMenu();
    } catch (_) {
      // 平台不可用时静默降级。
    }
  }

  Future<void> _minimize() async {
    try {
      await windowManager.minimize();
    } catch (_) {
      // 平台不可用时静默降级。
    }
  }

  Future<void> _close() async {
    try {
      // 走系统 SC_CLOSE：触发 DesktopController.onWindowClose 的
      // 托盘/退出逻辑，行为与原生关闭按钮一致。
      await windowManager.close();
    } catch (_) {
      // 平台不可用时静默降级。
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warm = ClashTones.of(context, ClashTone.warm);
    final danger = ClashTones.of(context, ClashTone.danger);
    return Material(
      // 撞色改造：标题栏背景取 `scheme.surface`（浅色=暖奶油 #FDF6F0，
      // 深色=暖近黑），与页面底色同源，让外壳与内容连成一片暖底；
      // 底部 1px hairline 用 outlineVariant 分隔「窗口外壳」与内容区。
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SizedBox(
          height: kTitleBarHeight,
          child: Row(
          children: [
            const SizedBox(width: AppTokens.spaceLg),
            // 品牌小方块：撞色渐变（暖×冷）+ 白色时钟图标，与侧栏品牌区
            // 同源，是撞色语言在「窗口外壳」上的最小表达。
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                gradient: ClashGradient.clash(context),
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              ),
              child: Icon(
                Icons.access_time_rounded,
                size: 13,
                color: warm.onFill,
              ),
            ),
            const SizedBox(width: AppTokens.spaceSm),
            Text(
              'TimeCalc',
              // v1.17 精修：14px w500，比 15px w600 更收敛，不抢内容。
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            // 细分隔线：品牌标识与拖动区的分界，用冷色渐变（暖 Logo ×
            // 冷分隔）点出撞色关系（纯装饰，不承载信息）。
            Container(
              width: 2,
              height: 14,
              margin: const EdgeInsets.only(left: AppTokens.spaceMd),
              decoration: BoxDecoration(
                gradient: ClashGradient.header(context, tone: ClashTone.cool),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            // 拖动区：双击最大化，右键系统窗口菜单，左键拖拽移动窗口。
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _toggleMaximize,
                onSecondaryTap: _showWindowMenu,
                onPanStart: (_) => _startDrag(),
              ),
            ),
            _WindowButton(
              icon: Icons.remove_rounded,
              tooltip: '最小化',
              onTap: _minimize,
            ),
            _WindowButton(
              // 最大化/还原图标随窗口状态切换。
              icon: _maximized
                  ? Icons.filter_none_rounded
                  : Icons.crop_square_rounded,
              tooltip: _maximized ? '还原' : '最大化',
              onTap: _toggleMaximize,
            ),
            _WindowButton(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              // 撞色改造：hover 用**危险色（红）**而非主色——桌面软件
              // 「关闭」的正确语义；主色留给品牌与主动作。
              hoverColor: danger.fill,
              hoverForeground: danger.onFill,
              onTap: _close,
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 标题栏窗口控制按钮：46×48 命中区（贴近系统按钮规格），hover 显示
/// 底色，关闭钮 hover 变危险色（撞色语言：危险＝红）。
class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.hoverColor,
    this.hoverForeground,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// hover 底色（默认 surfaceContainerHighest）。
  final Color? hoverColor;

  /// hover 前景色（默认 onSurfaceVariant；关闭钮用白）。
  final Color? hoverForeground;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 撞色改造：空闲图标色统一走 `scheme.onSurfaceVariant`（暖中灰），
    // 不再写死 #667085——保证跟随主题与撞色方案。
    final idleForeground = scheme.onSurfaceVariant;
    final foreground = _hovered
        ? (widget.hoverForeground ?? scheme.onSurfaceVariant)
        : idleForeground;
    final background = _hovered
        ? (widget.hoverColor ?? scheme.surfaceContainerHighest)
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // 标题栏在 Navigator 之上（MaterialApp.builder），无 Overlay 可用，
      // 不能用 Tooltip；用 Semantics 提供按钮语义标签（NFR-4 键盘/读屏）。
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: InkWell(
          onTap: widget.onTap,
          // 系统风按钮：无涟漪/高亮，仅 hover 底色。
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          child: SizedBox(
            width: 46,
            height: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(color: background),
              child: Icon(widget.icon, size: 18, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}
