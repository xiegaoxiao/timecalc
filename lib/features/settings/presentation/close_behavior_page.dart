import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/tables.dart';
import '../../../core/desktop/desktop_providers.dart';
import '../../../core/errors/app_guard.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../data/settings_repository_provider.dart';

/// 关闭行为页（FR-8.1）：退出 / 最小化到托盘。
///
/// 由设置页「关闭行为」菜单项 push 进入。存储于 schema v6
/// `Settings.close_behavior`；桌面层（DesktopController）据此决定关闭按钮
/// 的拦截行为。保存后实时应用到桌面层，切换无需重启即生效。
class CloseBehaviorPage extends ConsumerStatefulWidget {
  const CloseBehaviorPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/close-behavior';

  @override
  ConsumerState<CloseBehaviorPage> createState() => _CloseBehaviorPageState();
}

class _CloseBehaviorPageState extends ConsumerState<CloseBehaviorPage> {
  late String _behavior;
  bool _saving = false;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('关闭行为')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(settingsProvider),
        ),
        data: (settings) {
          // 首次加载到数据时初始化本地选择；provider 后续刷新不重置用户选择。
          if (!_initialized) {
            _behavior = settings.closeBehavior;
            _initialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '点击窗口关闭按钮时的行为；最小化到托盘后可随时从托盘菜单恢复（FR-8.1/8.2）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: CloseBehavior.exit,
                    label: Text('直接退出'),
                    icon: Icon(Icons.close),
                  ),
                  ButtonSegment(
                    value: CloseBehavior.minimizeToTray,
                    label: Text('最小化到托盘'),
                    icon: Icon(Icons.minimize),
                  ),
                ],
                selected: {_behavior},
                onSelectionChanged: (selection) =>
                    setState(() => _behavior = selection.first),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final ok = await runDbAction(
        context,
        action: () async {
          await ref
              .read(settingsRepositoryProvider)
              .updateCloseBehavior(_behavior);
        },
      );
      if (!ok) return;
      ref.invalidate(settingsProvider);
      // FR-8.1：保存后实时应用窗口拦截行为，切换无需重启即生效。
      await ref.read(desktopControllerProvider)?.applyCloseBehavior();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('关闭行为已保存')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
