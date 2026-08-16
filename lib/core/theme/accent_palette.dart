import 'package:flutter/material.dart';

/// 色系方案（2026-08-16 主题色解耦）。
///
/// 一个色系 = 一份声明，注册进 [accentPalettes] 即全应用生效：
/// - [seed]：M3 `ColorScheme.fromSeed` 派生种子，驱动按钮/选中格/进度环等
///   全部 `scheme.primary` 消费点自动换色；
/// - [brandDeep]/[brandBright]：hero 渐变卡（今天页倒计时卡、目标详情页
///   头部）的深/浅端——亮端按色系**受控提亮**（hero 上白字），避免任意
///   seed 直接当渐变亮端导致对比度不足。
///
/// 经 [ThemeData.extensions] 注册（见 `AppTheme._base`），页面用
/// `Theme.of(context).extension<AccentPalette>()` 读取 brand 色。
///
/// 以后新增色系 = 定义常量 + 注册表加一项；设置页/主题派生/渐变卡全自动。
class AccentPalette extends ThemeExtension<AccentPalette> {
  const AccentPalette({
    required this.id,
    required this.label,
    required this.seed,
    required this.brandDeep,
    required this.brandBright,
  });

  /// 持久化标识（schema v14 `settings.accent_color` 取值）。
  final String id;

  /// 设置页显示名。
  final String label;

  /// M3 色板派生种子。
  final Color seed;

  /// hero 渐变深端（同 seed 色相）。
  final Color brandDeep;

  /// hero 渐变浅端（同色相受控提亮）。
  final Color brandBright;

  @override
  AccentPalette copyWith({
    String? id,
    String? label,
    Color? seed,
    Color? brandDeep,
    Color? brandBright,
  }) {
    return AccentPalette(
      id: id ?? this.id,
      label: label ?? this.label,
      seed: seed ?? this.seed,
      brandDeep: brandDeep ?? this.brandDeep,
      brandBright: brandBright ?? this.brandBright,
    );
  }

  @override
  AccentPalette lerp(AccentPalette? other, double t) {
    if (other == null) return this;
    return AccentPalette(
      id: id,
      label: label,
      seed: Color.lerp(seed, other.seed, t)!,
      brandDeep: Color.lerp(brandDeep, other.brandDeep, t)!,
      brandBright: Color.lerp(brandBright, other.brandBright, t)!,
    );
  }
}

/// 品牌绿（默认色系，id `green`）：取值与既有
/// `kTimeCalcSeedColor`/`AppTokens.brandDeep/brandBright` 一致。
const AccentPalette greenAccent = AccentPalette(
  id: 'green',
  label: '绿色',
  seed: Color(0xFF3F6C51),
  brandDeep: Color(0xFF3F6C51),
  brandBright: Color(0xFF5C8A6E),
);

/// 专业藏蓝（id `blue`）：商务蓝种子；渐变亮端 `0xFF5C8AC2` 为受控提亮，
/// 保证白字对比度（模板 A「同色深浅表达层次」）。
const AccentPalette blueAccent = AccentPalette(
  id: 'blue',
  label: '蓝色',
  seed: Color(0xFF3A6EA5),
  brandDeep: Color(0xFF3A6EA5),
  brandBright: Color(0xFF5C8AC2),
);

/// 色系注册表：设置页选项、主题派生、app 换肤统一从这里取色系。
/// 显式字符串 key（常量表达式内不能访问 const 实例字段）。
const Map<String, AccentPalette> accentPalettes = {
  'green': greenAccent,
  'blue': blueAccent,
};

/// 按持久化 id 取色系（未知值回退绿色，与 settings 未知 themeMode 回退
/// system 同语义）。
AccentPalette accentPaletteById(String? id) =>
    accentPalettes[id] ?? greenAccent;
