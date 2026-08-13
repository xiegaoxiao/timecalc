import 'dart:io';

import 'webdav_client.dart';

/// 远端备份文件元信息。
///
/// [modifiedAt] 为 UTC，供恢复列表排序（最新在上）。
class RemoteBackupFile {
  const RemoteBackupFile({
    required this.fileName,
    required this.size,
    this.modifiedAt,
  });

  final String fileName;
  final int size;
  final DateTime? modifiedAt;
}

/// 自动备份文件名前缀。
///
/// 自动备份与手动导出同目录共存时靠前缀区分：保留策略只清理
/// `timecalc-auto-*`，绝不删除用户手动导出的文件（FR-9.4）。
const String autoBackupPrefix = 'timecalc-auto-';

/// 生成自动备份文件名（本地时间戳，供保留策略按字典序排序）。
String autoBackupFileName(DateTime local) {
  final stamp =
      '${local.year}${local.month.toString().padLeft(2, '0')}'
      '${local.day.toString().padLeft(2, '0')}-'
      '${local.hour.toString().padLeft(2, '0')}'
      '${local.minute.toString().padLeft(2, '0')}'
      '${local.second.toString().padLeft(2, '0')}';
  return '$autoBackupPrefix$stamp.timecalc';
}

/// 备份目的地抽象（M8）：本地目录与 WebDAV 的同一操作面。
///
/// 上传/下载/删除失败抛可读异常（本地 IO 异常、WebDAV 转 [WebDavException]），
/// 调用方（AutoBackupService / 备份页恢复流程）负责向用户展示原因。
abstract class BackupTarget {
  /// 用户可读的目的地名称（如「本地目录」/「WebDAV」）。
  String get label;

  /// 上传 [fileName] 到目的地；目标目录不存在时先创建。
  Future<void> upload(String fileName, List<int> bytes);

  /// 列出目的地内全部备份文件（最新在前由调用方排序，这里保持服务器序）。
  Future<List<RemoteBackupFile>> list();

  /// 下载 [file] 的完整内容。
  Future<List<int>> download(RemoteBackupFile file);

  /// 删除目的地内指定文件（不存在视为成功，幂等）。
  Future<void> delete(String fileName);
}

/// 本地目录目的地：备份文件直接写入用户选择的文件夹。
class LocalBackupTarget implements BackupTarget {
  LocalBackupTarget(this.folder);

  final Directory folder;

  /// 文件名净化（M14，防御性）：只接受纯文件名，拒绝路径分隔符与 `..`，
  /// 防路径穿越写出目标目录之外。非法时抛 [ArgumentError]。
  static String _baseName(String fileName) {
    final base = fileName.split(RegExp(r'[\\/]')).last;
    if (base.isEmpty || base == '..' || base.contains('..')) {
      throw ArgumentError.value(fileName, 'fileName', '非法文件名');
    }
    return base;
  }

  @override
  String get label => '本地目录';

  @override
  Future<void> upload(String fileName, List<int> bytes) async {
    await folder.create(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}${_baseName(fileName)}');
    await file.writeAsBytes(bytes);
  }

  @override
  Future<List<RemoteBackupFile>> list() async {
    if (!await folder.exists()) return const [];
    final entities = await folder.list().toList();
    final result = <RemoteBackupFile>[];
    for (final entity in entities) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.timecalc')) continue;
      final stat = await entity.stat();
      result.add(
        RemoteBackupFile(
          fileName: entity.uri.pathSegments.last,
          size: stat.size,
          modifiedAt: stat.modified.toUtc(),
        ),
      );
    }
    return result;
  }

  @override
  Future<List<int>> download(RemoteBackupFile file) async {
    return File('${folder.path}${Platform.pathSeparator}${_baseName(file.fileName)}')
        .readAsBytes();
  }

  @override
  Future<void> delete(String fileName) async {
    final file = File('${folder.path}${Platform.pathSeparator}${_baseName(fileName)}');
    if (await file.exists()) await file.delete();
  }
}

/// WebDAV 目的地：文件存放在服务器目录 [basePath]（默认 `webdav_auto/`，
/// 与手动上传到根目录的文件隔离）。
class WebDavBackupTarget implements BackupTarget {
  WebDavBackupTarget(this._client, {String basePath = 'webdav_auto'})
      : basePath = basePath.replaceFirst(RegExp(r'^/+'), '')
            .replaceFirst(RegExp(r'/+$'), '');

  final WebDavClient _client;
  final String basePath;

  @override
  String get label => 'WebDAV';

  String _path(String fileName) => '$basePath/$fileName';

  @override
  Future<void> upload(String fileName, List<int> bytes) async {
    await _client.ensureFolder(basePath);
    await _client.upload(_path(fileName), bytes);
  }

  @override
  Future<List<RemoteBackupFile>> list() async {
    await _client.ensureFolder(basePath);
    final entries = await _client.list(basePath);
    return entries
        .where((e) => e.href.endsWith('.timecalc'))
        .map(
          (e) => RemoteBackupFile(
            fileName: e.href.split('/').last,
            size: e.size,
            modifiedAt: e.modifiedAt,
          ),
        )
        .toList();
  }

  @override
  Future<List<int>> download(RemoteBackupFile file) {
    return _client.download(_path(file.fileName));
  }

  @override
  Future<void> delete(String fileName) {
    return _client.delete(_path(fileName));
  }
}
