import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/theme/app_theme.dart';

/// 主题对比度测试（NFR-4：文本与背景对比度以 WCAG 2.1 AA 为目标）。
///
/// 对浅色/深色主题的关键「前景/背景」色对计算对比度，断言 ≥ 4.5:1
/// （普通文本 AA 标准）。数值同时记录到 M4 里程碑验收记录。
///
/// 说明：热力图/甘特图色块为装饰性图形，信息由 tooltip 与图例文本承载
/// （M3 已落实，不在此对比度断言范围）。
void main() {
  for (final (name, theme) in [
    ('浅色', AppTheme.light()),
    ('深色', AppTheme.dark()),
  ]) {
    final scheme = theme.colorScheme;
    group('$name主题关键色对对比度（WCAG 2.1 AA ≥ 4.5）', () {
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
      test('日历普通格 onSurface/surfaceContainerLow', () {
        expect(
          _contrast(scheme.onSurface, scheme.surfaceContainerLow),
          greaterThanOrEqualTo(4.5),
        );
      });
    });
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
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  // Color.r/g/b 为 0..1 的 double。
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}
