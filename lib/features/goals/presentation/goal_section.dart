import 'package:flutter/material.dart';

import '../../../core/database/database.dart';
import '../../../core/database/tables.dart';
import '../../../services/countdown_service.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';

/// 目标模块撞色取色（docs/ui-refactor-contract.md §1）：
/// - 进行中 / 未逾期 = 暖（warm，品牌与主动作）；
/// - 已完成 = 点缀（citrus，成就徽标）；
/// - 逾期 / 已放弃 = 危险（danger）；
/// - 已归档 = 冷（cool，历史/数据语义）。
///
/// 只挑「撞色角色」，不挑色值——三套撞色方案换肤时全站自动跟随。
ClashTone goalClashTone(Goal goal, CountdownPhase phase) {
  if (goal.status == GoalStatus.completed) return ClashTone.citrus;
  if (goal.status == GoalStatus.abandoned) return ClashTone.danger;
  if (goal.status == GoalStatus.archived) return ClashTone.cool;
  if (phase == CountdownPhase.overdue) return ClashTone.danger;
  return ClashTone.warm;
}

/// 倒计时提示的撞色角色（与 [goalClashTone] 分开：卡片主色表达目标状态，
/// 倒计时提示色表达「时间压力」——逾期始终是危险色，与状态色无关）。
ClashTone countdownClashTone(CountdownPhase phase) {
  switch (phase) {
    case CountdownPhase.overdue:
      return ClashTone.danger;
    case CountdownPhase.terminated:
      return ClashTone.cool;
    case CountdownPhase.today:
    case CountdownPhase.upcoming:
      return ClashTone.warm;
  }
}

/// 目标模块的**撞色可折叠区块**。
///
/// 为什么不用共享的 `CollapsibleSection`：两者已分叉——本组件用
/// `scheme.outline` 取摘要/箭头色、圆角 8、动效时长硬编码，共享组件走
/// `ClashTones` 与 `AppTokens`；共享组件保持冻结，故在目标模块内用同样的
/// 交互契约重新组装：整行可点折叠、trailing 内嵌按钮优先消费点击、
/// AnimatedSize 平滑展开收起、`expanded` + `onChanged` 受控模式语义一致。
class GoalCollapsibleSection extends StatefulWidget {
  const GoalCollapsibleSection({
    super.key,
    required this.icon,
    required this.title,
    this.tone = ClashTone.warm,
    this.trailing,
    this.summary,
    this.body,
    this.expanded,
    this.onChanged,
    this.initialExpanded = true,
  });

  final IconData icon;
  final String title;

  /// 本区块的撞色归属（里程碑 = citrus、科目/任务 = cool、目标 = warm）。
  final ClashTone tone;

  /// 头部右侧操作（如「添加里程碑」），展开/折叠时均显示。
  final Widget? trailing;

  /// 折叠时显示的规模摘要（如「12 个」）；展开时列表本身可见，不显示。
  final String? summary;

  /// 展开时显示的内容。为空时组件只渲染头部，内容由外部按状态渲染。
  final Widget? body;

  /// 受控模式：传入后折叠状态由外部持有，需配合 [onChanged] 同步更新。
  final bool? expanded;

  /// 折叠状态变化回调。
  final ValueChanged<bool>? onChanged;

  /// 非受控模式下的初始状态（默认展开，保持区块内容默认可见）。
  final bool initialExpanded;

  @override
  State<GoalCollapsibleSection> createState() => _GoalCollapsibleSectionState();
}

class _GoalCollapsibleSectionState extends State<GoalCollapsibleSection> {
  late bool _expanded = widget.initialExpanded;

  bool get _isExpanded => widget.expanded ?? _expanded;

  void _toggle() {
    if (widget.expanded != null) {
      widget.onChanged?.call(!widget.expanded!);
    } else {
      setState(() => _expanded = !_expanded);
      widget.onChanged?.call(_expanded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _isExpanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 整行可点折叠。trailing 内嵌的操作按钮自身消费点击，不触发折叠
        // （嵌套手势内层优先）。
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(8),
          child: ClashSectionHeader(
            icon: widget.icon,
            title: widget.title,
            tone: widget.tone,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!expanded && widget.summary != null) ...[
                  Text(
                    widget.summary!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                  const SizedBox(width: 8),
                ],
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: scheme.outline,
                ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: expanded && widget.body != null
              ? widget.body!
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
