import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/desktop/desktop_controller.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/settings/data/settings_repository_provider.dart';

/// TimeCalc 应用根组件。
class TimeCalcApp extends ConsumerWidget {
  const TimeCalcApp({super.key});

  /// 主题模式文本 → [ThemeMode]（schema v12 存 `system`/`light`/`dark`，
  /// 与 [ThemeMode.name] 一致；未知值回退跟随系统）。
  static ThemeMode _themeModeFrom(String? mode) {
    for (final candidate in ThemeMode.values) {
      if (candidate.name == mode) return candidate;
    }
    return ThemeMode.system;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // 只依赖 themeMode 字段：用 select 窄化监听，避免任何设置项变更
    // （如 last_synced_at、关闭行为、备份目录）都重建整个 MaterialApp 树。
    final themeMode = ref
        .watch(settingsProvider.select((s) => s.valueOrNull?.themeMode));
    return MaterialApp.router(
      title: 'TimeCalc 时间计算器',
      debugShowCheckedModeBanner: false,
      // 桌面控制器通过该 key 取得全局 ScaffoldMessenger 上下文，
      // 用于「首次最小化到托盘」的说明提示（FR-8.1）。
      scaffoldMessengerKey: DesktopController.scaffoldMessengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // M10：由外观页选择「跟随系统 / 浅色 / 深色」；保存后 settingsProvider
      // 失效即整树换肤，无需重启。加载/失败时回退跟随系统。
      themeMode: _themeModeFrom(themeMode),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
