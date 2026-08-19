import 'package:flutter/material.dart';

/// 统一的圆形完成复选框（Things 式圆环勾选）。
///
/// 今天页任务与目标详情/里程碑页共用，保证「完成勾选」在各场景视觉与
/// 交互一致：圆形描边 → 实心填充 + 白勾。
///
/// 语义文案由调用方按实体提供（NFR-4：完成状态不只依赖颜色，需可读屏
/// 识别，故不改用 defaultTextStyle 透传，显式传 [semanticLabel]）。
class CompletionCheckbox extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Checkbox(
      value: value,
      semanticLabel: semanticLabel,
      onChanged: onChanged,
      // 圆形描边 → 实心填充 + 白勾：保持 Checkbox 类型与语义，
      // 测试（tap/semantics）不受影响。
      shape: const CircleBorder(),
      side: BorderSide(
        width: 1.5,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}