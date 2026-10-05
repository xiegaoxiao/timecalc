import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 备份用文件/目录选择抽象（M8）。
///
/// 包装 `file_selector` 的 3 次原生对话框调用（另存为 / 打开 / 选择目录）；
/// widget 测试中 override [backupFilePickerProvider] 为假实现，避免触碰平台
/// 对话框（原 backup_file_picker + backup_folder_picker 两个同型抽象合并）。
abstract interface class BackupFilePicker {
  /// 弹出「另存为」对话框，返回用户选择的保存路径；取消返回 null。
  Future<File?> saveBackupFile();

  /// 弹出「打开」对话框，返回用户选择的备份文件；取消返回 null。
  Future<File?> openBackupFile();

  /// 弹出「选择目录」对话框（自动备份本地目录），返回目录路径；取消返回 null。
  Future<String?> pickFolder();
}

/// 基于 `file_selector` 的默认实现（Windows 原生对话框）。
class NativeBackupFilePicker implements BackupFilePicker {
  static const _typeGroup = XTypeGroup(
    label: 'TimeCalc 备份',
    extensions: ['timecalc'],
    mimeTypes: ['application/zip'],
  );

  @override
  Future<File?> saveBackupFile() async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [_typeGroup],
      suggestedName: 'timecalc-backup.timecalc',
      confirmButtonText: '保存',
    );
    final path = location?.path;
    return path == null ? null : File(path);
  }

  @override
  Future<File?> openBackupFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [_typeGroup],
      confirmButtonText: '打开',
    );
    final path = file?.path;
    return path == null ? null : File(path);
  }

  @override
  Future<String?> pickFolder() => getDirectoryPath();
}

/// 备份文件/目录选择器 Provider（测试中 override）。
final backupFilePickerProvider = Provider<BackupFilePicker>((ref) {
  return NativeBackupFilePicker();
});
