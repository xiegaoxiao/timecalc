import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'clash_tones.dart';

/// 撞色英雄面板：大面积撞色渐变容器（今天页倒计时卡、目标详情头部、
/// 统计概览卡等「页面第一眼」区块的统一实现）。
///
/// 与 v1 的区别：v1 的 hero 是「主色深浅渐变的白字卡」，全站只有一种
/// 情绪；v2 用 [ClashGradient] 做**暖×冷双撞色**渐变，并支持右上角
/// 装饰性撞色光斑（[ClashHeroOrb]）制造层次，撞色对比一眼可见。
///
/// 用法：
/// ```dart
/// ClashHero(
///   tone: ClashTone.warm,
///   child: Column(children: [...]),
/// )
/// ```
class ClashHero extends StatelessWidget {
  const ClashHero({
    super.key,
    required this.child,
    this.tone = ClashTone.warm,
    this.gradient,
    this.padding = const EdgeInsets.all(AppTokens.spaceXl),
    this.borderRadius = AppTokens.radiusXl,
    this.orb = true,
    this.secondaryOrb = true,
    this.foreground,
  });

  final Widget child;

  /// 主撞色（渐变基色）。
  final ClashTone tone;

  /// 自定义渐变（默认按 [tone] 取品牌渐变；传 [ClashGradient.clash]
  /// 可得到暖×冷双撞色头图）。
  final Gradient? gradient;

  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// 是否渲染右上角主撞色光斑（装饰，纯视觉）。
  final bool orb;

  /// 是否渲染左下角**对撞色**光斑（撞色的关键：冷暖同时出现）。
  final bool secondaryOrb;

  /// 面板内文字/图标色（默认白，保证在渐变上 ≥4.5:1）。
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? Colors.white;
    final warm = ClashTones.of(context, tone);
    final clash = ClashTones.of(
      context,
      tone == ClashTone.warm ? ClashTone.cool : ClashTone.warm,
    );
    return Container(
      decoration: BoxDecoration(
        gradient: gradient ?? ClashGradient.clash(context),
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: AppTokens.shadowTinted(warm.fill, opacity: 0.30),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (orb)
            Positioned(
              top: -46,
              right: -34,
              child: _Orb(color: warm.deep, size: 168),
            ),
          if (secondaryOrb)
            Positioned(
              bottom: -58,
              left: -40,
              child: _Orb(color: clash.deep, size: 150),
            ),
          Padding(
            padding: padding,
            child: DefaultTextStyle(
              style: TextStyle(color: fg),
              child: IconTheme(
                data: IconThemeData(color: fg),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 装饰光斑（英雄面板上的半透明圆，制造撞色层次）。
class _Orb extends StatelessWidget {
  const _Orb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.22),
        ),
      ),
    );
  }
}
