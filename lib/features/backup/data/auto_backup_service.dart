import 'dart:io';

import '../../settings/data/settings_repository.dart';
import 'backup_service.dart';
import 'backup_target.dart';

/// 自动备份保留份数（FR-9.4 默认保留最近 7 份）。
const int autoBackupRetentionCount = 7;

/// 自动备份执行结果（调度器与 UI 共用）。
class AutoBackupResult {
  const AutoBackupResult({
    required this.skipped,
    required this.succeeded,
    this.skipReason,
    this.errors = const [],
  });

  /// 是否跳过（未启用 / 距上次不足 1 天 / 未配置目的地）。
  final bool skipped;

  /// 跳过原因（skipped 为 true 时给用户可读文案）。
  final String? skipReason;

  /// 是否成功（目的地只有本地目录一个，成功即全部成功）。
  final bool succeeded;

  /// 失败原因列表（导出失败或本地目录上传失败，最多一条）。
  final List<String> errors;

  bool get hasError => !skipped && !succeeded;
}

/// 自动备份执行面（调度器与测试共用的最小接口）。
abstract interface class AutoBackupRunner {
  /// 执行一次自动备份；[force] 跳过「距上次不足 1 天」判据。
  Future<AutoBackupResult> run({bool force, DateTime? now});
}

/// 自动备份服务（FR-9.4，M8）。
///
/// 负责：导出全量备份 zip → 上传到本地目录 → 剪枝（只保留最近
/// [autoBackupRetentionCount] 份自动备份）→ 成功才更新 last_auto_backup_at。
/// 失败不推进时间戳，避免静默跳过。
///
/// 纯 Dart（不依赖 UI）：调度器与「立即备份」按钮共用同一实例逻辑。
///
/// 2026-08：移除全部 WebDAV 后，目的地收敛为本地目录（M11 决策的落实）。
class AutoBackupService implements AutoBackupRunner {
  AutoBackupService({
    required this.settingsRepository,
    required this.backupService,
  });

  final SettingsRepository settingsRepository;
  final BackupService backupService;

  /// 执行一次自动备份。
  ///
  /// [force] 为 true 时跳过「距上次不足 1 天」判据（「立即备份」按钮用），
  /// 但「未启用」与「未配置目的地」仍跳过（与手动导出区分）。
  @override
  Future<AutoBackupResult> run({bool force = false, DateTime? now}) async {
    final nowUtc = (now ?? DateTime.now()).toUtc();
    final settings = await settingsRepository.get();
    if (!settings.autoBackupEnabled) {
      return const AutoBackupResult(
        skipped: true,
        succeeded: false,
        skipReason: '自动备份未开启',
      );
    }

    // M11：自动备份目的地收敛为本地目录——WebDAV 数据保护此前由整库文件
    // 同步（M9）承担；2026-08 移除全部 WebDAV 后，目的地仅本地目录。
    final localFolder = settings.localBackupFolder;
    if (localFolder == null || localFolder.trim().isEmpty) {
      return const AutoBackupResult(
        skipped: true,
        succeeded: false,
        skipReason: '未配置备份目的地（本地目录）',
      );
    }
    final target = LocalBackupTarget(Directory(localFolder));

    // 「每日」语义（FR-9.4）：距上次成功不足 24 小时跳过（force 例外）。
    final last = settings.lastAutoBackupAt;
    if (!force &&
        last != null &&
        nowUtc.difference(last).inHours < 24) {
      return AutoBackupResult(
        skipped: true,
        succeeded: false,
        skipReason: '距上次自动备份不足 24 小时，已跳过',
      );
    }

    // 先导出到临时文件，再上传到本地目录。
    final tempDir = await Directory.systemTemp.createTemp('timecalc-auto');
    final tempFile = File(
      '${tempDir.path}${Platform.pathSeparator}${autoBackupFileName(nowUtc.toLocal())}',
    );
    try {
      try {
        await backupService.exportBackup(tempFile);
      } catch (error) {
        // 导出失败（磁盘满/IO 异常）不逃出 run()：按失败返回并入 errors，
        // 避免被调度器 catch(_) 静默吞掉、用户零反馈（此前仅 finally 清理
        // 临时文件，异常直接冒泡）。
        return AutoBackupResult(
          skipped: false,
          succeeded: false,
          errors: ['导出失败：$error'],
        );
      }
      final bytes = await tempFile.readAsBytes();

      try {
        await target.upload(tempFile.uri.pathSegments.last, bytes);
        await _prune(target);
      } on Exception catch (error) {
        // 上传/剪枝失败：不推进时间戳，下次调度仍会尝试。
        return AutoBackupResult(
          skipped: false,
          succeeded: false,
          errors: ['${target.label}：$error'],
        );
      }
    } finally {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }

    // 成功才推进上次备份时间。
    await settingsRepository.updateLastAutoBackupAt(nowUtc);
    return const AutoBackupResult(skipped: false, succeeded: true);
  }

  /// 保留策略：目的地只保留最近 [autoBackupRetentionCount] 份自动备份。
  ///
  /// 只清理 `timecalc-auto-*` 前缀的文件（[autoBackupPrefix]），绝不删除
  /// 用户手动导出的备份。按文件名时间戳倒序保留最新的 N 份，其余删除。
  Future<void> _prune(BackupTarget target) async {
    final files = await target.list();
    final autos = files.where((f) => f.fileName.startsWith(autoBackupPrefix)).toList()
      ..sort((a, b) => b.fileName.compareTo(a.fileName));
    for (final file in autos.skip(autoBackupRetentionCount)) {
      await target.delete(file.fileName);
    }
  }
}
