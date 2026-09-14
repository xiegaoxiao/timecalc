import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 日历（.ics）文件选择抽象。
///
/// 与备份/计划导入的文件选择器同款：包装 `file_selector` 原生对话框，
/// widget 测试中 override 本 provider 为假实现，避免触碰平台对话框。
abstract interface class IcsFilePicker {
  /// 弹出「另存为」对话框，返回用户选择的保存路径（默认文件名
  /// `timecalc-日历.ics`）；取消返回 null。
  Future<File?> saveIcsFile({String? suggestedName});
}

/// 基于 `file_selector` 的默认实现（Windows 原生保存对话框）。
class NativeIcsFilePicker implements IcsFilePicker {
  const NativeIcsFilePicker();

  static const _typeGroup = XTypeGroup(
    label: 'iCalendar 日历',
    extensions: ['ics'],
    mimeTypes: ['text/calendar'],
  );

  @override
  Future<File?> saveIcsFile({String? suggestedName}) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [_typeGroup],
      suggestedName: suggestedName ?? 'timecalc-日历.ics',
      confirmButtonText: '保存',
    );
    final path = location?.path;
    return path == null ? null : File(path);
  }
}

/// 日历文件选择器 Provider（测试中 override）。
final icsFilePickerProvider = Provider<IcsFilePicker>((ref) {
  return const NativeIcsFilePicker();
});
