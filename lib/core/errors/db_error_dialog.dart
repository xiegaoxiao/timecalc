import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'diagnostics_service.dart';

/// 展示数据库写入失败对话框（PRD §8：停止继续写入，提示恢复或导出诊断）。
///
/// 写入异常时 drift 事务已回滚（NFR-2：不产生半条写入），本对话框负责
/// 向用户说明「本次写入未生效、应用已停止继续写入」，并提供两个自助入口：
/// - 导出诊断信息：调用 [DiagnosticsService.exportDiagnostics]；
/// - 前往备份恢复：跳转设置页「备份与恢复」区。
Future<void> showDbErrorDialog(BuildContext context, {required Object error}) {
  return showDialog<void>(
    context: context,
    builder: (_) => DbErrorDialog(error: error),
  );
}

/// 数据库写入失败对话框内容。
class DbErrorDialog extends ConsumerWidget {
  const DbErrorDialog({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('数据保存失败'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('本次写入未生效，应用已停止继续写入；你的已有数据不受影响。'
              '可从备份恢复，或导出诊断信息排查。'),
          const SizedBox(height: 8),
          Text(
            '原因：$error',
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () async => _exportDiagnostics(context, ref),
          icon: const Icon(Icons.description_outlined, size: 18),
          label: const Text('导出诊断信息'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            context.go('/settings');
          },
          child: const Text('前往备份恢复'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  Future<void> _exportDiagnostics(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final picker = ref.read(diagnosticsFilePickerProvider);
    final service = ref.read(diagnosticsServiceProvider);
    final target = await picker.saveDiagnosticsFile();
    if (target == null) return; // 用户取消
    try {
      await service.exportDiagnostics(target);
      messenger.showSnackBar(
        SnackBar(content: Text('诊断信息已导出：${target.path}')),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出诊断失败：$e')));
    }
  }
}
