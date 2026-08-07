import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_guard.dart';
import '../../../core/theme/app_theme.dart';
import '../data/settings_repository_provider.dart';

/// 外观设置页（M10）：明暗主题三选一（跟随系统 / 浅色 / 深色）。
///
/// 由设置页「外观」菜单项 push 进入。存储于 schema v12 `Settings.theme_mode`
/// （取值与 [ThemeMode.name] 一致：`system`/`light`/`dark`）。
///
/// **点击即切换**：分段点击立即写库并换肤（`settingsProvider` 失效 →
/// [TimeCalcApp] 整树换肤），无需单独保存；写库失败还原选择并提示。
class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/appearance';

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  late ThemeMode _mode;
  bool _initialized = false;

  /// 点击分段即切换：立即更新选中态（预览卡 + 整树换肤），后台写库持久化。
  Future<void> _selectMode(ThemeMode mode) async {
    if (_initialized && mode == _mode) return; // 未变化
    setState(() => _mode = mode); // 即时反馈

    final ok = await runDbAction(
      context,
      action: () async {
        await ref.read(settingsRepositoryProvider).updateThemeMode(mode.name);
      },
    );
    if (!ok) {
      // 写库失败：还原为库内值（runDbAction 已弹「数据保存失败」对话框）。
      if (mounted) {
        final saved = ref.read(settingsProvider).valueOrNull?.themeMode;
        setState(() {
          _mode = ThemeMode.values.firstWhere(
            (m) => m.name == saved,
            orElse: () => ThemeMode.system,
          );
        });
      }
      return;
    }
    // settingsProvider 失效 → TimeCalcApp 重新构建 → 整树换肤（无需重启）。
    ref.invalidate(settingsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('已切换为${_modeLabel(mode)}主题'),
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (settings) {
          // 首次加载到数据时初始化本地选择；provider 后续刷新不重置。
          if (!_initialized) {
            _mode = ThemeMode.values.firstWhere(
              (m) => m.name == settings.themeMode,
              orElse: () => ThemeMode.system,
            );
            _initialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '选择应用的明暗主题，点击即生效。「跟随系统」随 Windows 的深浅色自动切换。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('跟随系统'),
                    icon: Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('浅色'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('深色'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) => _selectMode(selection.first),
              ),
              const SizedBox(height: 24),
              _ThemePreview(mode: _mode),
            ],
          );
        },
      ),
    );
  }
}

/// 主题模式显示名。
String _modeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
    };

/// 主题预览卡：并排展示浅色/深色两套色板的「表面 + 主色」对比，
/// 高亮当前选中模式，直观反馈选择效果。
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前模式：${_modeLabel(mode)}',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _Swatch(theme: AppTheme.light(), label: '浅色')),
                const SizedBox(width: 12),
                Expanded(child: _Swatch(theme: AppTheme.dark(), label: '深色')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.theme, required this.label});

  final ThemeData theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  scheme.primary.toARGB32().toRadixString(16).substring(2),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
