import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'clash_tones.dart';

/// 统一表单输入框装饰器。
///
/// 提供一致的 InputDecoration 样式，支持标签、提示文本、
/// 字数计数器、前后缀图标等。
class AppFormField extends StatelessWidget {
  const AppFormField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.readOnly = false,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.maxLines = 1,
    this.maxLength,
    this.counterText,
    this.onChanged,
    this.onFieldSubmitted,
    this.validator,
    this.contentPadding,
    this.enabled = true,
    this.child,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final bool readOnly;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int maxLines;
  final int? maxLength;
  final String? counterText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final FormFieldValidator<String>? validator;
  final EdgeInsetsGeometry? contentPadding;
  final bool enabled;

  /// 子组件模式：直接提供自定义输入组件。
  final Widget? child;

  /// 获取统一的 InputDecoration 样式。
  ///
  /// 颜色全部取自 [ColorScheme] / [AppTokens]（随主题明暗切换）：
  /// 填充用浅色表面、边框用 `outlineVariant`、
  /// 文字用 `onSurfaceVariant`、错误用 `error`。
  ///
  /// **聚焦态用冷藏青描边**（撞色语言：暖色主动作 / 冷色聚焦与对照），
  /// 与 `inputDecorationTheme.focusedBorder` 的冷色语义一致。
  static InputDecoration defaultDecoration({
    String? label,
    String? hint,
    Widget? prefixIcon,
    Widget? suffixIcon,
    String? errorText,
    String? helperText,
    String? counterText,
    EdgeInsetsGeometry? contentPadding,
    bool enabled = true,
    ColorScheme? scheme,
  }) {
    final baseFill = scheme == null
        ? AppTokens.neutralSurfaceLight
        : (scheme.brightness == Brightness.dark
              ? scheme.surfaceContainerLow
              : scheme.surfaceContainerLowest);
    final borderColor = scheme?.outlineVariant ?? AppTokens.neutralBorderLight;
    final textSecondary =
        scheme?.onSurfaceVariant ?? AppTokens.neutralTextSecondaryLight;
    // 聚焦描边（冷色）：与主题 inputDecorationTheme.focusedBorder 同一语义。
    final focusColor = scheme?.secondary ?? AppTokens.clashCool;
    final errorColor = scheme?.error;

    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helperText,
      errorText: errorText,
      counterText: counterText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      contentPadding:
          contentPadding ??
          const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceMd,
            vertical: AppTokens.spaceMd,
          ),
      filled: true,
      fillColor: enabled ? baseFill : scheme?.surfaceContainerLow,
      enabled: enabled,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      alignLabelWithHint: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        borderSide: BorderSide(color: focusColor, width: 1.5),
      ),
      errorBorder: errorColor == null
          ? null
          : OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              borderSide: BorderSide(color: errorColor, width: 1),
            ),
      focusedErrorBorder: errorColor == null
          ? null
          : OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              borderSide: BorderSide(color: errorColor, width: 1.5),
            ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        borderSide: BorderSide(
          color: borderColor.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      labelStyle: TextStyle(
        color: enabled ? textSecondary : borderColor.withValues(alpha: 0.7),
      ),
      hintStyle: TextStyle(color: textSecondary.withValues(alpha: 0.8)),
      counterStyle: TextStyle(fontSize: 12, color: textSecondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (child != null) {
      return child!;
    }

    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      readOnly: readOnly,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      maxLines: maxLines,
      maxLength: maxLength,
      enabled: enabled,
      onChanged: onChanged,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      decoration: defaultDecoration(
        label: label,
        hint: hint,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        errorText: errorText,
        helperText: helperText,
        counterText: counterText,
        contentPadding: contentPadding,
        enabled: enabled,
        scheme: Theme.of(context).colorScheme,
      ),
    );
  }
}

/// 点击触发的日期选择器输入框。
class AppDateField extends StatelessWidget {
  const AppDateField({
    super.key,
    required this.label,
    required this.value,
    this.hint = '请选择日期',
    this.prefixIcon = Icons.event_outlined,
    this.onTap,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final String? value;
  final String hint;
  final IconData prefixIcon;
  final VoidCallback? onTap;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasValue = value != null && value!.isNotEmpty;
    final textSecondary = scheme.onSurfaceVariant;
    // 已选值的图标走撞色冷色 ink（压在卡片上的图标色），不写死 primary。
    final accent = ClashTones.of(context, ClashTone.cool).ink;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: InputDecorator(
        isEmpty: !hasValue,
        decoration: AppFormField.defaultDecoration(
          label: label,
          scheme: scheme,
          enabled: enabled,
          errorText: errorText,
          prefixIcon: Icon(
            prefixIcon,
            size: 20,
            color: hasValue ? accent : textSecondary,
          ),
          suffixIcon: const Icon(Icons.expand_more, size: 20),
        ),
        child: hasValue
            ? Text(value!, style: TextStyle(color: scheme.onSurface))
            : Text(hint, style: TextStyle(color: textSecondary)),
      ),
    );
  }
}

/// 点击触发的时刻选择器输入框（本地墙上时间 `HH:mm`）。
///
/// 与 [AppDateField] 同一套视觉；时刻是**可选**的（null = 只排到天），
/// 因此 [onClear] 非空且已选值时，右侧给出「清除」按钮回到未设置状态。
class AppTimeField extends StatelessWidget {
  const AppTimeField({
    super.key,
    required this.label,
    required this.value,
    this.hint = '未设置（只排到天）',
    this.prefixIcon = Icons.schedule_outlined,
    this.onTap,
    this.onClear,
    this.enabled = true,
  });

  final String label;

  /// 已选时刻（`HH:mm`）；null 表示未设置。
  final String? value;

  final String hint;
  final IconData prefixIcon;
  final VoidCallback? onTap;

  /// 清除回调（回到未设置状态）；null 表示不提供清除入口。
  final VoidCallback? onClear;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasValue = value != null && value!.isNotEmpty;
    final textSecondary = scheme.onSurfaceVariant;
    final accent = ClashTones.of(context, ClashTone.cool).ink;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: InputDecorator(
        isEmpty: !hasValue,
        decoration: AppFormField.defaultDecoration(
          label: label,
          scheme: scheme,
          enabled: enabled,
          prefixIcon: Icon(
            prefixIcon,
            size: 20,
            color: hasValue ? accent : textSecondary,
          ),
          suffixIcon: hasValue && onClear != null && enabled
              ? IconButton(
                  tooltip: '清除时刻',
                  onPressed: onClear,
                  icon: const Icon(Icons.close, size: 18),
                )
              : const Icon(Icons.expand_more, size: 20),
        ),
        child: hasValue
            ? Text(value!, style: TextStyle(color: scheme.onSurface))
            : Text(hint, style: TextStyle(color: textSecondary)),
      ),
    );
  }
}
