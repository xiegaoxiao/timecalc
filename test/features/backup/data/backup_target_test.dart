import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/features/backup/data/backup_target.dart';

/// 备份目的地测试（M8，FR-9.4）。
///
/// - LocalBackupTarget：真实临时目录上传/列出/下载/删除；
/// - 保留剪枝逻辑由 AutoBackupService._prune 测试覆盖（见
///   auto_backup_service_test.dart），这里覆盖目的地自身的行为。
void main() {
  group('LocalBackupTarget', () {
    late Directory tempDir;
    late LocalBackupTarget target;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('timecalc-target');
      target = LocalBackupTarget(tempDir);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('上传 → 列表 → 下载 → 删除闭环', () async {
      await target.upload('a.timecalc', [1, 2, 3]);
      final files = await target.list();
      expect(files, hasLength(1));
      expect(files.single.fileName, 'a.timecalc');
      expect(files.single.size, 3);

      final bytes = await target.download(files.single);
      expect(bytes, [1, 2, 3]);

      await target.delete('a.timecalc');
      expect(await target.list(), isEmpty);
    });

    test('上传前自动创建目录（含多层路径）', () async {
      final nested = LocalBackupTarget(
        Directory('${tempDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}deep'),
      );
      await nested.upload('b.timecalc', [1]);
      expect(await nested.list(), hasLength(1));
    });

    test('列表只收集 .timecalc 文件，忽略其他文件', () async {
      await target.upload('a.timecalc', [1]);
      File('${tempDir.path}${Platform.pathSeparator}notes.txt')
          .writeAsStringSync('x');
      final files = await target.list();
      expect(files, hasLength(1));
      expect(files.single.fileName, 'a.timecalc');
    });

    test('目录不存在时 list 返回空', () async {
      final empty = LocalBackupTarget(
        Directory('${tempDir.path}${Platform.pathSeparator}none'),
      );
      expect(await empty.list(), isEmpty);
    });
  });

  group('文件名工具', () {
    test('autoBackupFileName 生成带前缀与本地时间戳的文件名', () {
      final name = autoBackupFileName(DateTime(2026, 8, 6, 9, 5, 7));
      expect(name, 'timecalc-auto-20260806-090507.timecalc');
      expect(name.startsWith(autoBackupPrefix), isTrue);
    });
  });
}
