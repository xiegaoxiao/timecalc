import 'package:flutter/material.dart';

/// 统一的圆形完成复选框（Things 式圆环勾选，带弹跳与对勾动画）。
///
/// 今天页任务与目标详情/里程碑页共用，保证「完成勾选」在各场景视觉与
/// 交互一致：圆形描边 → 实心填充 + 白勾。
///
/// 勾选时播放 180ms 缩放回弹（0.85 → 1.0），对勾淡入，反馈更灵动；
/// 取消勾选时平滑恢复描边状态。
///
/// 语义文案由调用方按实体提供（NFR-4：完成状态不只依赖颜色，需可读屏
/// 识别，故不改用 defaultTextStyle 透传，显式传 [semanticLabel]）。
class CompletionCheckbox extends StatefulWidget {
  const CompletionCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });

  /// 是否已完成。
  final bool value;

  /// 勾选状态切换回调。
  final ValueChanged<bool?>? onChanged;

  /// 读屏可读的勾选说明（如「标记完成」/「标记里程碑「xx」为已完成」）。
  final String semanticLabel;

  @override
  State<CompletionCheckbox> createState() => _CompletionCheckboxState();
}

class _CompletionCheckboxState extends State<CompletionCheckbox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _scale = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    if (widget.value) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant CompletionCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value && !oldWidget.value) {
      _controller.forward(from: 0.0);
    }
    // 取消勾选无需动画：build 中 scale 在未勾选时恒为 1.0，过渡由
    // AnimatedContainer/AnimatedOpacity 完成，reverse() 无视觉作用。
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    widget.onChanged?.call(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = widget.value ? scheme.primary : Colors.transparent;
    final borderColor = widget.value ? scheme.primary : scheme.outline;

    return Semantics(
      checked: widget.value,
      label: widget.semanticLabel,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onChanged == null ? null : _handleTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // 勾选时播放 0.85 → 1.0 弹性回弹；取消勾选保持 1.0。
                final scale = widget.value
                    ? Tween<double>(begin: 0.82, end: 1.0).evaluate(_scale)
                    : 1.0;
                return Transform.scale(scale: scale, child: child);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: activeColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: borderColor,
                    width: widget.value ? 0 : 1.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(
                        alpha: widget.value ? 0.25 : 0,
                      ),
                      blurRadius: widget.value ? 6 : 0,
                      spreadRadius: widget.value ? 1 : 0,
                    ),
                  ],
                ),
                child: AnimatedOpacity(
                  opacity: widget.value ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  child: const Icon(Icons.check, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
