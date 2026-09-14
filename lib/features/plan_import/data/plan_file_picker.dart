import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 选中的计划文件：内容 + 文件名（无日历名时用作目标标题）。
class PickedPlanFile {
  const PickedPlanFile({required this.content, this.fileName});

  /// 文件内容（UTF-8 文本）。
  final String content;

  /// 文件名（不含目录）；未知时为 null。
  final String? fileName;
}

/// 计划文件选择抽象（JSON 计划书 / iCalendar .ics）。
///
/// 包装 `file_selector`（Windows 原生打开对话框）+ 文件读取，widget 测试
/// 中 override [planFilePickerProvider] 为假实现，避免触碰平台对话框。
abstract interface class PlanFilePicker {
  /// 弹出「打开」对话框选择计划文件（.json 或 .ics）；用户取消返回 null；
  /// 读取失败抛异常（由调用方提示）。
  ///
  /// 返回的文本由调用方按内容判别格式（见 PlanImportDialog）：以
  /// `BEGIN:VCALENDAR` 开头按 iCalendar 解析，否则按计划书 JSON 解析。
  Future<PickedPlanFile?> pickPlanFile();
}

/// 基于 `file_selector` 的默认实现（Windows 原生打开对话框）。
class NativePlanFilePicker implements PlanFilePicker {
  const NativePlanFilePicker();

  static const _typeGroups = [
    XTypeGroup(
      label: '计划文件（JSON / 日历）',
      extensions: ['json', 'ics'],
      mimeTypes: ['application/json', 'text/calendar'],
    ),
    XTypeGroup(label: '完整计划 JSON', extensions: ['json']),
    XTypeGroup(label: 'iCalendar 日历', extensions: ['ics']),
  ];

  @override
  Future<PickedPlanFile?> pickPlanFile() async {
    final file = await openFile(
      acceptedTypeGroups: _typeGroups,
      confirmButtonText: '打开',
    );
    final path = file?.path;
    if (path == null) return null;
    return PickedPlanFile(
      content: await File(path).readAsString(),
      fileName: _fileNameOf(path),
    );
  }

  /// 从路径取文件名，并去掉扩展名（`考研日历.ics` → `考研日历`）。
  static String _fileNameOf(String path) {
    final segments = path.split(RegExp(r'[\\/]'));
    final base = segments.isEmpty ? path : segments.last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }
}

/// 计划文件选择器 Provider（测试中 override）。
final planFilePickerProvider = Provider<PlanFilePicker>((ref) {
  return const NativePlanFilePicker();
});
