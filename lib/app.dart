import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/desktop/desktop_controller.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

/// TimeCalc 应用根组件。
class TimeCalcApp extends ConsumerWidget {
  const TimeCalcApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'TimeCalc 时间计算器',
      debugShowCheckedModeBanner: false,
      // 桌面控制器通过该 key 取得全局 ScaffoldMessenger 上下文，
      // 用于「首次最小化到托盘」的说明提示（FR-8.1）。
      scaffoldMessengerKey: DesktopController.scaffoldMessengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // M3 起改为可由用户在设置中选择；当前跟随系统。
      themeMode: ThemeMode.system,
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
