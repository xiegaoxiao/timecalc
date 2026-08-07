import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import 'diagnostics_service.dart';

/// 启动错误屏（PRD §8：数据库异常 → 提示从备份恢复或导出诊断信息）。
///
/// 数据库无法打开（损坏/不可写/路径异常）时替代正常应用运行：
/// - 说明问题与数据库路径；
/// - 提示可重新安装应用后用既有备份恢复（备份文件不受本程序版本影响）；
/// - 提供「导出诊断信息」入口，供用户提交排查。
///
/// 此场景下没有可用的数据库连接，诊断导出跳过数据行数段落。
class StartupErrorApp extends ConsumerWidget {
  const StartupErrorApp({super.key, required this.error, this.dbPath});

  final Object error;

  /// 数据库文件路径（无法确定时为 null）。
  final String? dbPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'TimeCalc 时间计算器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: kTimeCalcSeedColor),
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
                            await _exportDiagnostics(context, ref);
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

  Future<void> _exportDiagnostics(BuildContext context, WidgetRef ref) async {
    // 启动失败路径无共享诊断实例：直接用当前诊断服务（空库，跳过数据段落）。
    final messenger = ScaffoldMessenger.of(context);
    final picker = ref.read(diagnosticsFilePickerProvider);
    final service = DiagnosticsService();
    final target = await picker.saveDiagnosticsFile();
    if (target == null) return; // 用户取消
    try {
      await service.exportDiagnostics(target);
      messenger.showSnackBar(SnackBar(content: Text('诊断信息已导出：${target.path}')));
    } on Exception catch (e) {
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
  });

  final Object error;
  final String? dbPath;
  final DiagnosticsFilePicker? picker;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        if (picker != null)
          diagnosticsFilePickerProvider.overrideWithValue(picker!),
      ],
      child: StartupErrorApp(error: error, dbPath: dbPath),
    );
  }
}
