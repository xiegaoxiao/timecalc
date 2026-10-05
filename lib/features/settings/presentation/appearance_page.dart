import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_guard.dart';
import '../../../core/theme/accent_palette.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/clash_tones.dart';
import '../../../shared/widgets/clash_widgets.dart';
import '../data/settings_repository_provider.dart';

/// 外观设置页（M10；**v2.0 撞色重构**）：明暗主题三选一（跟随系统 / 浅色 /
/// 深色）+ **撞色方案**三选一（暖橙×冷藏青 / 电光青×青柠 / 紫罗兰×暖橙，
/// 见 [clashPaletteOrder]）+ 减少动画开关（2026-08-20 动效改造）。
///
/// 由设置页「外观」菜单项 push 进入。明暗存储于 schema v12
/// `Settings.theme_mode`（取值与 [ThemeMode.name] 一致）；色系存储于
/// schema v14 `Settings.accent_color`（取值见 [AccentPalette.id]）；
/// 减少动画存储于 schema v15 `Settings.reduce_motion`。
///
/// **点击即切换**：分段点击立即写库并换肤（`settingsProvider` 失效 →
/// [TimeCalcApp] 整树换肤 / 全局动效重建），无需单独保存；写库失败还原
/// 选择并提示。
///
/// 色系选择器**只展示 v2 撞色方案**（[clashPaletteOrder]），但写库 id 与
/// 失败还原逻辑完全保留 —— legacy 方案（green/blue）不出现在 UI，
/// 老数据仍能正确渲染（[accentPaletteById] 回退注册表）。
class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/appearance';

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  late ThemeMode _mode;
  late AccentPalette _accent;
  late bool _reduceMotion;
  bool _initialized = false;

  /// 点击明暗分段即切换：立即更新选中态（预览卡 + 整树换肤），后台写库持久化。
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

  /// 点击色系分段即切换（与 [_selectMode] 同模式）。
  Future<void> _selectAccent(AccentPalette accent) async {
    if (_initialized && accent.id == _accent.id) return; // 未变化
    setState(() => _accent = accent); // 即时反馈

    final ok = await runDbAction(
      context,
      action: () async {
        await ref
            .read(settingsRepositoryProvider)
            .updateAccentColor(accent.id);
      },
    );
    if (!ok) {
      if (mounted) {
        final saved = ref.read(settingsProvider).valueOrNull?.accentColor;
        setState(() => _accent = accentPaletteById(saved));
      }
      return;
    }
    ref.invalidate(settingsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('已切换为${accent.label}主题'),
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  /// 切换「减少动画」开关（2026-08-20 动效改造）。
  ///
  /// 与主题/色系同模式：点击即写库并刷新全局动效（[reduceMotionProvider]
  /// 随 [settingsProvider] 失效重建），无需单独保存；写库失败还原并提示。
  Future<void> _toggleReduceMotion(bool enabled) async {
    setState(() => _reduceMotion = enabled); // 即时反馈

    final ok = await runDbAction(
      context,
      action: () async {
        await ref
            .read(settingsRepositoryProvider)
            .updateReduceMotion(enabled);
      },
    );
    if (!ok) {
      if (mounted) {
        final saved =
            ref.read(settingsProvider).valueOrNull?.reduceMotion ?? false;
        setState(() => _reduceMotion = saved);
      }
      return;
    }
    ref.invalidate(settingsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(enabled ? '已减少动画' : '已恢复动画'),
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
          appBar: AppBar(title: const Text('外观')),
          body: AppErrorView(
            error: settingsAsync.error!,
            onRetry: () => ref.invalidate(settingsProvider),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('外观')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 首次加载到数据时初始化本地选择；provider 后续刷新不重置。
    if (!_initialized) {
      _mode = ThemeMode.values.firstWhere(
        (m) => m.name == settings.themeMode,
        orElse: () => ThemeMode.system,
      );
      _accent = accentPaletteById(settings.accentColor);
      _reduceMotion = settings.reduceMotion;
      _initialized = true;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        children: [
          const ClashSectionHeader(
            icon: Icons.brightness_6_outlined,
            title: '明暗模式',
            tone: ClashTone.warm,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            '选择应用的明暗主题，点击即生效。「跟随系统」随 Windows 的深浅色自动切换。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppTokens.spaceMd),
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
          const SizedBox(height: AppTokens.spaceXl),
          const ClashSectionHeader(
            icon: Icons.palette_outlined,
            title: '撞色方案',
            tone: ClashTone.cool,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            '主题色：选择应用的撞色方案（暖色主动作 × 冷色数据），'
            '背景、按钮、任务、日历等随主色变化。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          // 展示 v2 撞色方案注册表（clashPaletteOrder）；legacy 值
          // （green/blue，仅老数据可能存有）**不写库归一**，而是作为
          // 「当前选中项」额外渲染一项 —— 这样分段控件永远有且仅有
          // 一个高亮项，且高亮项与 app.dart 实际生效的 AccentPalette
          // 完全同一，预览卡与真实主题不会打架。
          SegmentedButton<AccentPalette>(
            // 纵向排布：三套方案各带三色圆点预览，窄窗口下不会挤压溢出。
            direction: Axis.vertical,
            showSelectedIcon: false,
            segments: [
              for (final palette in _paletteOptions)
                ButtonSegment(
                  value: palette,
                  label: Text(palette.label),
                  icon: _PaletteDots(palette: palette),
                ),
            ],
            selected: {_accent},
            onSelectionChanged: (selection) => _selectAccent(selection.first),
          ),
          if (_isLegacyAccent) ...[
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '当前色系「${_accent.label}」是旧版方案，仅为老数据保留渲染路径；'
              '选择任一撞色方案即可切换（不会自动改写你的数据）。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppTokens.spaceXl),
          // —— 动效（2026-08-20 动效改造）——
          const ClashSectionHeader(
            icon: Icons.animation_outlined,
            title: '动效',
            tone: ClashTone.citrus,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              value: _reduceMotion,
              onChanged: _toggleReduceMotion,
              secondary: Icon(
                Icons.animation_outlined,
                color: ClashTones.of(context, ClashTone.citrus).ink,
              ),
              title: const Text('减少动画'),
              subtitle: const Text(
                '开启后减少页面入场、切换等过渡动效，交互仍保持即时响应。',
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceXl),
          _ThemePreview(mode: _mode, accent: _accent),
        ],
      ),
    );
  }

  /// 分段控件渲染列表：三套 v2 撞色方案；若当前值是 legacy（不在
  /// [clashPaletteOrder] 内）则把它追加为当前选中项，避免出现
  /// 「无高亮项」或「高亮项 ≠ 实际生效主题」。
  List<AccentPalette> get _paletteOptions {
    final options = [for (final id in clashPaletteOrder) accentPalettes[id]!];
    if (!options.any((palette) => palette.id == _accent.id)) {
      options.add(_accent);
    }
    return options;
  }

  /// 当前库内色系是否为 legacy（green/blue：旧版方案，不在撞色列表内）。
  bool get _isLegacyAccent => !clashPaletteOrder.contains(_accent.id);
}

/// 主题模式显示名。
String _modeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
};

/// 撞色方案的三色圆点预览（暖 / 冷 / 点缀）：一眼看出该方案的撞色关系。
class _PaletteDots extends StatelessWidget {
  const _PaletteDots({required this.palette});

  final AccentPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final color in [palette.warm, palette.cool, palette.citrus])
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// 主题预览卡：并排展示浅色/深色两套色板（用当前撞色方案派生）的
/// 「表面 + 撞色三色」对比，高亮当前选中模式，直观反馈选择效果。
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.mode, required this.accent});

  final ThemeMode mode;

  /// 当前选中的撞色方案（预览随方案变化）。
  final AccentPalette accent;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前模式：${_modeLabel(mode)} · ${accent.label}色系',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Row(
              children: [
                Expanded(
                  child: _Swatch(
                    theme: AppTheme.light(accent: accent),
                    label: '浅色',
                  ),
                ),
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: _Swatch(
                    theme: AppTheme.dark(accent: accent),
                    label: '深色',
                  ),
                ),
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
    // 撞色三色：暖（primary=主结构/主动作）、冷（secondary=数据/对照）、
    // 点缀（tertiary=里程碑/徽标）。
    final swatches = <(Color, String)>[
      (scheme.primary, '暖'),
      (scheme.secondary, '冷'),
      (scheme.tertiary, '点缀'),
    ];
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppTokens.spaceSm),
          Row(
            children: [
              for (final (color, name) in swatches)
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                      ),
                      const SizedBox(height: AppTokens.spaceXs),
                      Text(
                        name,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
