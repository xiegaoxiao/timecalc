import 'package:flutter/material.dart';

/// TimeCalc 主题定义。
///
/// M1 提供浅色/深色两套 ThemeData，颜色以 Material 3 默认色板为基础，
/// 不做自定义品牌色，避免与参考项目的视觉设计混淆。
abstract final class AppTheme {
  static const Color _seedColor = Color(0xFF3F6C51);

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}
