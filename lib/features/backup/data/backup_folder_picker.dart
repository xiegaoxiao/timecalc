import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 目录选择抽象（自动备份本地目录，M8）。
///
/// 包装 `file_selector.getDirectoryPath`（Windows 原生目录对话框），
/// widget 测试 override [backupFolderPickerProvider] 为假实现，避免触碰
/// 平台对话框（仿 backupFilePickerProvider）。
abstract interface class BackupFolderPicker {
  /// 弹出「选择目录」对话框，返回目录路径；取消返回 null。
  Future<String?> pickFolder();
}

/// 基于 `file_selector` 的默认实现（Windows 原生目录对话框）。
class NativeBackupFolderPicker implements BackupFolderPicker {
  @override
  Future<String?> pickFolder() => getDirectoryPath();
}

/// 目录选择器 Provider（测试中 override）。
final backupFolderPickerProvider = Provider<BackupFolderPicker>((ref) {
  return NativeBackupFolderPicker();
});
