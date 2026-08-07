import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import '../database/database.dart';
import '../database/database_provider.dart';

/// 诊断信息文件选择抽象。
///
/// 包装 `file_selector`（Windows 原生保存对话框），widget 测试中
/// override [diagnosticsFilePickerProvider] 为假实现，避免触碰平台对话框。
abstract interface class DiagnosticsFilePicker {
  /// 弹出「另存为」对话框，返回用户选择的保存路径；取消返回 null。
  Future<File?> saveDiagnosticsFile();
}

/// 基于 `file_selector` 的默认实现（Windows 原生对话框）。
class NativeDiagnosticsFilePicker implements DiagnosticsFilePicker {
  static const _typeGroup = XTypeGroup(
    label: '诊断信息',
    extensions: ['txt'],
    mimeTypes: ['text/plain'],
  );

  @override
  Future<File?> saveDiagnosticsFile() async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [_typeGroup],
      suggestedName: 'timecalc-diagnostics.txt',
      confirmButtonText: '保存',
    );
    final path = location?.path;
    return path == null ? null : File(path);
  }
}

/// 诊断信息文件选择器 Provider（测试中 override）。
final diagnosticsFilePickerProvider = Provider<DiagnosticsFilePicker>((ref) {
  return NativeDiagnosticsFilePicker();
});

/// 诊断信息服务（PRD §8：数据库异常时提示「导出诊断信息」）。
///
/// 职责：
/// - 捕获运行期错误（全局错误处理器写入），保留最近 [maxLogEntries] 条；
/// - 本地日志文件追加记录（NFR-3：本地保存、容量封顶、自动清理）；
/// - [exportDiagnostics] 导出诊断文件：应用版本、schema 版本、数据库路径、
///   各表行数（守卫读取）与最近错误日志，供用户自助排查或提交。
///
/// 数据库连接在启动失败场景下可能不存在（`db` 为 null），此时导出文件
/// 跳过数据库相关段落，保证启动错误页也能导出诊断。
class DiagnosticsService {
  DiagnosticsService([this._db]);

  static const int _maxLogEntries = 200;

  /// 日志文件容量上限（超过时截断保留尾部 32KB，避免无限增长，NFR-3）。
  static const int _maxLogBytes = 256 * 1024;

  AppDatabase? _db;
  final List<String> _log = [];
  Directory? _logDir;

  /// 数据库打开成功后挂载连接（启动流程先装全局处理器后开库）。
  void attachDatabase(AppDatabase db) => _db = db;

  /// 捕获错误：记录时间戳与错误信息，写入内存环与本地日志文件。
  void capture(Object error, [StackTrace? stack]) {
    final entry = '[${_now()}] $error${stack == null ? '' : '\n$stack'}';
    _log.add(entry);
    if (_log.length > _maxLogEntries) _log.removeAt(0);
    _appendToFile(entry);
  }

  /// 最近捕获的错误日志（只读）。
  List<String> get recentErrors => List.unmodifiable(_log);

  /// 导出诊断信息到 [target]，返回写入的 [target]。
  Future<File> exportDiagnostics(File target) async {
    final buffer = StringBuffer()
      ..writeln('TimeCalc 诊断信息')
      ..writeln('导出时间：${_now()}')
      ..writeln('应用版本：$kAppVersion')
      ..writeln(
        '数据库 schema 版本：${_db?.schemaVersion ?? '（数据库未打开）'}',
      )
      ..writeln(
        '平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('数据库文件：${await _databasePath()}')
      ..writeln()
      ..writeln('== 数据行数 ==');

    final db = _db;
    if (db == null) {
      buffer.writeln('（数据库不可用，无法读取）');
    } else {
      Future<void> writeRowCount(String name, Future<int> Function() count) async {
        try {
          final n = await count();
          buffer.writeln('$name: $n');
        } catch (_) {
          buffer.writeln('$name: <读取失败>');
        }
      }

      await writeRowCount(
          'goals', () async => (await db.select(db.goals).get()).length);
      await writeRowCount(
          'subjects', () async => (await db.select(db.subjects).get()).length);
      await writeRowCount(
          'tasks', () async => (await db.select(db.tasks).get()).length);
      await writeRowCount(
          'settings', () async => (await db.select(db.settings).get()).length);
      await writeRowCount('recurrence_templates',
          () async => (await db.select(db.recurrenceTemplates).get()).length);
      await writeRowCount(
          'milestones', () async => (await db.select(db.milestones).get()).length);
      await writeRowCount('checklist_items',
          () async => (await db.select(db.checklistItems).get()).length);
    }

    buffer
      ..writeln()
      ..writeln('== 最近错误日志（${_log.length} 条）==');
    if (_log.isEmpty) {
      buffer.writeln('（无）');
    } else {
      for (final entry in _log.reversed) {
        buffer.writeln(entry);
      }
    }

    await target.writeAsString(buffer.toString());
    return target;
  }

  Future<String> _databasePath() async {
    final db = _db;
    if (db == null) return '（数据库未打开）';
    try {
      // 从真实连接的 `PRAGMA database_list` 读取主库文件路径：权威来源，
      // 不依赖 drift_flutter 的目录/文件名内部约定（L6）。
      final rows = await db
          .customSelect('PRAGMA database_list', readsFrom: {db.settings})
          .get();
      for (final row in rows) {
        final name = row.data['name'];
        final path = row.data['file'];
        if (name == 'main' && path is String && path.isNotEmpty) {
          return path;
        }
      }
      return '（无法定位数据库文件）';
    } catch (_) {
      // 查询失败（如极端只读场景）时回退到预期路径，仍可导出诊断。
      try {
        final dir = await getApplicationDocumentsDirectory();
        return '${dir.path}${Platform.pathSeparator}timecalc.sqlite'
            '（推断路径，读取失败）';
      } catch (_) {
        return '（无法获取，drift_flutter 默认文档目录）';
      }
    }
  }

  Future<void> _appendToFile(String entry) async {
    try {
      final dir = await _ensureLogDir();
      final file = File('${dir.path}${Platform.pathSeparator}timecalc-error.log');
      if (await file.exists() && await file.length() > _maxLogBytes) {
        // 容量封顶：保留文件尾部，避免日志无限增长（NFR-3 自动清理）。
        final tail = await file.readAsString();
        const maxTail = 32768;
        final keep = tail.length > maxTail
            ? tail.substring(tail.length - maxTail)
            : tail;
        await file.writeAsString('...（日志已截断）\n$keep');
      }
      await file.writeAsString('$entry\n', mode: FileMode.append);
    } catch (_) {
      // 日志写入失败不影响应用（本地日志尽力而为）。
    }
  }

  Future<Directory> _ensureLogDir() async {
    if (_logDir != null) return _logDir!;
    final support = await getApplicationSupportDirectory();
    _logDir = support;
    return _logDir!;
  }

  static String _now() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}

/// 诊断信息服务 Provider。
///
/// 生产环境默认基于当前数据库连接构造；main() 中 override 为共享实例，
/// 使全局错误处理器与 UI 导出使用同一日志。
final diagnosticsServiceProvider = Provider<DiagnosticsService>((ref) {
  return DiagnosticsService(ref.watch(databaseProvider));
});
