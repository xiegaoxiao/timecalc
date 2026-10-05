import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 撞色方案（v2.0 撞色重构）：一个色系 = **一组互补撞色三元组**。
///
/// 与 v1 的「单 seed 派生」不同：撞色语言要求两套主色**显式对冲**，
/// 由 seed 自动派生的 secondary 只会是同色系深浅，撞不出来。因此这里把
/// 三主色（暖 / 冷 / 点缀）连同各自的容器色一起显式声明，主题层直接把
/// 它们灌进 [ColorScheme]（见 `AppTheme._base`），不依赖 M3 派生。
///
/// 经 [ThemeData.extensions] 注册，页面用
/// `Theme.of(context).extension<AccentPalette>()` 或便捷的
/// [ClashPalette.of] 读取。
///
/// 以后新增撞色方案 = 定义常量 + 注册表加一项；设置页/主题/渐变卡全自动。
@immutable
class AccentPalette extends ThemeExtension<AccentPalette> {
  const AccentPalette({
    required this.id,
    required this.label,
    required this.seed,
    required this.brandDeep,
    required this.brandBright,
    required this.warm,
    required this.warmDeep,
    required this.warmBright,
    required this.warmDark,
    required this.warmContainer,
    required this.onWarmContainer,
    required this.cool,
    required this.coolDeep,
    required this.coolBright,
    required this.coolContainer,
    required this.onCoolContainer,
    required this.citrus,
    required this.citrusBright,
    required this.citrusContainer,
    required this.onCitrusContainer,
    required this.onWarm,
    required this.onCool,
    required this.onCitrus,
  });

  /// 持久化标识（settings.accent_color 取值）。
  final String id;

  /// 设置页显示名。
  final String label;

  /// 亮色模式主色（＝[warm]，保留字段名以兼容 v1 消费点）。
  final Color seed;

  /// hero 渐变深端。
  final Color brandDeep;

  /// hero 渐变亮端。
  final Color brandBright;

  // —— 撞色三元组：暖 / 冷 / 点缀（浅色模式取值）——
  final Color warm;
  final Color warmDeep;
  final Color warmBright;

  /// **深色模式的实心主色底**（按钮/徽标填充，配白字）。
  ///
  /// 为什么单独一个角色：深色下 `primary` 被两种互相冲突的用法争夺——
  /// ①图标/文字/进度环要求「在深底上足够亮」（[warmBright]）；
  /// ②实心按钮要求「白字压得住」（需要足够深）。
  /// 一个色值无法同时满足，故拆成两色：主题把 [warmBright] 给
  /// `scheme.primary`（文字/图标语义），按钮填充显式取本值。
  final Color warmDark;

  final Color warmContainer;
  final Color onWarmContainer;
  final Color onWarm;

  final Color cool;
  final Color coolDeep;
  final Color coolBright;
  final Color coolContainer;
  final Color onCoolContainer;
  final Color onCool;

  final Color citrus;
  final Color citrusBright;
  final Color citrusContainer;
  final Color onCitrusContainer;
  final Color onCitrus;

  @override
  AccentPalette copyWith({
    String? id,
    String? label,
    Color? seed,
    Color? brandDeep,
    Color? brandBright,
    Color? warm,
    Color? warmDeep,
    Color? warmBright,
    Color? warmDark,
    Color? warmContainer,
    Color? onWarmContainer,
    Color? onWarm,
    Color? cool,
    Color? coolDeep,
    Color? coolBright,
    Color? coolContainer,
    Color? onCoolContainer,
    Color? onCool,
    Color? citrus,
    Color? citrusBright,
    Color? citrusContainer,
    Color? onCitrusContainer,
    Color? onCitrus,
  }) {
    return AccentPalette(
      id: id ?? this.id,
      label: label ?? this.label,
      seed: seed ?? this.seed,
      brandDeep: brandDeep ?? this.brandDeep,
      brandBright: brandBright ?? this.brandBright,
      warm: warm ?? this.warm,
      warmDeep: warmDeep ?? this.warmDeep,
      warmBright: warmBright ?? this.warmBright,
      warmDark: warmDark ?? this.warmDark,
      warmContainer: warmContainer ?? this.warmContainer,
      onWarmContainer: onWarmContainer ?? this.onWarmContainer,
      onWarm: onWarm ?? this.onWarm,
      cool: cool ?? this.cool,
      coolDeep: coolDeep ?? this.coolDeep,
      coolBright: coolBright ?? this.coolBright,
      coolContainer: coolContainer ?? this.coolContainer,
      onCoolContainer: onCoolContainer ?? this.onCoolContainer,
      onCool: onCool ?? this.onCool,
      citrus: citrus ?? this.citrus,
      citrusBright: citrusBright ?? this.citrusBright,
      citrusContainer: citrusContainer ?? this.citrusContainer,
      onCitrusContainer: onCitrusContainer ?? this.onCitrusContainer,
      onCitrus: onCitrus ?? this.onCitrus,
    );
  }

  @override
  AccentPalette lerp(AccentPalette? other, double t) {
    if (other == null) return this;
    Color? l(Color a, Color b) => Color.lerp(a, b, t);
    return AccentPalette(
      id: id,
      label: label,
      seed: l(seed, other.seed)!,
      brandDeep: l(brandDeep, other.brandDeep)!,
      brandBright: l(brandBright, other.brandBright)!,
      warm: l(warm, other.warm)!,
      warmDeep: l(warmDeep, other.warmDeep)!,
      warmBright: l(warmBright, other.warmBright)!,
      warmDark: l(warmDark, other.warmDark)!,
      warmContainer: l(warmContainer, other.warmContainer)!,
      onWarmContainer: l(onWarmContainer, other.onWarmContainer)!,
      onWarm: l(onWarm, other.onWarm)!,
      cool: l(cool, other.cool)!,
      coolDeep: l(coolDeep, other.coolDeep)!,
      coolBright: l(coolBright, other.coolBright)!,
      coolContainer: l(coolContainer, other.coolContainer)!,
      onCoolContainer: l(onCoolContainer, other.onCoolContainer)!,
      onCool: l(onCool, other.onCool)!,
      citrus: l(citrus, other.citrus)!,
      citrusBright: l(citrusBright, other.citrusBright)!,
      citrusContainer: l(citrusContainer, other.citrusContainer)!,
      onCitrusContainer: l(onCitrusContainer, other.onCitrusContainer)!,
      onCitrus: l(onCitrus, other.onCitrus)!,
    );
  }
}

/// 撞色方案读取入口：页面统一用 `ClashPalette.of(context)` 取三主色，
/// 不再各自 `Theme.of(context).extension<AccentPalette>()`。
///
/// 主题未注册时回退到 [clashAccent]（正常渲染不会发生，防御测试环境
/// 手工构造 ThemeData 的场景）。
abstract final class ClashPalette {
  static AccentPalette of(BuildContext context) =>
      Theme.of(context).extension<AccentPalette>() ?? clashAccent;

  /// 当前是否为深色模式（撞色块在深色下的用法不同：亮度更高、投影更重）。
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 主色（当前主题的暖色，即 `scheme.primary` 的撞色来源）。
  static Color warm(BuildContext context) => of(context).warm;

  /// 次级撞色（冷藏青，即 `scheme.secondary` 来源）。
  static Color cool(BuildContext context) => of(context).cool;

  /// 点缀强调（青柠）。
  static Color citrus(BuildContext context) => of(context).citrus;
}

/// **暖橙 × 冷藏青**（默认撞色方案，id `clash`）：本应用的新设计语言
/// 基准。三主色均由 `tool/clash_palette_solver.dart` 求解并通过
/// WCAG 2.1 AA（见 contrast_test）。
const AccentPalette clashAccent = AccentPalette(
  id: 'clash',
  label: '暖橙 × 冷藏青',
  seed: AppTokens.clashWarm,
  brandDeep: AppTokens.clashWarmDeep,
  brandBright: AppTokens.clashWarmBright,
  warm: AppTokens.clashWarm,
  warmDeep: AppTokens.clashWarmDeep,
  warmBright: AppTokens.clashWarmBright,
  warmDark: Color(0xFF8A3009),
  warmContainer: AppTokens.clashWarmContainer,
  onWarmContainer: AppTokens.clashWarmInk,
  onWarm: Color(0xFFFFFFFF),
  cool: AppTokens.clashCool,
  coolDeep: AppTokens.clashCoolDeep,
  coolBright: AppTokens.clashCoolBright,
  coolContainer: AppTokens.clashCoolContainer,
  onCoolContainer: AppTokens.clashCoolInk,
  onCool: Color(0xFFFFFFFF),
  citrus: AppTokens.clashCitrus,
  citrusBright: AppTokens.clashCitrusBright,
  citrusContainer: AppTokens.clashCitrusContainer,
  onCitrusContainer: AppTokens.clashCitrusInk,
  onCitrus: Color(0xFFFFFFFF),
);

/// **电光青 × 青柠**（id `electric`）：冷调撞色变体，主色青、点缀青柠，
/// 暖色退为强调（图表与徽标）。适合偏好冷峻科技感的用户。
const AccentPalette electricAccent = AccentPalette(
  id: 'electric',
  label: '电光青 × 青柠',
  seed: Color(0xFF0E6E6B),
  brandDeep: Color(0xFF08504E),
  brandBright: Color(0xFF4FD1C5),
  warm: Color(0xFF0E6E6B),
  warmDeep: Color(0xFF08504E),
  warmBright: Color(0xFF4FD1C5),
  warmDark: Color(0xFF0A5250),
  warmContainer: Color(0xFFCBE9E7),
  onWarmContainer: Color(0xFF03302E),
  onWarm: Color(0xFFFFFFFF),
  cool: Color(0xFF4D7C0F),
  coolDeep: Color(0xFF3A5E0B),
  coolBright: Color(0xFFBBD65C),
  coolContainer: Color(0xFFE6F0CB),
  onCoolContainer: Color(0xFF22370A),
  onCool: Color(0xFFFFFFFF),
  citrus: Color(0xFFC63D0F),
  citrusBright: Color(0xFFFF8A4C),
  citrusContainer: Color(0xFFFFE3D3),
  onCitrusContainer: Color(0xFF5A1A00),
  onCitrus: Color(0xFFFFFFFF),
);

/// **紫罗兰 × 暖橙**（id `violet`）：冷暖反差最大的撞色变体，
/// 紫做主结构、橙做主动作，视觉冲击最强。
const AccentPalette violetAccent = AccentPalette(
  id: 'violet',
  label: '紫罗兰 × 暖橙',
  seed: Color(0xFF5B3FA8),
  brandDeep: Color(0xFF412C7C),
  brandBright: Color(0xFF8E74D8),
  warm: Color(0xFF5B3FA8),
  warmDeep: Color(0xFF412C7C),
  warmBright: Color(0xFF8E74D8),
  warmDark: Color(0xFF4A2F8F),
  warmContainer: Color(0xFFE4DBFB),
  onWarmContainer: Color(0xFF241154),
  onWarm: Color(0xFFFFFFFF),
  cool: Color(0xFFC63D0F),
  coolDeep: Color(0xFF9E2F0A),
  coolBright: Color(0xFFFF8A4C),
  coolContainer: Color(0xFFFFE3D3),
  onCoolContainer: Color(0xFF5A1A00),
  onCool: Color(0xFFFFFFFF),
  citrus: Color(0xFF0E6E6B),
  citrusBright: Color(0xFF4FD1C5),
  citrusContainer: Color(0xFFCBE9E7),
  onCitrusContainer: Color(0xFF03302E),
  onCitrus: Color(0xFFFFFFFF),
);

/// 品牌绿（legacy id `green`）：v1 默认色系，仅为已持久化该值的老数据
/// 保留渲染路径。新装默认走 [clashAccent]。
const AccentPalette greenAccent = AccentPalette(
  id: 'green',
  label: '品牌绿',
  seed: Color(0xFF3F6C51),
  brandDeep: Color(0xFF3F6C51),
  brandBright: Color(0xFF5C8A6E),
  warm: Color(0xFF3F6C51),
  warmDeep: Color(0xFF2C4D39),
  warmBright: Color(0xFF5C8A6E),
  warmDark: Color(0xFF2F5F44),
  warmContainer: Color(0xFFD8E8DC),
  onWarmContainer: Color(0xFF10281A),
  onWarm: Color(0xFFFFFFFF),
  cool: Color(0xFF0E6E6B),
  coolDeep: Color(0xFF08504E),
  coolBright: Color(0xFF4FD1C5),
  coolContainer: Color(0xFFCBE9E7),
  onCoolContainer: Color(0xFF03302E),
  onCool: Color(0xFFFFFFFF),
  citrus: Color(0xFF4D7C0F),
  citrusBright: Color(0xFFBBD65C),
  citrusContainer: Color(0xFFE6F0CB),
  onCitrusContainer: Color(0xFF22370A),
  onCitrus: Color(0xFFFFFFFF),
);

/// 专业藏蓝（legacy id `blue`）：同 [greenAccent]，为老数据保留。
const AccentPalette blueAccent = AccentPalette(
  id: 'blue',
  label: '专业藏蓝',
  seed: Color(0xFF3F6FA3),
  brandDeep: Color(0xFF3F6FA3),
  brandBright: Color(0xFF5F87B5),
  warm: Color(0xFF3F6FA3),
  warmDeep: Color(0xFF2A4C73),
  warmBright: Color(0xFF6E9BC9),
  warmDark: Color(0xFF2E5480),
  warmContainer: Color(0xFFD6E4F2),
  onWarmContainer: Color(0xFF102844),
  onWarm: Color(0xFFFFFFFF),
  cool: Color(0xFF0E6E6B),
  coolDeep: Color(0xFF08504E),
  coolBright: Color(0xFF4FD1C5),
  coolContainer: Color(0xFFCBE9E7),
  onCoolContainer: Color(0xFF03302E),
  onCool: Color(0xFFFFFFFF),
  citrus: Color(0xFF4D7C0F),
  citrusBright: Color(0xFFBBD65C),
  citrusContainer: Color(0xFFE6F0CB),
  onCitrusContainer: Color(0xFF22370A),
  onCitrus: Color(0xFFFFFFFF),
);

/// 撞色方案注册表：设置页选项、主题派生、app 换肤统一从这里取。
/// 前三项是 v2 撞色方案（设置页展示），后两项为 legacy 老数据兼容。
const Map<String, AccentPalette> accentPalettes = {
  'clash': clashAccent,
  'electric': electricAccent,
  'violet': violetAccent,
  'green': greenAccent,
  'blue': blueAccent,
};

/// 设置页只展示 v2 撞色方案（legacy 不出现，但老数据仍能正确渲染）。
const List<String> clashPaletteOrder = ['clash', 'electric', 'violet'];

/// 按持久化 id 取撞色方案；未知/null 回退默认撞色（新装用户即得到新语言）。
AccentPalette accentPaletteById(String? id) => accentPalettes[id] ?? clashAccent;
