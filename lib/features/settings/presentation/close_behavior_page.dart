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
/// 的拦截行为。**点击即生效**（写库 + 实时应用桌面层，无需单独保存/重启）。
class CloseBehaviorPage extends ConsumerStatefulWidget {
  const CloseBehaviorPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/close-behavior';

  @override
  ConsumerState<CloseBehaviorPage> createState() => _CloseBehaviorPageState();
}

class _CloseBehaviorPageState extends ConsumerState<CloseBehaviorPage> {
  late String _behavior;
  bool _initialized = false;

  /// 点击分段即切换：立即写库并实时应用桌面层拦截行为（FR-8.1）。
  Future<void> _selectBehavior(String behavior) async {
    if (_initialized && behavior == _behavior) return; // 未变化
    setState(() => _behavior = behavior); // 即时反馈

    final ok = await runDbAction(
      context,
      action: () async {
        await ref
            .read(settingsRepositoryProvider)
            .updateCloseBehavior(behavior);
      },
    );
    if (!ok) {
      // 写库失败：还原为库内值（runDbAction 已弹「数据保存失败」）。
      if (mounted) {
        final saved = ref.read(settingsProvider).valueOrNull?.closeBehavior;
        setState(() => _behavior = saved ?? CloseBehavior.exit);
      }
      return;
    }
    ref.invalidate(settingsProvider);
    // 实时应用到桌面层（退出 ↔ 最小化到托盘切换无需重启即生效）。
    await ref.read(desktopControllerProvider)?.applyCloseBehavior();
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '已切换为${behavior == CloseBehavior.minimizeToTray ? '最小化到托盘' : '直接退出'}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    // valueOrNull 保留旧值（M15）：保存后 invalidate(settingsProvider) 使
    // provider 短暂回到 loading，若用 .when(loading: spinner) 会整页闪烁。
    final settings = settingsAsync.valueOrNull;
    if (settings == null) {
      if (settingsAsync.hasError) {
        return Scaffold(
          appBar: AppBar(title: const Text('关闭行为')),
          body: AppErrorView(
            error: settingsAsync.error!,
            onRetry: () => ref.invalidate(settingsProvider),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('关闭行为')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 首次加载到数据时初始化本地选择；provider 后续刷新不重置用户选择。
    if (!_initialized) {
      _behavior = settings.closeBehavior;
      _initialized = true;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('关闭行为')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '点击窗口关闭按钮时的行为，点击即生效；最小化到托盘后可随时从托盘菜单恢复（FR-8.1/8.2）。',
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
            onSelectionChanged: (selection) => _selectBehavior(selection.first),
          ),
        ],
      ),
    );
  }
}
