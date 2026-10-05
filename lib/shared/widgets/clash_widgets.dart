import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'clash_tones.dart';

/// 撞色区块头：**左侧撞色竖条 + 撞色图标底 + 标题 + 计数徽标 + 尾部动作**。
///
/// 全站区块头的唯一实现（2026-10 起旧的 `SectionHeader` 已删除，调用点
/// 全部迁到这里）。本组件把「这一块属于哪个撞色」显式暴露出来
/// （[tone]），于是页面天然形成「暖块/冷块/点缀块」的节奏，
/// 而不需要每页自己写 import + 取色。
class ClashSectionHeader extends StatelessWidget {
  const ClashSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.tone = ClashTone.warm,
    this.subtitle,
    this.count,
    this.trailing,
    this.dense = false,
    this.foreground,
  });

  final IconData icon;
  final String title;

  /// 本区块的撞色归属。
  final ClashTone tone;

  final String? subtitle;

  /// 计数徽标（非空时在标题右侧显示撞色药丸，如「3 项」）。
  final int? count;

  /// 尾部内容（动作按钮、展开箭头等）。
  final Widget? trailing;

  /// 紧凑模式（用于卡片内的次级区块，字号与间距收一档）。
  final bool dense;

  /// 显式前景色（撞色竖条/图标底/标题/副标题统一用它，半透明区分层级）。
  ///
  /// 用途：区块头被放在 **hero 渐变上**时（`ClashHero` 内），按撞色推导的
  /// `ink`/`onSurface` 在渐变上没有对比度，必须显式传 `Colors.white`。
  /// 不传则保持原有按 tone 取色行为（**向后兼容**）。
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    final theme = Theme.of(context);
    final fg = foreground;
    final iconSize = dense ? 16.0 : 18.0;
    final barHeight = dense ? 16.0 : 20.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 撞色竖条：区块的「色标」，1px 宽的视觉锚点。
        Container(
          width: 3.5,
          height: barHeight,
          margin: EdgeInsets.only(right: dense ? 8 : 10),
          decoration: BoxDecoration(
            color: fg ?? t.ink,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Container(
          padding: EdgeInsets.all(dense ? 5 : 7),
          decoration: BoxDecoration(
            color: fg?.withValues(alpha: 0.18) ?? t.soft,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          child: Icon(icon, size: iconSize, color: fg ?? t.onSoft),
        ),
        SizedBox(width: dense ? 8 : 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (dense
                                  ? theme.textTheme.titleSmall
                                  : theme.textTheme.titleMedium)
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: fg ?? theme.colorScheme.onSurface,
                              ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    _CountPill(count: count!, tone: tone, foreground: fg),
                  ],
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color:
                        fg?.withValues(alpha: 0.85) ??
                        theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.tone, this.foreground});

  final int count;
  final ClashTone tone;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    final fg = foreground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: fg?.withValues(alpha: 0.22) ?? t.soft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg ?? t.onSoft,
        ),
      ),
    );
  }
}

/// 撞色统计小块：大号数字 + 标签 + 可选趋势说明。
///
/// 用在「今天」页概览、进度页 KPI 行：数字用撞色填充底白字，
/// 是页面里视觉重量最高的元素（生产力工具的主角是数字）。
///
/// [dense] 用于**矮视口**（如 500×400 的日历日面板、窄分栏预览）：把
/// 内边距、字号、圆角各收一档，高度从约 86px 降到约 46px，避免一排统计块
/// 把列表首行挤出可滚动视口（那时 `find.text` 会找不到、用户也看不到）。
///
/// **[maxWidth] 的必要性（踩坑记录）**：组件内部 `Column(crossAxisAlignment:
/// start)` 会让内容宽度由父级决定；直接放进 `Wrap` 时，`Wrap` 给子项的横向
/// 约束是「最多一行宽」，于是每块都吃满整行 → **永远一块一行**（3 块堆成
/// 3 行，高度翻倍）。需要并排时请显式给 `maxWidth`（或用 `SizedBox` 限宽），
/// 这样 `Wrap`/`Row` 才能把多块排在同一行。
class ClashStatTile extends StatelessWidget {
  const ClashStatTile({
    super.key,
    required this.value,
    required this.label,
    this.tone = ClashTone.warm,
    this.icon,
    this.hint,
    this.filled = true,
    this.dense = false,
    this.maxWidth,
  });

  /// 主数值文本（如「3」「72%」「1.5h」）。
  final String value;

  final String label;
  final ClashTone tone;
  final IconData? icon;

  /// 数值下方的辅助说明（趋势、对比等）。
  final String? hint;

  /// true＝实心撞色块白字；false＝浅色底撞色字（密集排布时更安静）。
  final bool filled;

  /// 紧凑形态（矮视口专用；见类文档）。
  final bool dense;

  /// 宽度上限（见类文档「maxWidth 的必要性」）。null＝由父级决定宽度。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    final theme = Theme.of(context);
    final fg = filled ? t.onFill : t.onSoft;
    final subFg = filled
        ? t.onFill.withValues(alpha: 0.82)
        : t.onSoft.withValues(alpha: 0.80);
    // dense：把统计块压到「单行标签 + 大数字」的紧凑形态。
    // 用途：矮视口（如 500×400 的日历日面板/分栏预览）下，若统计块保持
    // 常规高度（≈86px），会把列表首行挤出可滚动视口，从而「首屏看不到第一
    // 张卡」。dense 形态高约 46px，横向排布即可在矮窗口内让列表首行可见。
    final valueStyle =
        (dense ? theme.textTheme.titleLarge : theme.textTheme.headlineSmall)
            ?.copyWith(color: fg, fontWeight: FontWeight.w700);
    final labelStyle = (dense
            ? theme.textTheme.labelSmall
            : theme.textTheme.labelSmall)
        ?.copyWith(color: subFg, fontWeight: FontWeight.w600);
    final iconSize = dense ? 12.0 : 14.0;

    Widget tile = Container(
      padding: dense
          ? const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceMd,
              vertical: AppTokens.spaceSm,
            )
          : const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceLg,
              vertical: AppTokens.spaceMd,
            ),
      decoration: BoxDecoration(
        color: filled ? t.fill : t.soft,
        borderRadius: BorderRadius.circular(
          dense ? AppTokens.radiusMd : AppTokens.radiusLg,
        ),
        boxShadow: filled
            ? AppTokens.shadowTinted(t.fill, opacity: 0.22)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: iconSize, color: subFg),
                SizedBox(width: dense ? 4 : 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
            ],
          ),
          SizedBox(height: dense ? 2 : 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: valueStyle,
          ),
          if (hint != null && !dense) ...[
            const SizedBox(height: 2),
            Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: subFg,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
    if (maxWidth != null) {
      tile = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: tile,
      );
    }
    return tile;
  }
}

/// 撞色药丸标签（状态 chips、分类标签、图例项）。
///
/// [ClashChip.filled] 实心（醒目，用于当前筛选/关键状态），
/// [ClashChip.soft] 浅底（默认，用于次要标签），
/// [ClashChip.outlined] 描边（最轻，用于元信息）。
class ClashChip extends StatelessWidget {
  const ClashChip({
    super.key,
    required this.label,
    this.tone = ClashTone.warm,
    this.icon,
    this.variant = ClashChipVariant.soft,
    this.onTap,
    this.dense = false,
    this.foreground,
    this.background,
    this.flexible = false,
    this.maxWidth,
  });

  final String label;
  final ClashTone tone;
  final IconData? icon;
  final ClashChipVariant variant;
  final VoidCallback? onTap;
  final bool dense;

  /// 显式前景色，覆盖按 [tone] 推导的默认值。
  ///
  /// 用途：药丸被放在 **hero 渐变上**（如课表页把「本周」药丸放在
  /// `ClashHero` 内）时，按撞色推导的 `ink`/`onSoft` 在渐变上没有对比度，
  /// 必须显式传 `ClashTones.onFill`（白）。不传则保持原有按 tone 取色行为
  /// （**向后兼容**，老调用点不受影响）。
  final Color? foreground;

  /// 显式背景色，覆盖按 [variant] 推导的默认值（如 hero 上用半透明白底）。
  final Color? background;

  /// 窄容器内允许压缩：为 true 时给 [label] 加省略号并允许收缩。
  ///
  /// 背景：药丸默认按内容宽度自适应（`Row` + 不换行 `Text`），被放进
  /// **宽度受限**的父级（如 330px 侧面板里的 `Wrap`、卡片角标位）时，
  /// 超长文案会直接抛 `RenderFlex overflow`。此开关用于「宁可省略也不允许
  /// 溢出」的场景；默认 false 保持原有按内容自适应行为（**向后兼容**）。
  final bool flexible;

  /// [flexible] 为 true 时的最大宽度上限（超出即省略）。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    final (baseBg, baseFg, border) = switch (variant) {
      ClashChipVariant.filled => (t.fill, t.onFill, null),
      ClashChipVariant.soft => (t.soft, t.onSoft, null),
      ClashChipVariant.outlined => (
        Colors.transparent,
        t.ink,
        BorderSide(color: t.ink.withValues(alpha: 0.45)),
      ),
    };
    final bg = background ?? baseBg;
    final fg = foreground ?? baseFg;
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: flexible ? TextOverflow.ellipsis : TextOverflow.clip,
      softWrap: !flexible,
      style: TextStyle(
        fontSize: dense ? 11 : 12,
        fontWeight: FontWeight.w600,
        color: fg,
      ),
    );
    Widget chipBody = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: dense ? 11 : 13, color: fg),
          const SizedBox(width: 4),
        ],
        // 默认（非 flexible）保持原行为：不可收缩的不换行文本。
        if (flexible) Flexible(child: labelText) else labelText,
      ],
    );
    if (maxWidth != null) {
      chipBody = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: chipBody,
      );
    }
    final child = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: border == null ? null : Border.all(color: border.color),
      ),
      child: chipBody,
    );
    if (onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

/// [ClashChip] 的三种强度。
enum ClashChipVariant { filled, soft, outlined }

/// 撞色空态：无数据/无结果时的统一呈现（撞色圆底图标 + 主文案 + 说明 +
/// 可选动作），替代各页面自写的「灰图标 + 一句灰字」。
class ClashEmptyState extends StatelessWidget {
  const ClashEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.tone = ClashTone.cool,
    this.action,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final ClashTone tone;
  final Widget? action;

  /// 紧凑模式（卡片内空态，减小留白）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = ClashTones.of(context, tone);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppTokens.spaceXl,
          vertical: compact ? AppTokens.spaceLg : AppTokens.spaceXxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: compact ? 44 : 56,
              height: compact ? 44 : 56,
              decoration: BoxDecoration(
                color: t.soft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: compact ? 22 : 26,
                color: t.onSoft,
              ),
            ),
            SizedBox(height: compact ? AppTokens.spaceMd : AppTokens.spaceLg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppTokens.spaceLg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
