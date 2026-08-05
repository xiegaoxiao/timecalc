import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 可注入的时钟 Provider。
///
/// 业务规则（倒计时、日期计算）通过它获取当前时间，
/// 测试中可 override 为固定时间，保证日期边界测试可复现。
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
