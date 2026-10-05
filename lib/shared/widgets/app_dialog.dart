import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/motion_provider.dart';
import '../../core/theme/app_tokens.dart';
import 'clash_tones.dart';

/// 统一卡片式对话框组件（**v2.0 撞色语言**）。
///
/// 使用「撞色渐变顶条 + 撞色图标底标题区 + 自适应滚动内容 + 底部操作按钮」，
/// 替代默认 AlertDialog 以保持 UI 一致性：
/// - 标题图标底走 `ClashTones.of(context, ClashTone.warm).soft / onSoft`；
/// - 对话框圆角走 [AppTokens.radiusDialog]；
/// - 分隔线走 `scheme.outlineVariant`（暖调细边框）；
/// - 底部主行动按钮交给主题 `filledButton`（暖实心）、取消交给中性 textButton。
///
/// **公开签名向后兼容**：字段与 [show] 的全部参数名/类型保持不变，
/// 入场动效（[motionControllerProvider]，「减少动画」开关）依旧生效。
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.titleIcon,
    this.showCloseButton = false,
    this.onClose,
    this.maxWidth = 480,
    this.contentPadding,
    this.tone = ClashTone.warm,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final IconData? titleIcon;
  final bool showCloseButton;
  final VoidCallback? onClose;
  final double maxWidth;
  final EdgeInsetsGeometry? contentPadding;

  /// 标题区撞色归属（默认暖色）。
  ///
  /// 用于让「新增/编辑」类对话框标明自己的语义色（如里程碑表单用
  /// [ClashTone.citrus]、危险操作确认用 [ClashTone.danger]）；
  /// 不传则保持暖色，**向后兼容**。
  final ClashTone tone;

  /// 显示对话框的便捷方法。
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget content,
    List<Widget> actions = const [],
    IconData? titleIcon,
    bool showCloseButton = false,
    VoidCallback? onClose,
    double maxWidth = 480,
    EdgeInsetsGeometry? contentPadding,
    bool barrierDismissible = true,
    ClashTone tone = ClashTone.warm,
  }) {
    // 入场时长随「减少动画」开关归零（开启时瞬时呈现，交互仍即时）。
    final motion = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(motionControllerProvider);
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32),
      transitionDuration: motion.duration(AppTokens.motionNormal),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        // 入场动效（2026-08-20 动效改造）：淡入 + 0.96→1.0 轻微放大，
        // 比纯淡入更有「卡片浮现」感；开启「减少动画」时退化为纯淡入。
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppTokens.motionCurve,
        );
        Widget result = FadeTransition(opacity: curved, child: child);
        if (motion.enabled) {
          result = ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: result,
          );
        }
        return result;
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return AppDialog(
          title: title,
          content: content,
          actions: actions,
          titleIcon: titleIcon,
          showCloseButton: showCloseButton,
          onClose: onClose,
          maxWidth: maxWidth,
          contentPadding: contentPadding,
          tone: tone,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dialog(
      // 与 dialogTheme 同源取值（浅色纯白卡 / 深色暖黑卡），不写死颜色。
      backgroundColor: theme.brightness == Brightness.light
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: scheme.shadow.withValues(alpha: 0.16),
      clipBehavior: Clip.antiAlias,
      // 更大的对话框圆角（AppTokens.radiusDialog），与卡片语言区分层级。
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusDialog),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DialogTitle(
              title: title,
              icon: titleIcon,
              showCloseButton: showCloseButton,
              onClose: onClose,
              tone: tone,
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Flexible(
              child: SingleChildScrollView(
                padding:
                    contentPadding ?? const EdgeInsets.all(AppTokens.spaceXl),
                child: content,
              ),
            ),
            if (actions.isNotEmpty) ...[
              Divider(height: 1, color: scheme.outlineVariant),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceXl,
                  vertical: AppTokens.spaceLg,
                ),
                child: _DialogActions(actions: actions),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 对话框标题区域组件（撞色渐变顶条 + 撞色图标底 + 标题 + 可选关闭）。
class _DialogTitle extends StatelessWidget {
  const _DialogTitle({
    required this.title,
    this.icon,
    this.showCloseButton = false,
    this.onClose,
    this.tone = ClashTone.warm,
  });

  final String title;
  final IconData? icon;
  final bool showCloseButton;
  final VoidCallback? onClose;

  /// 标题区撞色归属（图标底与图标前景皆取该撞色的 soft/onSoft 配对，
  /// 保证深浅两模式下都 ≥4.5:1；不再直接用 `scheme.primary` 作图标色 ——
  /// 深色模式下 primary 是「实心填充色」，当图标色对比不足）。
  final ClashTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = ClashTones.of(context, tone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 细撞色渐变顶条：让对话框「属于哪个撞色」在扫视时即可判定。
        Container(
          height: 4,
          decoration: BoxDecoration(gradient: ClashGradient.clash(context)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceXl,
            vertical: 18,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: t.soft,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                  child: Icon(icon, color: t.onSoft, size: 20),
                ),
                const SizedBox(width: AppTokens.spaceSm),
              ],
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (showCloseButton)
                IconButton(
                  onPressed: onClose ?? () => Navigator.of(context).pop(),
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).closeButtonTooltip,
                  icon: const Icon(Icons.close, size: 20),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 对话框按钮区域组件。
class _DialogActions extends StatelessWidget {
  const _DialogActions({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return OverflowBar(
      alignment: MainAxisAlignment.end,
      overflowAlignment: OverflowBarAlignment.end,
      spacing: AppTokens.spaceSm,
      overflowSpacing: AppTokens.spaceSm,
      children: actions,
    );
  }
}
