import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/motion_provider.dart';
import '../../core/theme/app_tokens.dart';
import 'clash_tones.dart';

/// 可点卡片 hover 反馈容器（2026-08-20 动效改造）。
///
/// 桌面端最常见的「这张卡能点」暗示：鼠标悬停时边框加深（主色淡化）、
/// 阴影增强、微上浮 2px，并显示点击光标。动画用局部 [AnimatedContainer]
/// 过渡（不触整页 transform），动画时长随「减少动画」开关归零
/// （[motionControllerProvider]），hover 反馈仍即时呈现。
///
/// 传入 [onTap] 才视为可点卡片（有 hover 反馈 + 点击光标 + 水波纹）；
/// 不传时仅作普通容器，保持与 [Card] 一致的圆角/边框/阴影语言。
class HoverableCard extends ConsumerStatefulWidget {
  const HoverableCard({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
    this.decoration,
    this.hoverDecoration,
    this.hoverBorderColor,
    this.hoverElevate = true,
  });

  final Widget child;

  /// 点击回调；非空时渲染水波纹与点击光标。
  final VoidCallback? onTap;

  final BorderRadius? borderRadius;

  /// 常规态完整装饰（含表面色/渐变/边框/阴影）。为空时用与主题
  /// [Card] 一致的语言：圆角 12 + 中性细边框 + 黑 4% 浅影 + surface 表面。
  final BoxDecoration? decoration;

  /// hover 态完整装饰；为空时基于 [decoration]/默认样式增强边框与阴影。
  final BoxDecoration? hoverDecoration;

  /// hover 边框色（未传 [hoverDecoration] 时生效，默认主色 35% 透明度）。
  final Color? hoverBorderColor;

  /// hover 是否微上浮 2px（桌面观感）。
  final bool hoverElevate;

  @override
  ConsumerState<HoverableCard> createState() => _HoverableCardState();
}

class _HoverableCardState extends ConsumerState<HoverableCard> {
  bool _hovered = false;

  BoxDecoration _baseDecoration(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius =
        widget.borderRadius ?? BorderRadius.circular(AppTokens.radiusXl);
    return widget.decoration ??
        BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: radius,
          border: Border.all(
            color: isDark
                ? AppTokens.neutralBorderDark
                : AppTokens.neutralBorderLight,
          ),
          boxShadow: AppTokens.shadowCard(isDark),
        );
  }

  BoxDecoration _hoverDecoration(BuildContext context, BoxDecoration base) {
    if (widget.hoverDecoration != null) return widget.hoverDecoration!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // hover 边框用撞色主色（浅色下深橙、深色下亮橙，均满足图形 3:1）。
    final accent = ClashTones.of(context, ClashTone.warm);
    return base.copyWith(
      border: Border.all(
        color: widget.hoverBorderColor ?? accent.ink.withValues(alpha: 0.55),
      ),
      boxShadow: AppTokens.shadowCardHover(isDark),
    );
  }

  @override
  Widget build(BuildContext context) {
    final motion = ref.watch(motionControllerProvider);
    final clickable = widget.onTap != null;
    final radius =
        widget.borderRadius ?? BorderRadius.circular(AppTokens.radiusXl);
    final base = _baseDecoration(context);
    final hovered = _hovered && clickable;
    final decoration = hovered ? _hoverDecoration(context, base) : base;

    Widget content = widget.child;
    if (clickable) {
      content = Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: radius,
          child: widget.child,
        ),
      );
    }

    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: clickable ? (_) => setState(() => _hovered = true) : null,
      onExit: clickable ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedContainer(
        duration: motion.duration(AppTokens.motionNormal),
        curve: motion.curve,
        transform: hovered && widget.hoverElevate
            ? Matrix4.translationValues(0, -2, 0)
            : Matrix4.identity(),
        decoration: decoration,
        child: content,
      ),
    );
  }
}
