import 'package:flutter/material.dart';

import '../../core/theme/accent_palette.dart';

/// 撞色语言的**色调角色**：把「一块撞色要表达什么情绪」抽象成枚举，
/// 页面只挑角色、不挑色值——这样三套撞色方案（暖橙×青 / 电光青×青柠 /
/// 紫罗兰×暖橙）切换时全站自动换色，且深浅色模式的明暗处理集中在一处。
///
/// 用法：
/// ```dart
/// ClashTone.warm // 主动作、倒计时、今日进度（= scheme.primary 家族）
/// ClashTone.cool // 数据、统计、课表、对照（= scheme.secondary 家族）
/// ClashTone.citrus // 里程碑、成就、徽标（= scheme.tertiary 家族）
/// ClashTone.danger // 逾期、超载、危险动作（= scheme.error 家族）
/// ```
enum ClashTone {
  /// 暖色（主色）：品牌主动作、hero 渐变、今日/倒计时。
  warm,

  /// 冷色（次级撞色）：统计数据、图表、日历选中、课表。
  cool,

  /// 点缀色：里程碑、成就、完成徽标。
  citrus,

  /// 危险色：逾期、超载、删除。
  danger,
}

/// 撞色角色 → 具体颜色（按当前明暗模式解析亮/暗变体）。
///
/// 为什么需要它：深色模式下同一个撞色的「填充色」与「图标/文字色」必须
/// 分开（见 `AppTheme._base` 的主色角色拆分注释）。页面若直接拿
/// `scheme.primary` 当填充又当图标色，深色下必有一处对比度不足。
/// 用 [ClashTones] 一次拿到正确的组合。
@immutable
class ClashTones {
  const ClashTones({
    required this.fill,
    required this.onFill,
    required this.ink,
    required this.soft,
    required this.onSoft,
    required this.deep,
  });

  /// 实心填充色（按钮底、选中块底、徽标底）——配 [onFill] 文字。
  final Color fill;

  /// 填充色上的文字/图标色（保证 ≥4.5:1）。
  final Color onFill;

  /// 直接压在页面底/卡片上的**文字或图标**色（保证 ≥4.5:1）。
  final Color ink;

  /// 浅色容器底（标签底、内嵌区块、选中行底）——配 [onSoft] 文字。
  final Color soft;

  /// 浅色容器上的文字色。
  final Color onSoft;

  /// 该撞色的深色变体（渐变的深端、边框、描边）。
  final Color deep;

  /// 解析当前主题下某个 [ClashTone] 的完整色组。
  ///
  /// 深色分支中与 `scheme.*Container` **完全同值**的 5 个字面量改为直接引用
  /// scheme（C19 去重）：容器色已由 `AppTheme._base` 按撞色方案解析一次，
  /// 这里再写一遍字面量必然漂移（如 `0xFF0F3D3B` 同时是
  /// `scheme.secondaryContainer(dark)` 与 cool.soft(dark)）。引用后这几对
  /// 容器色与 `contrast_test.dart` 断言的 `onXxxContainer/xxxContainer`
  /// 同源，不再依赖「两处手抄同一个值」。
  static ClashTones of(BuildContext context, ClashTone tone) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final accent = ClashPalette.of(context);
    return switch (tone) {
      ClashTone.warm => ClashTones(
        fill: isDark ? accent.warmDark : accent.warm,
        onFill: Colors.white,
        ink: isDark ? accent.warmBright : accent.warm,
        soft: isDark ? const Color(0xFF4A2110) : accent.warmContainer,
        onSoft: scheme.onPrimaryContainer,
        deep: isDark ? accent.warmBright : accent.warmDeep,
      ),
      ClashTone.cool => ClashTones(
        fill: isDark ? accent.coolDeep : accent.cool,
        onFill: Colors.white,
        ink: isDark ? accent.coolBright : accent.cool,
        soft: scheme.secondaryContainer,
        onSoft: scheme.onSecondaryContainer,
        deep: isDark ? accent.coolBright : accent.coolDeep,
      ),
      ClashTone.citrus => ClashTones(
        fill: isDark ? const Color(0xFF3F5410) : accent.citrus,
        onFill: Colors.white,
        ink: isDark ? accent.citrusBright : accent.citrus,
        soft: isDark ? const Color(0xFF2C3A0C) : accent.citrusContainer,
        onSoft: scheme.onTertiaryContainer,
        deep: isDark ? accent.citrusBright : accent.citrus,
      ),
      ClashTone.danger => ClashTones(
        // 深色填充＝scheme.errorContainer（原字面量 0xFF8C1D18 即其同值副本）。
        fill: isDark ? scheme.errorContainer : scheme.error,
        onFill: Colors.white,
        ink: scheme.error,
        soft: scheme.errorContainer,
        onSoft: scheme.onErrorContainer,
        deep: scheme.error,
      ),
    };
  }

  /// 撞色三主色的**全站序列**：图表、图例、日历多类别配色统一从这里取，
  /// 保证同一张图里三条序列永远是撞色关系而不是同色深浅。
  static List<Color> chartSeries(BuildContext context) {
    Color tone(ClashTone t) => of(context, t).ink;
    return [tone(ClashTone.warm), tone(ClashTone.cool), tone(ClashTone.citrus)];
  }

  /// 撞色半透明底（hover 底、选中行底、图表填充）——统一透明度免得
  /// 各页面自己 `withValues(alpha: 0.08)` 取值不一致。
  ///
  /// **口径（契约 v2.1）**：默认 `alpha = 0.10`，用于「大块 hover 底」；
  /// 侧栏等密集导航项用 `0.08`。两者都是既有约定值，页面按场景二选一，
  /// 不要引入第三个数。
  static Color tint(Color base, {double alpha = 0.10}) =>
      base.withValues(alpha: alpha);

  /// 把撞色混合进另一个底色（**不透明**结果）。
  ///
  /// 用途：需要「撞色淡底」但要求**完全不透明**时（例如日历格内的事件块、
  /// 压在任意格子底色上的胶囊）——半透明会让文字对比度随下层底色变化，
  /// 不透明混合则把对比度锁定，便于通过 NFR-4 的统一校验。
  static Color blend(Color base, Color background, {double alpha = 0.10}) =>
      Color.alphaBlend(base.withValues(alpha: alpha), background);

  /// 实心撞色块的 **hover/pressed 加深**变体。
  ///
  /// 背景：`fill` 是给「静置态」用的，hover 时若只加重投影，缺少直接的
  /// 颜色反馈。这里按固定比例把 [fill] 压暗（palette-agnostic，不引入
  /// 硬编码色），保证白字对比度只增不减（深色模式下 `warmDark` 压暗后
  /// 白字对比更高），因此可以安全地配 [onFill] 使用。
  static Color fillHover(Color fill, {double amount = 0.10}) =>
      Color.lerp(fill, Colors.black, amount)!;

  /// 实心撞色块的 **pressed** 变体（比 [fillHover] 再深一档）。
  static Color fillPressed(Color fill, {double amount = 0.18}) =>
      Color.lerp(fill, Colors.black, amount)!;
}

/// 撞色渐变（hero 卡、品牌头图、进度环底）。
///
/// [ClashGradient.header] 用于大面积品牌头图（深浅跨两个撞色），
/// [ClashGradient.tone] 用于单撞色深浅渐变（按钮、徽标、进度条）。
abstract final class ClashGradient {
  /// 品牌头图渐变：暖橙 → 深暖橙（默认方案），随撞色方案自动换色。
  static LinearGradient header(BuildContext context, {ClashTone? tone}) {
    final t = ClashTones.of(context, tone ?? ClashTone.warm);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? [t.fill, Color.lerp(t.fill, Colors.black, 0.34)!]
          : [t.deep, Color.lerp(t.deep, Colors.black, 0.22)!],
    );
  }

  /// 双撞色头图渐变（暖 × 冷）：用于「今天」页 hero —— 撞色最强烈的表达。
  static LinearGradient clash(BuildContext context) {
    final warm = ClashTones.of(context, ClashTone.warm);
    final cool = ClashTones.of(context, ClashTone.cool);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final a = isDark ? warm.fill : warm.deep;
    final b = isDark ? cool.deep : cool.fill;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [a, Color.lerp(a, b, 0.55)!, b],
      stops: const [0.0, 0.55, 1.0],
    );
  }

  /// 单撞色柔和渐变（浅底块、图表填充）。
  static LinearGradient soft(BuildContext context, ClashTone tone) {
    final t = ClashTones.of(context, tone);
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [t.soft, Color.lerp(t.soft, Colors.white, 0.35)!],
    );
  }
}
