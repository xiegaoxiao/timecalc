import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 计划 JSON 文件选择抽象。
///
/// 包装 `file_selector`（Windows 原生打开对话框）+ 文件读取，widget 测试
/// 中 override [planJsonPickerProvider] 为假实现，避免触碰平台对话框。
abstract interface class PlanJsonPicker {
  /// 弹出「打开」对话框选择 JSON 文件，返回文件内容（UTF-8）；
  /// 用户取消返回 null；读取失败抛异常（由调用方提示）。
  Future<String?> pickJson();
}

/// 基于 `file_selector` 的默认实现（Windows 原生打开对话框）。
class NativePlanJsonPicker implements PlanJsonPicker {
  static const _typeGroup = XTypeGroup(
    label: 'JSON 计划',
    extensions: ['json'],
    mimeTypes: ['application/json'],
  );

  @override
  Future<String?> pickJson() async {
    final file = await openFile(
      acceptedTypeGroups: const [_typeGroup],
      confirmButtonText: '打开',
    );
    final path = file?.path;
    if (path == null) return null;
    return File(path).readAsString();
  }
}

/// 计划 JSON 选择器 Provider（测试中 override）。
final planJsonPickerProvider = Provider<PlanJsonPicker>((ref) {
  return NativePlanJsonPicker();
});
