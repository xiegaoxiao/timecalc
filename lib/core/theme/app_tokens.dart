import 'package:flutter/material.dart';

/// TimeCalc 设计 token 层（UI 重写 v1.11）。
///
/// 借鉴 shadcn/ui 的现代极简生产力设计语言：**中性基底 + 品牌绿点缀 +
/// 小圆角 + 细边框 + 克制阴影 + 清晰层级**。
///
/// 全部间距/圆角/阴影/动效收敛到本层，页面不再散落魔法数字
/// （现有页面逐步迁移，新代码一律从这里取值）。
///
/// 主色仍由 M3 `ColorScheme.fromSeed` 派生（对比度测试锁定），
/// 本层提供中性补充色与几何/动效档位，两层互补不冲突。
abstract final class AppTokens {
  // —— 品牌色（种子/渐变，同 app_theme 常量，供新代码直用）——
  static const Color brandDeep = Color(0xFF3F6C51);
  static const Color brandBright = Color(0xFF5C8A6E);

  // —— 中性灰阶（浅色模式；shadcn 式：更浅的底、更细的边框）——
  /// 页面底色（比旧 #F6F6F6 更冷更中性，卡片留白更干净）。
  static const Color neutralBgLight = Color(0xFFF5F5F7);
  /// 卡片表面（白）。
  static const Color neutralSurfaceLight = Color(0xFFFFFFFF);
  /// 细边框（卡片/分割线，中性冷灰）。
  static const Color neutralBorderLight = Color(0xFFE4E4E7);
  /// 主文字（近黑，比 M3 onSurface 更明确）。
  static const Color neutralTextLight = Color(0xFF18181B);
  /// 次级文字（摘要/说明）。
  static const Color neutralTextSecondaryLight = Color(0xFF52525B);

  // —— 圆角档位（小圆角为主，shadcn 风）——
  static const double radiusSm = 6;
  static const double radiusMd = 8;
  static const double radiusLg = 10;
  static const double radiusXl = 12;
  static const double radiusDialog = 16;

  // —— 间距档位 ——
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;

  /// 页面统一边距。
  static const double pagePadding = 16;

  // —— 动效档位（克制，不喧宾夺主）——
  static const Duration motionFast = Duration(milliseconds: 120);
  static const Duration motionNormal = Duration(milliseconds: 200);
  static const Duration motionSlow = Duration(milliseconds: 320);
  static const Curve motionCurve = Curves.easeOutCubic;
}
