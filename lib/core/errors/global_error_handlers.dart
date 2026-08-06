import 'package:flutter/foundation.dart';

import 'diagnostics_service.dart';

/// 安装全局错误处理器（PRD §8 / NFR-3）。
///
/// 未捕获的 Flutter 框架错误与异步 isolate 错误写入诊断日志（本地记录），
/// 不终止应用。数据库相关异常的业务侧提示由 [app_guard] 的
/// [runDbAction] 统一处理；此处只保证「未预期错误不静默丢失」。
///
/// 仅在 main() 启动流程调用一次；widget 测试不安装，避免污染测试环境。
void installGlobalErrorHandlers(DiagnosticsService diagnostics) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _captureSafe(diagnostics, details.exception, details.stack);
  };
  // 返回 true：错误已处理，不终止 isolate（release 下保持应用可用）。
  PlatformDispatcher.instance.onError = (error, stack) {
    _captureSafe(diagnostics, error, stack);
    return true;
  };
}

/// 捕获错误，防止诊断服务自身抛错时再次进入错误处理器造成无限递归。
void _captureSafe(
  DiagnosticsService diagnostics,
  Object error,
  StackTrace? stack,
) {
  try {
    diagnostics.capture(error, stack);
  } catch (_) {
    // 日志写入失败不影响错误处理器（尽力而为）。
  }
}
