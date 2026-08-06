import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/core/app_version.dart';

/// kAppVersion 与 pubspec.yaml 版本一致性测试。
///
/// kAppVersion 写入备份 manifest 与诊断导出，供版本追溯；pubspec 的
/// `version:` 是构建产物的版本。两者脱节会导致追溯信息失真，故以测试
/// 强制同步（手工 bump 版本时若漏改 kAppVersion 会在此失败）。
void main() {
  test('kAppVersion 与 pubspec.yaml 的 version 保持一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionMatch = RegExp(r'^version:\s*(\S+)$', multiLine: true)
        .firstMatch(pubspec);
    expect(versionMatch, isNotNull, reason: 'pubspec.yaml 缺少 version 字段');
    final raw = versionMatch!.group(1)!;
    // 去掉 +build 构建号（如 1.2.0+1 → 1.2.0），只比业务版本。
    final version = raw.split('+').first;
    expect(kAppVersion, version,
        reason: 'kAppVersion 与 pubspec 版本不一致，请同步 lib/core/app_version.dart');
  });
}
