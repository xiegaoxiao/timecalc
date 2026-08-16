import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/accent_palette.dart';
import 'diagnostics_service.dart';

/// 启动错误屏（PRD §8：数据库异常 → 提示从备份恢复或导出诊断信息）。
///
/// 数据库无法打开（损坏/不可写/路径异常）时替代正常应用运行：
/// - 说明问题与数据库路径；
/// - 提示可重新安装应用后用既有备份恢复（备份文件不受本程序版本影响）；
/// - 提供「导出诊断信息」入口，供用户提交排查。
///
/// 此场景下没有可用的数据库连接，诊断导出跳过数据行数段落，但包含
/// 启动时捕获的错误日志（[diagnostics] 由 main 传入共享实例，M2）。
class StartupErrorApp extends ConsumerStatefulWidget {
  const StartupErrorApp({super.key, required this.error, this.dbPath, this.diagnostics});

  final Object error;

  /// 数据库文件路径（无法确定时为 null）。
  final String? dbPath;

  /// 共享诊断服务实例（main 中已 capture 启动错误）；null 时回退新建
  /// 空实例（测试兼容路径，导出不含错误日志）。
  final DiagnosticsService? diagnostics;

  @override
  ConsumerState<StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends ConsumerState<StartupErrorApp> {
  @override
  Widget build(BuildContext context) {
    final error = widget.error;
    final dbPath = widget.dbPath;
    return MaterialApp(
      title: 'TimeCalc 时间计算器',
      debugShowCheckedModeBanner: false,
      // 无 settings 可读（数据库都打不开），用默认绿色色系。
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: greenAccent.seed,
      ),
      home: Scaffold(
        body: Builder(
          // Builder 位于 MaterialApp 内部，ScaffoldMessenger 可用。
          builder: (context) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                margin: const EdgeInsets.all(24),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.error_outline, size: 32),
                          const SizedBox(width: 12),
                          Text(
                            '数据无法打开',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('本地数据库打开失败，应用无法正常启动。你的数据没有丢失。'),
                      const SizedBox(height: 8),
                      if (dbPath != null)
                        Text(
                          '数据库文件：$dbPath',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(height: 8),
                      Text(
                        '原因：$error',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '你可以：\n'
                        '· 导出诊断信息用于排查；\n'
                        '· 从之前的 TimeCalc 备份（.timecalc 文件）恢复数据——'
                        '请先安装应用，再从「设置 → 备份与恢复」恢复。',
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: () async {
                            await _exportDiagnostics(context);
                          },
                          icon: const Icon(
                            Icons.description_outlined,
                            size: 18,
                          ),
                          label: const Text('导出诊断信息'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _exportDiagnostics(BuildContext context) async {
    // 使用共享诊断实例（main 在开库失败时已 capture 启动错误）：导出文件
    // 包含真正导致启动失败的错误日志（M2；此前新建空实例导不出错误）。
    // diagnostics 为 null（测试未注入）时回退新建空实例。
    final messenger = ScaffoldMessenger.of(context);
    final picker = ref.read(diagnosticsFilePickerProvider);
    final service = widget.diagnostics ?? DiagnosticsService();
    final target = await picker.saveDiagnosticsFile();
    if (target == null) return; // 用户取消
    try {
      await service.exportDiagnostics(target);
      messenger.showSnackBar(SnackBar(content: Text('诊断信息已导出：${target.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出诊断失败：$e')));
    }
  }
}

/// 携带启动错误信息的 ProviderScope 包装（供 main 失败路径直接 runApp）。
///
/// 测试中可注入假文件选择器；生产环境使用默认实现。
class StartupErrorScope extends StatelessWidget {
  const StartupErrorScope({
    super.key,
    required this.error,
    this.dbPath,
    this.picker,
    this.diagnostics,
  });

  final Object error;
  final String? dbPath;
  final DiagnosticsFilePicker? picker;

  /// 共享诊断服务实例（main 传入，M2：导出含启动错误日志）。
  final DiagnosticsService? diagnostics;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        if (picker != null)
          diagnosticsFilePickerProvider.overrideWithValue(picker!),
      ],
      child: StartupErrorApp(
        error: error,
        dbPath: dbPath,
        diagnostics: diagnostics,
      ),
    );
  }
}
