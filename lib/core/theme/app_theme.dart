import 'package:flutter/material.dart';

import 'app_semantic_colors.dart';
import 'app_tokens.dart';

/// TimeCalc 品牌种子色（深绿）。
///
/// 主题派生与启动错误屏共用，避免硬编码多处漂移。
const Color kTimeCalcSeedColor = Color(0xFF3F6C51);

/// 浅色模式页面底色（token：中性冷灰，卡片留白更干净）。
const Color kTimeCalcLightBackground = AppTokens.neutralBgLight;

/// 浅色模式分割线色（token：中性细边框）。
const Color kTimeCalcLightDivider = AppTokens.neutralBorderLight;

/// 品牌渐变深端（hero 卡片背景起点，同 seed 色相）。
const Color kTimeCalcBrandDeep = AppTokens.brandDeep;

/// 品牌渐变浅端（同色相提亮变体，模板 A「同色深浅表达层次」手法）。
const Color kTimeCalcBrandBright = AppTokens.brandBright;

/// TimeCalc 主题定义。
///
/// M1 起以 Material 3 默认色板为基础；M13 外观升级引入**组件级主题定制**
/// （克制型生产力风，参照 ui-template 模板的轻阴影/圆角/浅灰底手法）；
/// v1.11 主题重写接入 [AppTokens] design token 层（借鉴 shadcn/ui 的
/// 现代极简生产力语言）：中性底色/细边框/小圆角/统一动效档位，主色仍由
/// M3 派生色板承担（对比度测试锁定）。
///
/// - [CardThemeData]：圆角 12 + 中性细边框 + 轻阴影——卡片语言全局统一；
/// - [AppBarTheme]：去表面色晕染、无阴影，页面头干净；
/// - 按钮/分割线/SnackBar/对话框统一圆角档位；
/// - [NavigationBarThemeData]：底导航指示器圆角/标签规格统一；
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
        : AppTokens.neutralBgLight;

    // 文字层级：标题统一加粗（Semibold），摘要统一中性次级色，
    // 与中性底/细边框一起构成「清晰层级」。
    final baseTextTheme = ThemeData(
      brightness: brightness,
      useMaterial3: true,
    ).textTheme;
    final textTheme = baseTextTheme
        // 先统一到 M3 派生前景色。
        .apply(
          bodyColor: colorScheme.onSurface,
          displayColor: colorScheme.onSurface,
        )
        // 再覆写层级：标题 Semibold、摘要中性次级色（后写生效）。
        .copyWith(
          titleLarge: baseTextTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          titleMedium: baseTextTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          bodySmall: baseTextTheme.bodySmall?.copyWith(
            color: isDark
                ? colorScheme.outline
                : AppTokens.neutralTextSecondaryLight,
          ),
        );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      textTheme: textTheme,
      // 中性底色（深色用 M3 派生 surface），卡片留白更清晰。
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
        // 页面标题层级：Semibold，与 token 文字档位一致。
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      // 卡片：圆角 12 + 中性细边框 + 轻阴影（token 化；进度页既有语言
      // 的全局化）。clipBehavior: Clip.none 让 fl_chart tooltip 可浮出
      // 图表边界。
      cardTheme: CardThemeData(
        elevation: 1,
        clipBehavior: Clip.none,
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusXl),
          side: BorderSide(
            color: isDark
                ? colorScheme.outlineVariant.withValues(alpha: 0.4)
                : AppTokens.neutralBorderLight,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? colorScheme.outlineVariant : AppTokens.neutralBorderLight,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusDialog),
        ),
      ),
      // 底部导航（窄窗保留手机式底栏）：指示器圆角/标签规格统一，
      // 与 NavigationRail（宽窗）保持同一视觉语言。
      navigationBarTheme: NavigationBarThemeData(
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
      ),
      // 统一路由过渡（页面入场动画）：纯淡入，无位移无缩放。
      //
      // 此前用 FadeForwardsPageTransitionsBuilder（带位移 + 缩放，Flutter
      // 3.27+ 新过渡），覆盖了主壳切页 + 所有子页 push，桌面端位移/缩放
      // 合成叠加是「页面切换掉帧」的实测主因。换成本地轻量淡入
      // （_FadePageTransitionsBuilder，150ms，仅透明度，无 transform），
      // UI 线程负担最小，观感同样顺滑克制。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.windows: _FadePageTransitionsBuilder(),
          TargetPlatform.linux: _FadePageTransitionsBuilder(),
          TargetPlatform.macOS: _FadePageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 轻量淡入路由过渡（150ms 纯透明度，无位移/缩放）。
///
/// 替代默认 MaterialPage 的位移 + FadeForwards 的位移/缩放：桌面端
/// 位移动画在 push/切页时触发整页 raster 合成，是掉帧的主要来源；
/// 纯 Opacity 动画不改变布局/几何，绘制成本最低。
class _FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 首帧直接给出内容（CurvedAnimation 从 0 起，150ms 淡入到位）。
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    );
  }
}
