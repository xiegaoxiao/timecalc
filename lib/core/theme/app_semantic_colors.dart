import 'package:flutter/material.dart';

/// 语义色 token（M13）：警告/成功/信息三组，浅深两套。
///
/// 背景：进度/时间管理工具里「错误」与「警告」此前共用 scheme.error 红色，
/// 过载（超出可用时长）与逾期/失败无法靠颜色区分。这里为各语义提供
/// 独立的 文字色 + 容器色 两组，供页面直接取用；语义文案仍有文字与图标
/// 承载（NFR-4：不只依赖颜色）。
///
/// 取值满足 WCAG 2.1 AA（文字级 ≥4.5:1，容器/文字对也 ≥4.5:1），
/// 由 contrast_test 循环固化。
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.info,
    required this.onInfo,
    required this.infoContainer,
    required this.onInfoContainer,
  });

  /// 警告（如超出每日可用时长）：文字色。
  final Color warning;

  /// 警告背景上的文字色。
  final Color onWarning;

  /// 警告容器色（浅底，配合图标/文字使用）。
  final Color warningContainer;

  /// 警告容器上的文字色。
  final Color onWarningContainer;

  /// 成功（如目标已完成/提前完成）：文字色。
  final Color success;

  /// 成功背景上的文字色。
  final Color onSuccess;

  /// 成功容器色。
  final Color successContainer;

  /// 成功容器上的文字色。
  final Color onSuccessContainer;

  /// 信息（中性提示）：文字色。
  final Color info;

  /// 信息背景上的文字色。
  final Color onInfo;

  /// 信息容器色。
  final Color infoContainer;

  /// 信息容器上的文字色。
  final Color onInfoContainer;

  /// 从当前主题读取语义色（主题已注册 extensions，正常渲染必命中）。
  static AppSemanticColors of(BuildContext context) {
    return Theme.of(context).extension<AppSemanticColors>()!;
  }

  static AppSemanticColors light() => const AppSemanticColors(
    // 深琥珀：浅色表面（#F6F6F6）上 5.7:1。
    warning: Color(0xFF8F5200),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFDEA6),
    onWarningContainer: Color(0xFF4A2F00),
    // 深绿：浅色表面上 4.75:1。
    success: Color(0xFF2E7D32),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFA5D6A7),
    onSuccessContainer: Color(0xFF0D3310),
    // 深蓝：浅色表面上 5.32:1。
    info: Color(0xFF1565C0),
    onInfo: Color(0xFFFFFFFF),
    infoContainer: Color(0xFFBBDEFB),
    onInfoContainer: Color(0xFF0C2E56),
  );

  static AppSemanticColors dark() => const AppSemanticColors(
    // 亮琥珀：深色表面上 9.9:1。
    warning: Color(0xFFF5B84C),
    onWarning: Color(0xFF4A2F00),
    warningContainer: Color(0xFF6B4A00),
    onWarningContainer: Color(0xFFFFDEA6),
    // 亮绿。
    success: Color(0xFF81C784),
    onSuccess: Color(0xFF0D3310),
    successContainer: Color(0xFF2E5A31),
    onSuccessContainer: Color(0xFFA5D6A7),
    // 亮蓝。
    info: Color(0xFF90CAF9),
    onInfo: Color(0xFF0C2E56),
    infoContainer: Color(0xFF244F7E),
    onInfoContainer: Color(0xFFBBDEFB),
  );

  @override
  AppSemanticColors copyWith({
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? info,
    Color? onInfo,
    Color? infoContainer,
    Color? onInfoContainer,
  }) {
    return AppSemanticColors(
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      info: info ?? this.info,
      onInfo: onInfo ?? this.onInfo,
      infoContainer: infoContainer ?? this.infoContainer,
      onInfoContainer: onInfoContainer ?? this.onInfoContainer,
    );
  }

  @override
  AppSemanticColors lerp(covariant AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      onWarningContainer: Color.lerp(
        onWarningContainer,
        other.onWarningContainer,
        t,
      )!,
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      onSuccessContainer: Color.lerp(
        onSuccessContainer,
        other.onSuccessContainer,
        t,
      )!,
      info: Color.lerp(info, other.info, t)!,
      onInfo: Color.lerp(onInfo, other.onInfo, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      onInfoContainer: Color.lerp(onInfoContainer, other.onInfoContainer, t)!,
    );
  }
}
