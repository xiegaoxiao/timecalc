import 'package:flutter/material.dart';

import 'app_semantic_colors.dart';

/// TimeCalc 品牌种子色（深绿）。
///
/// 主题派生与启动错误屏共用，避免硬编码多处漂移。
const Color kTimeCalcSeedColor = Color(0xFF3F6C51);

/// 浅色模式页面底色（模板参考：浅灰页面底，卡片留白更清晰）。
const Color kTimeCalcLightBackground = Color(0xFFF6F6F6);

/// 浅色模式分割线色（模板参考）。
const Color kTimeCalcLightDivider = Color(0xFFE0E0E0);

/// 品牌渐变深端（hero 卡片背景起点，同 seed 色相）。
const Color kTimeCalcBrandDeep = Color(0xFF3F6C51);

/// 品牌渐变浅端（同色相提亮变体，模板 A「同色深浅表达层次」手法）。
const Color kTimeCalcBrandBright = Color(0xFF5C8A6E);

/// TimeCalc 主题定义。
///
/// M1 起以 Material 3 默认色板为基础；M13 外观升级引入**组件级主题定制**
/// （克制型生产力风，参照 ui-template 模板的轻阴影/圆角/浅灰底手法）：
/// - [CardThemeData]：圆角 12 + 微边框 + 轻阴影——把进度页既有的卡片语言
///   提升为全局，所有页面 `Card` 自动统一；
/// - [AppBarTheme]：去表面色晕染、无阴影，页面头干净；
/// - 按钮/分割线/SnackBar/对话框统一圆角；
/// - [AppSemanticColors]：警告/成功/信息语义色 token 随主题注册；
/// - 品牌渐变（[kTimeCalcBrandDeep]→[kTimeCalcBrandBright]）+ 统一路由
///   过渡（页面入场动画），给 hero 卡片与页面切换注入品牌感。
///
/// 字体保持系统默认（Roboto），仅建立统一的主题档位，不引入字体资源。
abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: kTimeCalcSeedColor,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    final scaffoldBackground = isDark
        ? colorScheme.surface
        : kTimeCalcLightBackground;

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      // 浅灰页面底（深色用 M3 派生 surface），卡片留白更清晰。
      scaffoldBackgroundColor: scaffoldBackground,
      // 语义色 token 随主题注册，页面经 AppSemanticColors.of(context) 读取。
      extensions: [
        isDark ? AppSemanticColors.dark() : AppSemanticColors.light(),
      ],
      // AppBar：去 M3 默认表面色晕染与阴影，背景贴合页面底色。
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: scaffoldBackground,
      ),
      // 卡片：圆角 12 + 微边框 + 轻阴影（进度页既有语言的全局化）。
      // clipBehavior: Clip.none 让 fl_chart tooltip 可浮出图表边界。
      cardTheme: CardThemeData(
        elevation: 1,
        clipBehavior: Clip.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? colorScheme.outlineVariant : kTimeCalcLightDivider,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      // 统一路由过渡（页面入场动画）：淡入淡出，克制不抢戏。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
