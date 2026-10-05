import 'package:flutter/material.dart';

import 'accent_palette.dart';
import 'app_semantic_colors.dart';
import 'app_tokens.dart';

/// TimeCalc 默认品牌种子色（暖橙，即 [clashAccent] 的 warm）。
///
/// 保留常量供无 context 场景（启动错误屏、诊断导出）使用；页面一律走
/// `Theme.of(context)` / [ClashPalette.of]。
const Color kTimeCalcSeedColor = AppTokens.clashWarm;

/// 浅色模式页面底色（token：暖奶油）。
const Color kTimeCalcLightBackground = AppTokens.neutralBgLight;

/// 浅色模式分割线色（token：暖调细边框）。
const Color kTimeCalcLightDivider = AppTokens.neutralBorderLight;

/// 默认撞色方案 hero 渐变深端。
const Color kTimeCalcBrandDeep = AppTokens.clashWarmDeep;

/// 默认撞色方案 hero 渐变亮端。
const Color kTimeCalcBrandBright = AppTokens.clashWarmBright;

/// TimeCalc 主题定义（**v2.0 撞色重构**）。
///
/// ## 与 v1 的关键差异
///
/// v1 用 `ColorScheme.fromSeed` 单 seed 派生：secondary/tertiary 只是主色
/// 的同色系深浅，撞不出来；且 `scheme.surface` 与页面实际底色
/// （[AppTokens.neutralBgLight]）不一致，导致对比度测试断言的颜色对与用户
/// 实际看到的颜色对**不是同一个**。
///
/// v2 改为**显式构造 [ColorScheme]**：
/// - 三主色（暖橙/冷藏青/青柠）直接来自 [AccentPalette]，撞色关系锁定；
/// - `surface == 页面底色`，因此 `contrast_test` 断言的每一条
///   `xxx/surface` 都等于「用户真实看到的色对」；
/// - 所有色值由 `tool/clash_palette_solver.dart` 求解 ≥4.5:1。
///
/// 组件级语言：暖调细边框 + 暖调投影 + 大圆角（18px 卡片）+ 撞色高亮，
/// 卡片「白卡浮于暖奶油底」。
abstract final class AppTheme {
  /// 构造指定撞色方案的主题；[accent] 为空时用默认撞色（[clashAccent]）。
  static ThemeData light({AccentPalette? accent}) =>
      _base(Brightness.light, accent ?? clashAccent);

  static ThemeData dark({AccentPalette? accent}) =>
      _base(Brightness.dark, accent ?? clashAccent);

  static ThemeData _base(Brightness brightness, AccentPalette accent) {
    final isDark = brightness == Brightness.dark;

    // ── 主色角色拆分（撞色语言的关键约定） ──
    //
    // 深色模式下「主色」有三种互相冲突的用法，用一个色值必然有一处不达标：
    //  ① 实心填充（按钮/选中块）＋白字  → 需要足够深；
    //  ② 图标/文字/进度环压在深色页底上 → 需要足够亮；
    //  ③ M3 的 `scheme.primary` 语义恰好同时要服务 ①②。
    //
    // 解法：`scheme.primary` 取**填充色**（M3 约定 primary=实心底色，
    // onPrimary=白字，对比度最高优先项），图标/文字类消费点显式改用
    // [primaryAccent]。
    final primaryFill = isDark ? accent.warmDark : accent.warm;
    final primaryAccent = isDark ? accent.warmBright : accent.warm;

    // ── 显式色板：三主色来自撞色方案，中性色来自 token，全部显式。 ──
    final scheme = ColorScheme(
      brightness: brightness,
      primary: primaryFill,
      onPrimary: Colors.white,
      primaryContainer: isDark
          ? const Color(0xFF5A2410)
          : accent.warmContainer,
      onPrimaryContainer: isDark
          ? const Color(0xFFFFDBC8)
          : accent.onWarmContainer,
      // 次级撞色（冷藏青）：数据/统计/日历选中/对照。
      secondary: isDark ? accent.coolBright : accent.cool,
      onSecondary: isDark ? const Color(0xFF00201F) : accent.onCool,
      secondaryContainer: isDark
          ? const Color(0xFF0F3D3B)
          : accent.coolContainer,
      onSecondaryContainer: isDark
          ? const Color(0xFFC8F5F0)
          : accent.onCoolContainer,
      // 点缀撞色（青柠）：里程碑/成就/徽标/图表第三序列。
      tertiary: isDark ? accent.citrusBright : accent.citrus,
      onTertiary: isDark ? const Color(0xFF1B2A00) : accent.onCitrus,
      tertiaryContainer: isDark
          ? const Color(0xFF33440F)
          : accent.citrusContainer,
      onTertiaryContainer: isDark
          ? const Color(0xFFE4F2C0)
          : accent.onCitrusContainer,
      error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
      onError: isDark ? const Color(0xFF690005) : const Color(0xFFFFFFFF),
      errorContainer: isDark
          ? const Color(0xFF8C1D18)
          : const Color(0xFFF9DEDC),
      onErrorContainer: isDark
          ? const Color(0xFFF9DEDC)
          : const Color(0xFF410E0B),
      // 表面：surface 即页面底色（让对比度断言 == 实际观感）。
      surface: isDark ? AppTokens.neutralBgDark : AppTokens.neutralBgLight,
      onSurface: isDark
          ? AppTokens.neutralTextDark
          : AppTokens.neutralTextLight,
      surfaceContainerLowest: isDark
          ? const Color(0xFF120E0C)
          : const Color(0xFFFFFFFF),
      surfaceContainerLow: isDark
          ? AppTokens.neutralSurfaceDark
          : const Color(0xFFFFFFFF),
      surfaceContainer: isDark
          ? AppTokens.neutralSurfaceMutedDark
          : AppTokens.neutralSurfaceMutedLight,
      surfaceContainerHigh: isDark
          ? const Color(0xFF332B26)
          : const Color(0xFFF2E5DC),
      surfaceContainerHighest: isDark
          ? const Color(0xFF3E3430)
          : const Color(0xFFEBDCD2),
      surfaceDim: isDark ? const Color(0xFF120E0C) : const Color(0xFFF0E4DB),
      surfaceBright: isDark
          ? const Color(0xFF3E3430)
          : const Color(0xFFFFFFFF),
      onSurfaceVariant: isDark
          ? AppTokens.neutralTextSecondaryDark
          : AppTokens.neutralTextSecondaryLight,
      outline: isDark
          ? const Color(0xFF6B5B52)
          : AppTokens.neutralBorderStrongLight,
      outlineVariant: isDark
          ? AppTokens.neutralBorderDark
          : AppTokens.neutralBorderLight,
      shadow: const Color(0xFF1C1917),
      scrim: const Color(0xFF1C1917),
      inverseSurface: isDark
          ? AppTokens.neutralTextDark
          : AppTokens.neutralTextLight,
      onInverseSurface: isDark
          ? const Color(0xFF1C1917)
          : const Color(0xFFFDF6F0),
      inversePrimary: isDark ? accent.warmDeep : accent.warmBright,
      // 派生色板（图表/装饰用）显式给定，避免 fromSeed 的调性偏移。
      primaryFixed: accent.warmContainer,
      primaryFixedDim: isDark ? accent.warmBright : accent.warmDeep,
      onPrimaryFixed: accent.onWarmContainer,
      onPrimaryFixedVariant: accent.warmDeep,
      secondaryFixed: accent.coolContainer,
      secondaryFixedDim: isDark ? accent.coolBright : accent.coolDeep,
      onSecondaryFixed: accent.onCoolContainer,
      onSecondaryFixedVariant: accent.coolDeep,
      tertiaryFixed: accent.citrusContainer,
      tertiaryFixedDim: isDark ? accent.citrusBright : accent.citrus,
      onTertiaryFixed: accent.onCitrusContainer,
      onTertiaryFixedVariant: accent.citrus,
    );

    final baseTextTheme = ThemeData(
      brightness: brightness,
      useMaterial3: true,
    ).textTheme;
    final onSurface = scheme.onSurface;
    final onSurfaceVariant = scheme.onSurfaceVariant;

    // 文字层级（撞色语言：标题更重、正文更松、标签更小更宽）。
    final textTheme = baseTextTheme
        .apply(bodyColor: onSurface, displayColor: onSurface)
        .copyWith(
          // 数值/大标题：数字是生产力工具的主角，字重拉到 w700。
          displaySmall: baseTextTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: onSurface,
          ),
          headlineMedium: baseTextTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: onSurface,
          ),
          headlineSmall: baseTextTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: onSurface,
          ),
          titleLarge: baseTextTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: onSurface,
          ),
          titleMedium: baseTextTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: onSurface,
          ),
          titleSmall: baseTextTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: onSurface,
          ),
          bodyLarge: baseTextTheme.bodyLarge?.copyWith(
            height: 1.45,
            color: onSurface,
          ),
          bodyMedium: baseTextTheme.bodyMedium?.copyWith(
            height: 1.45,
            color: onSurface,
          ),
          bodySmall: baseTextTheme.bodySmall?.copyWith(
            color: onSurfaceVariant,
            height: 1.4,
          ),
          labelLarge: baseTextTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
            color: onSurface,
          ),
          labelMedium: baseTextTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: onSurfaceVariant,
          ),
          labelSmall: baseTextTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: onSurfaceVariant,
          ),
        );

    final cardRadius = BorderRadius.circular(AppTokens.radiusXl);
    final cardBorder = BorderSide(
      color: isDark ? AppTokens.neutralBorderDark : AppTokens.neutralBorderLight,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      // 语义色 token（警告/成功/信息）+ 撞色方案随主题注册。
      extensions: [
        isDark ? AppSemanticColors.dark() : AppSemanticColors.light(),
        accent,
      ],
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: scheme.surface,
        foregroundColor: onSurface,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: onSurface),
      ),
      // 卡片：18px 大圆角 + 暖调细边框 + 暖调投影（白卡浮于暖奶油底）。
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? AppTokens.neutralSurfaceDark : Colors.white,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.none,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: cardRadius,
          side: cardBorder,
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        iconColor: onSurfaceVariant,
        textColor: onSurface,
      ),
      navigationRailTheme: NavigationRailThemeData(
        minWidth: AppTokens.sidebarWidth,
        backgroundColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        selectedIconTheme: IconThemeData(color: primaryAccent, size: 22),
        unselectedIconTheme: IconThemeData(color: onSurfaceVariant, size: 22),
        selectedLabelTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: primaryAccent,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: onSurfaceVariant,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: isDark ? AppTokens.neutralSurfaceDark : Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.warmContainer,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? (isDark ? accent.warmBright : accent.warmDeep)
                : onSurfaceVariant,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark
            ? AppTokens.neutralBorderDark
            : AppTokens.neutralBorderLight,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryFill,
          foregroundColor: Colors.white,
          minimumSize: const Size(88, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? accent.coolBright : accent.coolDeep,
          side: BorderSide(
            color: isDark
                ? AppTokens.neutralBorderDark
                : AppTokens.neutralBorderStrongLight,
          ),
          minimumSize: const Size(88, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? accent.coolBright : accent.cool,
          minimumSize: const Size(68, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: onSurfaceVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryFill,
        foregroundColor: Colors.white,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark
            ? AppTokens.neutralSurfaceMutedDark
            : AppTokens.neutralSurfaceMutedLight,
        selectedColor: accent.warmContainer,
        side: BorderSide.none,
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: accent.onWarmContainer,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? accent.warmContainer
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? accent.onWarmContainer
                : onSurfaceVariant,
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(
              color: isDark
                  ? AppTokens.neutralBorderDark
                  : AppTokens.neutralBorderStrongLight,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? AppTokens.neutralSurfaceMutedDark
            : AppTokens.neutralSurfaceMutedLight,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        hintStyle: TextStyle(
          color: isDark
              ? AppTokens.neutralTextSecondaryDark
              : AppTokens.neutralTextTertiaryLight,
          fontSize: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(
            color: isDark
                ? AppTokens.neutralBorderDark
                : AppTokens.neutralBorderLight,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(
            color: isDark ? accent.coolBright : accent.cool,
            width: 1.6,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primaryAccent,
        linearTrackColor: isDark
            ? AppTokens.neutralSurfaceMutedDark
            : AppTokens.neutralSurfaceMutedLight,
        circularTrackColor: isDark
            ? AppTokens.neutralSurfaceMutedDark
            : AppTokens.neutralSurfaceMutedLight,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : (isDark ? const Color(0xFF8A7A70) : Colors.white),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent.warm
              : (isDark
                    ? AppTokens.neutralSurfaceMutedDark
                    : const Color(0xFFDCCBC0)),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primaryFill
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(
          color: isDark
              ? AppTokens.neutralBorderDark
              : AppTokens.neutralBorderStrongLight,
          width: 1.6,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primaryFill
              : (isDark
                    ? AppTokens.neutralBorderDark
                    : AppTokens.neutralBorderStrongLight),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primaryAccent,
        thumbColor: primaryAccent,
        inactiveTrackColor: isDark
            ? AppTokens.neutralSurfaceMutedDark
            : AppTokens.neutralSurfaceMutedLight,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: primaryAccent,
        unselectedLabelColor: onSurfaceVariant,
        indicatorColor: primaryAccent,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark
              ? AppTokens.neutralSurfaceMutedDark
              : AppTokens.neutralTextLight,
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
        textStyle: TextStyle(
          color: isDark ? AppTokens.neutralTextDark : Colors.white,
          fontSize: 12,
        ),
        waitDuration: const Duration(milliseconds: 400),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? AppTokens.neutralSurfaceMutedDark
            : AppTokens.neutralTextLight,
        contentTextStyle: TextStyle(
          color: isDark ? AppTokens.neutralTextDark : Colors.white,
          fontSize: 14,
        ),
        actionTextColor: isDark
            ? accent.citrusBright
            : AppTokens.clashCitrusBright,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? AppTokens.neutralSurfaceDark : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusDialog),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(color: onSurface),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? AppTokens.neutralSurfaceDark : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusDialog),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? AppTokens.neutralSurfaceDark : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        textStyle: textTheme.bodyMedium,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? (isDark
                    ? AppTokens.neutralBorderDark
                    : AppTokens.neutralBorderStrongLight)
              : (isDark
                    ? AppTokens.neutralBorderDark.withValues(alpha: 0.6)
                    : AppTokens.neutralBorderLight),
        ),
      ),
      // 统一路由过渡：纯淡入（桌面端最省合成，见 v1.17 性能结论）。
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
