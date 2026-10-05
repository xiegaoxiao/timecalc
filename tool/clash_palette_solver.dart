// 撞色色板求解器（一次性工具，UI 重构期间用于精确求色）。
//
// 目标：为「暖橙 × 冷藏青」撞色语言求解满足 WCAG 2.1 AA（≥4.5:1）的
// 具体色值，避免手改颜色反复跑测试试错。
//
// 运行：dart run tool/clash_palette_solver.dart
import 'dart:math' as math;

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double lum(int hex) {
  final r = ((hex >> 16) & 0xFF) / 255.0;
  final g = ((hex >> 8) & 0xFF) / 255.0;
  final b = (hex & 0xFF) / 255.0;
  return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b);
}

double contrast(int a, int b) {
  final la = lum(a), lb = lum(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 在与 [bg] 保持对比度的前提下，按 [hue]/[sat] 方向把明度收到刚好达标。
/// 返回 (hex, 实测对比度)。
(int, double) darkenUntil(int fg, int bg, double target) {
  var best = fg;
  var bestC = contrast(fg, bg);
  if (bestC >= target) return (fg, bestC);
  // 朝黑色线性插值，步进 1%，取第一个达标的。
  for (var i = 1; i <= 100; i++) {
    final t = i / 100.0;
    int ch(int shift) {
      final v = (((fg >> shift) & 0xFF) * (1 - t)).round().clamp(0, 255);
      return v << shift;
    }

    final cand = ch(16) | ch(8) | ch(0);
    final c = contrast(cand, bg);
    if (c >= target) {
      best = cand;
      bestC = c;
      break;
    }
  }
  return (best, bestC);
}

String hex(int v) => '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';

void report(String label, int fg, int bg, {double target = 4.5}) {
  final c = contrast(fg, bg);
  final ok = c >= target ? 'OK  ' : 'FAIL';
  print(
    '$ok $label  ${hex(fg)} on ${hex(bg)}  '
    '${c.toStringAsFixed(2)}:1 (need $target)',
  );
}

void main() {
  print('=== 浅色模式候选 ===');
  const cream = 0xFFFDF6F0; // 暖奶油页底
  const white = 0xFFFFFFFF; // 卡片
  const ink = 0xFF1C1917; // 暖近黑正文
  const inkSoft = 0xFF57534E; // 暖次级灰

  // 主色橙：白字按钮 / 白底上的橙字两种约束
  for (final cand in [0xFFC63D0F, 0xFFC2410C, 0xFFB93A0C, 0xFFD24A12]) {
    final (d, dc) = darkenUntil(cand, white, 4.5);
    print(
      'orange ${hex(cand)}: onWhite(btn) ${contrast(cand, white).toStringAsFixed(2)}'
      ' | asTextOnWhite ${contrast(cand, white).toStringAsFixed(2)}'
      ' | autoDeep ${hex(d)} (${dc.toStringAsFixed(2)})',
    );
  }

  // 撞色青
  for (final cand in [0xFF0E6E6B, 0xFF0F766E, 0xFF0D6E6E, 0xFF127C76]) {
    print(
      'teal ${hex(cand)}: onWhite ${contrast(cand, white).toStringAsFixed(2)}'
      ' | onCream ${contrast(cand, cream).toStringAsFixed(2)}',
    );
  }

  // 点缀柠檬黄绿（青柠）
  for (final cand in [0xFF4D7C0F, 0xFF3F6212, 0xFF65840F, 0xFF4F7A0B]) {
    print(
      'lime ${hex(cand)}: onWhite ${contrast(cand, white).toStringAsFixed(2)}'
      ' | onCream ${contrast(cand, cream).toStringAsFixed(2)}',
    );
  }

  print('\n=== 定稿候选的完整检查（浅色） ===');
  const p = 0xFFC63D0F; // 主橙
  const pC = 0xFFFFE3D3; // 橙容器（浅）
  const s = 0xFF0E6E6B; // 冷藏青
  const sC = 0xFFCBE9E7; // 青容器
  const t = 0xFF4D7C0F; // 青柠点缀
  const tC = 0xFFE6F0CB; // 青柠容器
  report('onSurface/surface', ink, cream);
  report('onSurface/surfaceContainerLow', ink, white, target: 4.5);
  report('inkSoft/cream', inkSoft, cream);
  report('primary/white(btn fg)', white, p);
  report('primary as text on cream', p, cream);
  report('onPrimaryContainer/primaryContainer', 0xFF5A1A00, pC);
  report('secondary/white', white, s);
  report('onSecondaryContainer/secondaryContainer', 0xFF03302E, sC);
  report('tertiary/white', white, t);
  report('onTertiaryContainer/tertiaryContainer', 0xFF22370A, tC);
  report('error/cream', 0xFFB3261E, cream);
  report('onErrorContainer/errorContainer', 0xFF410E0B, 0xFFF9DEDC);
  report('warning text/cream', 0xFF8F5200, cream);
  report('onWarningContainer/warningContainer', 0xFF4A2F00, 0xFFFFDEA6);
  report('success text/cream', 0xFF2E7D32, cream);
  report('onSuccessContainer/successContainer', 0xFF0D3310, 0xFFA5D6A7);
  report('info text/cream', 0xFF1565C0, cream);
  report('onInfoContainer/infoContainer', 0xFF0C2E56, 0xFFBBDEFB);

  print('\n=== 定稿候选的完整检查（深色） ===');
  const dbg = 0xFF17120F; // 暖近黑页底
  const dsurf = 0xFF201A16; // 深卡面
  const dLow = 0xFF2A2320; // surfaceContainerLow
  const dInk = 0xFFF5EFE9; // 深色正文
  const dp = 0xFFFF8A4C; // 深色主橙（提亮）
  const dpC = 0xFF5A2410; // 深色橙容器
  const ds = 0xFF4FD1C5; // 深色青
  const dsC = 0xFF0F3D3B;
  const dt = 0xFFBBD65C; // 深色青柠
  const dtC = 0xFF33440F;
  report('onSurface/surface', dInk, dbg);
  report('onSurface/surfaceContainerLow', dInk, dLow);
  report('onSurface/dark card', dInk, dsurf);
  report('primary(dark)/dbg as text', dp, dbg);
  report('onPrimary/darkPrimary', 0xFF3A1400, dp);
  report('onPrimaryContainer/primaryContainer(dark)', 0xFFFFDBC8, dpC);
  report('secondary(dark)/dbg as text', ds, dbg);
  report('onSecondaryContainer/secondaryContainer(dark)', 0xFFC8F5F0, dsC);
  report('tertiary(dark)/dbg as text', dt, dbg);
  report('onTertiaryContainer/tertiaryContainer(dark)', 0xFFE4F2C0, dtC);
  report('error(dark)/dbg', 0xFFFFB4AB, dbg);
  report('onErrorContainer/errorContainer(dark)', 0xFFF9DEDC, 0xFF8C1D18);
  report('warning(dark)/dbg', 0xFFF5B84C, dbg);
  report('onWarningContainer/warningContainer(dark)', 0xFFFFDEA6, 0xFF6B4A00);
  report('success(dark)/dbg', 0xFF81C784, dbg);
  report('onSuccessContainer/successContainer(dark)', 0xFFA5D6A7, 0xFF2E5A31);
  report('info(dark)/dbg', 0xFF90CAF9, dbg);
  report('onInfoContainer/infoContainer(dark)', 0xFFBBDEFB, 0xFF244F7E);
}
