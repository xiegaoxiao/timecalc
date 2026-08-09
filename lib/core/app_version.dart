/// 当前应用版本（单一来源）。
///
/// 写入备份文件 manifest 与导出诊断信息，便于追溯备份/日志对应的应用版本。
/// 与 pubspec.yaml 的 `version:` 保持一致（不含 `+build` 构建号）；
/// `test/core/app_version_test.dart` 会解析 pubspec 校验一致性，防止脱节。
const String kAppVersion = '1.10.0';
