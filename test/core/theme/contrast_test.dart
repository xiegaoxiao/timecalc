import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/theme/accent_palette.dart';
import 'package:timecalc/core/theme/app_semantic_colors.dart';
import 'package:timecalc/core/theme/app_theme.dart';

/// 主题对比度测试（NFR-4：文本与背景对比度以 WCAG 2.1 AA 为目标）。
///
/// 对浅色/深色主题的关键「前景/背景」色对计算对比度，断言 ≥ 4.5:1
/// （普通文本 AA 标准）。
///
/// **v2.0 撞色重构后的强化**：
/// - 覆盖范围从 2 套色系扩到**注册表全部**（撞色三方案 + 2 个 legacy），
///   新增色系忘记验对比度会被本测试挡住；
/// - 主题改为显式构造 `ColorScheme`，`scheme.surface == 页面底色`，
///   因此本测试断言的「xxx/surface」**就是用户真实看到的色对**
///   （v1 时代 `scheme.surface` 与页面底色不一致，断言的是另一个颜色）；
/// - 新增「实心主色按钮填充/白字」断言：深色模式的主色填充另取
///   [AccentPalette.warmDark]，与 `scheme.primary`（图标/文字语义）分离。
///
/// 色值由 `tool/clash_palette_solver.dart` 求解后固化到
/// `app_tokens.dart` / `accent_palette.dart`。
///
/// 说明：热力图色块为装饰性图形，信息由 tooltip 与图例文本承载
/// （M3 已落实，不在此对比度断言范围）。
void main() {
  for (final entry in accentPalettes.entries) {
    final accentName = entry.key;
    final accent = entry.value;
    for (final (brightnessName, theme) in [
      ('浅色', AppTheme.light(accent: accent)),
      ('深色', AppTheme.dark(accent: accent)),
    ]) {
      final scheme = theme.colorScheme;
      final semantics = theme.extension<AppSemanticColors>()!;
      final isDark = theme.brightness == Brightness.dark;
      group('$accentName$brightnessName主题关键色对对比度（WCAG 2.1 AA ≥ 4.5）', () {
      test('正文文本 onSurface/surface', () {
        expect(
          _contrast(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('错误文本 error/surface', () {
        expect(
          _contrast(scheme.error, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('错误容器 onErrorContainer/errorContainer', () {
        expect(
          _contrast(scheme.onErrorContainer, scheme.errorContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('主色按钮 onPrimary/primary', () {
        expect(
          _contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('实心主色按钮 白字/填充底色（深色取 warmDark）', () {
        final fill = isDark ? accent.warmDark : accent.warm;
        expect(
          _contrast(Colors.white, fill),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('主容器 onPrimaryContainer/primaryContainer（今天高亮格）', () {
        expect(
          _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('次容器 onSecondaryContainer/secondaryContainer（选中日期格）', () {
        expect(
          _contrast(scheme.onSecondaryContainer, scheme.secondaryContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('点缀容器 onTertiaryContainer/tertiaryContainer（里程碑徽标）', () {
        expect(
          _contrast(scheme.onTertiaryContainer, scheme.tertiaryContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('日历普通格 onSurface/surfaceContainerLow', () {
        expect(
          _contrast(scheme.onSurface, scheme.surfaceContainerLow),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('次级文字 onSurfaceVariant/surface', () {
        expect(
          _contrast(scheme.onSurfaceVariant, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('警告文本 warning/surface（超出可用时长等提醒）', () {
        expect(
          _contrast(semantics.warning, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('警告容器 onWarningContainer/warningContainer', () {
        expect(
          _contrast(semantics.onWarningContainer, semantics.warningContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('成功文本 success/surface（目标完成等）', () {
        expect(
          _contrast(semantics.success, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('成功容器 onSuccessContainer/successContainer', () {
        expect(
          _contrast(semantics.onSuccessContainer, semantics.successContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('信息文本 info/surface（中性提示）', () {
        expect(
          _contrast(semantics.info, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('信息容器 onInfoContainer/infoContainer', () {
        expect(
          _contrast(semantics.onInfoContainer, semantics.infoContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
      });
    }
  }
}

/// 计算 [fg] 相对 [bg] 的 WCAG 对比度（1～21，越大越好）。
double _contrast(Color fg, Color bg) {
  final l1 = _relativeLuminance(fg);
  final l2 = _relativeLuminance(bg);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color color) {
  double channel(double v) {
    return v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  // Color.r/g/b 为 0..1 的 double。
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}
