import 'package:flutter/material.dart';

import 'section_header.dart';

/// 可折叠区块（2026-08-18）：区块头整行可点展开/收起，供目标详情页
/// 里程碑/科目/任务等长列表区块统一收纳——内容多时收起区块即可避免
/// 整页无限滚动。头部复用 SectionHeader，trailing 结构为「折叠摘要（如
/// N 个）+ 展开/收起 chevron + 外部操作按钮」；内容用 AnimatedSize 平滑
/// 展开收起（与进度页 _StatNote 同款动画）。
///
/// 两种用法：
/// - 非受控（默认）：折叠状态组件内部维护，点头部切换；
/// - 受控（传入 [expanded] + [onChanged]）：状态由外部持有，用于外部需要
///   感知/改变折叠状态的场景（如添加成功后自动展开、或按状态决定是否
///   渲染自身 sliver 列表）。
///
/// [body] 为空时组件只渲染头部（AnimatedSize 收起为空），内容由外部按
/// 折叠状态自行渲染（TaskListSection 的 sliver 列表即此用法）。
class CollapsibleSection extends StatefulWidget {
  const CollapsibleSection({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.summary,
    this.body,
    this.expanded,
    this.onChanged,
    this.initialExpanded = true,
  });

  final IconData icon;
  final String title;

  /// 头部右侧操作（如「添加里程碑」），展开/折叠时均显示。
  final Widget? trailing;

  /// 折叠时显示的规模摘要（如「12 个」）；展开时列表本身可见，不显示。
  final String? summary;

  /// 展开时显示的内容。为空时组件只渲染头部，内容由外部按状态渲染。
  final Widget? body;

  /// 受控模式：传入后折叠状态由外部持有，需配合 [onChanged] 同步更新。
  final bool? expanded;

  /// 折叠状态变化回调（受控模式负责更新外部状态；非受控模式可选监听）。
  final ValueChanged<bool>? onChanged;

  /// 非受控模式下的初始状态（默认展开，保持区块内容默认可见）。
  final bool initialExpanded;

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
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
          child: SectionHeader(
            icon: widget.icon,
            title: widget.title,
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
