import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/desktop/window_chrome.dart';
import '../../core/providers/motion_provider.dart';
import '../../core/theme/accent_palette.dart';
import '../../core/theme/app_tokens.dart';

/// 统一卡片式对话框组件。
///
/// 使用品牌色渐变标题区域 + 白底内容 + 底部操作按钮，
/// 替代默认 AlertDialog 以保持 UI 一致性。
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
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final IconData? titleIcon;
  final bool showCloseButton;
  final VoidCallback? onClose;
  final double maxWidth;
  final EdgeInsetsGeometry? contentPadding;

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
      barrierColor: Colors.black54,
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = Theme.of(context).extension<AccentPalette>();
    final motion = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(motionControllerProvider);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceXl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: AnimatedSize(
          duration: motion.duration(AppTokens.motionNormal),
          curve: motion.curve,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题区域 - 品牌色渐变
              _DialogTitle(
                title: title,
                icon: titleIcon,
                showCloseButton: showCloseButton,
                onClose: onClose,
                accent: accent,
                scheme: scheme,
              ),
              // 内容区域：Material 承载表面色（内部 ListTile/RadioListTile
              // 的水波纹才能正确渲染，Container 背景会触发框架断言）+ 限高 +
              // 可滚动，避免小窗口高度/系统字号放大时溢出。
              Material(
                color: scheme.surface,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(AppTokens.radiusDialog),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    // 可用高度先减去自定义标题栏（48px），再取 78%：
                    // 对话框在窗口高度下始终留出标题栏空间，小窗口/系统
                    // 字号放大时内容可滚动而不溢出（无边框窗口回归）。
                    maxHeight: (MediaQuery.sizeOf(context).height -
                            kTitleBarHeight) *
                        0.78,
                  ),
                  child: SingleChildScrollView(
                    padding: contentPadding ??
                        const EdgeInsets.fromLTRB(
                          AppTokens.spaceLg,
                          AppTokens.spaceLg,
                          AppTokens.spaceLg,
                          AppTokens.spaceMd,
                        ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        content,
                        if (actions.isNotEmpty) ...[
                          const SizedBox(height: AppTokens.spaceLg),
                          _DialogActions(actions: actions),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 对话框标题区域组件。
class _DialogTitle extends StatelessWidget {
  const _DialogTitle({
    required this.title,
    required this.scheme,
    this.icon,
    this.showCloseButton = false,
    this.onClose,
    this.accent,
  });

  final String title;
  final IconData? icon;
  final bool showCloseButton;
  final VoidCallback? onClose;
  final AccentPalette? accent;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    // 使用主题 primary 色的渐变
    final gradientColors = [
      scheme.primary,
      scheme.primary.withValues(alpha: 0.85),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceMd + 2,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradientColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusDialog),
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: AppTokens.spaceSm),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (showCloseButton)
            IconButton(
              onPressed: onClose ?? () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 18,
            ),
        ],
      ),
    );
  }
}

/// 对话框按钮区域组件。
class _DialogActions extends StatelessWidget {
  const _DialogActions({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        for (int i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: AppTokens.spaceSm),
          actions[i],
        ],
      ],
    );
  }
}
