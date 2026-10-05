import 'package:flutter/material.dart';

/// TimeCalc 设计 token 层（**v2.0 撞色重构**）。
///
/// ## 设计语言：「暖橙 × 冷藏青」互补撞色
///
/// 两套主色互为补色方向，形成结构性对冲而非单色深浅：
/// - **暖橙**（warm）＝品牌主色、主动作、导航选中、hero 渐变；
/// - **冷藏青**（cool）＝次级主色、数据/统计/日历选中、对照与进度；
/// - **青柠黄绿**（citrus）＝点缀强调、里程碑、成就与徽标。
///
/// 底色走**暖奶油**而非冷灰：撞色需要暖底承载，冷灰底会把暖橙拉脏。
/// 卡片仍为纯白（撞色块浮在白卡上对比最强），边框带一点暖调。
///
/// ## 与 v1 的关系（向后兼容）
///
/// v1 的中性 token（`neutralBgLight` 等）与几何/动效档位**全部保留原名**，
/// 旧页面不改也能编译；但取值已换成新语言的暖色系。新代码优先用
/// [clashWarm] / [clashCool] / [clashCitrus] 与 [shadowCard] 等语义档位，
/// 不再直接写死颜色。
///
/// 所有色值经 `tool/clash_palette_solver.dart` 求解并由
/// `test/core/theme/contrast_test.dart` 锁定 ≥4.5:1（WCAG 2.1 AA）。
abstract final class AppTokens {
  // ───────────────────────── 撞色三主色（v2 核心） ─────────────────────────

  /// 暖橙（主色）：白字对比 5.15:1，暖奶油底上作文字 4.81:1。
  static const Color clashWarm = Color(0xFFC63D0F);

  /// 深暖橙（hover/pressed、渐变深端）。
  static const Color clashWarmDeep = Color(0xFF9E2F0A);

  /// 亮暖橙（渐变亮端、深色模式主橙，白底上仅作装饰不作小字）。
  static const Color clashWarmBright = Color(0xFFFF8A4C);

  /// 橙容器（浅底，配 [clashWarmInk] 文字 10.86:1）。
  static const Color clashWarmContainer = Color(0xFFFFE3D3);

  /// 橙容器上的文字色。
  static const Color clashWarmInk = Color(0xFF5A1A00);

  /// 冷藏青（次级主色）：白字对比 6.07:1，暖奶油底上作文字 5.67:1。
  static const Color clashCool = Color(0xFF0E6E6B);

  /// 深冷藏青（hover/pressed、渐变深端）。
  static const Color clashCoolDeep = Color(0xFF08504E);

  /// 亮冷藏青（渐变亮端、深色模式青）。
  static const Color clashCoolBright = Color(0xFF4FD1C5);

  /// 青容器（浅底，配 [clashCoolInk] 文字 11.15:1）。
  static const Color clashCoolContainer = Color(0xFFCBE9E7);

  /// 青容器上的文字色。
  static const Color clashCoolInk = Color(0xFF03302E);

  /// 青柠黄绿（点缀强调）：白字 4.99:1，暖奶油底上作文字 4.66:1。
  static const Color clashCitrus = Color(0xFF4D7C0F);

  /// 亮青柠（深色模式点缀）。
  static const Color clashCitrusBright = Color(0xFFBBD65C);

  /// 青柠容器（浅底，配 [clashCitrusInk] 文字 10.93:1）。
  static const Color clashCitrusContainer = Color(0xFFE6F0CB);

  /// 青柠容器上的文字色。
  static const Color clashCitrusInk = Color(0xFF22370A);

  // ───────────────────────── 品牌别名（旧代码兼容） ─────────────────────────

  /// 品牌深端（＝暖橙；hero 渐变深端）。
  static const Color brandDeep = clashWarm;

  /// 品牌亮端（＝亮暖橙；hero 渐变亮端）。
  static const Color brandBright = clashWarmBright;

  // ───────────────────────── 中性暖色阶（浅色模式） ─────────────────────────

  /// 页面底色（暖奶油，承载撞色块）。
  static const Color neutralBgLight = Color(0xFFFDF6F0);

  /// 卡片表面（纯白：撞色块浮于白卡，对比最强）。
  static const Color neutralSurfaceLight = Color(0xFFFFFFFF);

  /// 次级表面（暖调浅底：内嵌区块、表头、alternating 行）。
  static const Color neutralSurfaceMutedLight = Color(0xFFF7EDE6);

  /// 细边框（暖调，比 v1 的冷灰更柔和）。
  static const Color neutralBorderLight = Color(0xFFEADFD7);

  /// 强边框（hover/聚焦、区块分隔）。
  static const Color neutralBorderStrongLight = Color(0xFFDCCBC0);

  /// 主文字（暖近黑）。
  static const Color neutralTextLight = Color(0xFF1C1917);

  /// 次级文字（暖中灰，暖奶油底上 7.13:1）。
  static const Color neutralTextSecondaryLight = Color(0xFF57534E);

  /// 三级文字（说明/占位，仅用于 ≥14px 的非关键信息）。
  static const Color neutralTextTertiaryLight = Color(0xFF78716C);

  // ───────────────────────── 中性暖色阶（深色模式） ─────────────────────────

  /// 深色页底（暖近黑）。
  static const Color neutralBgDark = Color(0xFF17120F);

  /// 深色卡片表面。
  static const Color neutralSurfaceDark = Color(0xFF201A16);

  /// 深色次级表面。
  static const Color neutralSurfaceMutedDark = Color(0xFF2A2320);

  /// 深色边框。
  static const Color neutralBorderDark = Color(0xFF3A2F28);

  /// 深色主文字。
  static const Color neutralTextDark = Color(0xFFF5EFE9);

  /// 深色次级文字。
  static const Color neutralTextSecondaryDark = Color(0xFFC4B8AE);

  // ───────────────────────── 圆角档位 ─────────────────────────

  /// 小圆角（chip、徽标、进度条端）。
  static const double radiusSm = 8;

  /// 中圆角（按钮、输入框、导航项）。
  static const double radiusMd = 12;

  /// 大圆角（小卡、内嵌区块）。
  static const double radiusLg = 14;

  /// 超大圆角（卡片，全局卡片语言）。
  static const double radiusXl = 18;

  /// 对话框圆角。
  static const double radiusDialog = 22;

  // ───────────────────────── 间距档位 ─────────────────────────

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double spaceXxl = 32;

  /// 页面统一边距。
  static const double pagePadding = 20;

  /// 侧栏宽度（撞色面板）。
  static const double sidebarWidth = 208;

  // ───────────────────────── 阴影档位（暖调投影，非纯黑） ─────────────────────────

  /// 卡片静止阴影：暖褐 6%，比纯黑更贴底色。
  static List<BoxShadow> shadowCard(bool isDark) => [
    BoxShadow(
      color: const Color(0xFF7C4A2D).withValues(alpha: isDark ? 0.28 : 0.07),
      blurRadius: 14,
      offset: const Offset(0, 4),
    ),
  ];

  /// 卡片 hover 阴影（抬升感增强）。
  static List<BoxShadow> shadowCardHover(bool isDark) => [
    BoxShadow(
      color: const Color(0xFF7C4A2D).withValues(alpha: isDark ? 0.40 : 0.13),
      blurRadius: 26,
      offset: const Offset(0, 10),
    ),
  ];

  /// 撞色块阴影：按撞色本身的色相投影（暖橙块投橙影、青块投青影）。
  static List<BoxShadow> shadowTinted(Color base, {double opacity = 0.28}) => [
    BoxShadow(
      color: base.withValues(alpha: opacity),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  // ───────────────────────── 动效档位 ─────────────────────────

  static const Duration motionFast = Duration(milliseconds: 120);
  static const Duration motionNormal = Duration(milliseconds: 200);
  static const Duration motionSlow = Duration(milliseconds: 320);
  static const Curve motionCurve = Curves.easeOutCubic;
}
