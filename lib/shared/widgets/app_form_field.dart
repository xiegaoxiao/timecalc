import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

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
  /// 颜色全部取自 [ColorScheme]（随主题明暗切换）：
  /// 填充用 `surfaceContainerHighest`、边框用 `outlineVariant`、
  /// 文字用 `onSurfaceVariant`、错误用 `error`。
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
    final baseFill = scheme?.surfaceContainerHighest ?? const Color(0xFFF8F9FA);
    final borderColor = scheme?.outlineVariant ?? AppTokens.neutralBorderLight;
    final textSecondary = scheme?.onSurfaceVariant ??
        AppTokens.neutralTextSecondaryLight;
    final errorColor = scheme?.error ?? const Color(0xFFDC2626);

    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helperText,
      errorText: errorText,
      counterText: counterText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      contentPadding: contentPadding ??
          const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceMd,
            vertical: AppTokens.spaceMd,
          ),
      filled: true,
      fillColor: baseFill.withValues(alpha: enabled ? 0.6 : 0.3),
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
        borderSide: BorderSide(
          color: scheme?.primary ?? const Color(0xFF3F6C51),
          width: 1.5,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        borderSide: BorderSide(color: errorColor, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
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
      hintStyle: TextStyle(color: textSecondary.withValues(alpha: 0.6)),
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
    final borderColor = scheme.outlineVariant;
    final textSecondary = scheme.onSurfaceVariant;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: InputDecorator(
        isEmpty: !hasValue,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Padding(
            padding: const EdgeInsets.only(right: AppTokens.spaceSm),
            child: Icon(
              prefixIcon,
              size: 20,
              color: hasValue ? scheme.primary : textSecondary,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceMd,
            vertical: AppTokens.spaceMd,
          ),
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            borderSide: BorderSide(color: borderColor, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            borderSide: BorderSide(color: borderColor, width: 1),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            borderSide: BorderSide(color: scheme.error, width: 1),
          ),
          errorText: errorText,
        ),
        child: hasValue
            ? Text(
                value!,
                style: TextStyle(color: scheme.onSurface),
              )
            : null,
      ),
    );
  }
}