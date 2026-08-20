import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/data/settings_repository_provider.dart';
import '../theme/app_tokens.dart';

/// 全局动效控制（2026-08-20 动效改造）。
///
/// 「减少动画」开关（schema v15 `Settings.reduce_motion`，外观页切换）开启
/// 后，全局过渡/入场动效时长归零（直接显示），仅保留必要操作反馈
/// （勾选回弹、hover 光标等短交互）。各页新增动画统一从这里取时长/开关，
/// 避免散落魔法数字与漏接开关。
///
/// 设计原则：跟随项目既有的「克制动效」语言——动画限定在局部小 widget、
/// 不引入整页 transform；reduce 模式下直接显示，不做半吊子降速。
class MotionController {
  const MotionController({required this.enabled});

  /// 是否启用过渡/入场动效（开启「减少动画」时为 false）。
  final bool enabled;

  /// 过渡动效时长：reduce 模式归零（直接显示），否则取 [duration]。
  Duration duration(Duration duration) => enabled ? duration : Duration.zero;

  /// 过渡曲线：reduce 模式用线性（时长归零时无实际作用）。
  Curve get curve => enabled ? AppTokens.motionCurve : Curves.linear;

  /// 是否应跳过入场类动效（reduce 模式）。
  bool get skipEntrance => !enabled;
}

/// 全局动效开关状态：读「减少动画」设置，随 [settingsProvider] 失效重建。
final motionControllerProvider = Provider<MotionController>((ref) {
  // valueOrNull 兜底：设置未加载/出错时按默认（启用动效），避免页面闪烁。
  final reduce = ref.watch(settingsProvider).valueOrNull?.reduceMotion ?? false;
  return MotionController(enabled: !reduce);
});
