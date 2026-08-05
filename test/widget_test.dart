// TimeCalc 应用骨架冒烟测试。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';

void main() {
  testWidgets('应用启动并展示主导航（骨架冒烟）', (tester) async {
    // 使用内存数据库，避免在测试环境初始化真实文件库与插件。
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 四个一级导航入口均存在（PRD §7）。
    expect(find.text('今天'), findsWidgets);
    expect(find.text('计划'), findsWidgets);
    expect(find.text('进度'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });
}
