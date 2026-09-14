import 'package:flutter/material.dart';

import '../domain/course_palette.dart';

/// 课程配色文本（`#RRGGBB`，见 [CoursePalette]）→ [Color]。
///
/// 非法/缺失值回退 [CoursePalette.defaultHex]——配色只影响观感，不该让
/// 一条脏数据把整张网格渲染搞崩（备份恢复/手工改库都可能带来脏值）。
Color courseColorOf(String? hex) {
  final text = hex == null ? '' : hex.trim();
  if (!CoursePalette.isValid(text)) {
    return _parse(CoursePalette.defaultHex);
  }
  return _parse(text);
}

/// 课程卡片的强调色变体：以配色为底、按主题明暗取不同透明度。
///
/// 只做「淡色底纹」而不是实心填充，是为了让卡片上的正文沿用主题前景色
/// （onSurface/onSurfaceVariant），浅色与深色主题下都无需逐色校验对比度；
/// 颜色差异由左侧竖条与底纹共同表达（NFR-4：不只依赖颜色也看结构——
/// 标题/地点/节次文本本身即可区分）。
Color courseTint(Color color, Brightness brightness) =>
    color.withValues(alpha: brightness == Brightness.dark ? 0.26 : 0.14);

/// 把 [color] 解析为不透明 [Color]。
Color _parse(String hex) {
  final value = int.parse(hex.substring(1), radix: 16);
  return Color(0xFF000000 | value);
}
