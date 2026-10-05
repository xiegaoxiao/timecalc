import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timecalc/app.dart';
import 'package:timecalc/core/database/database.dart';
import 'package:timecalc/core/database/database_provider.dart';
import 'package:timecalc/core/providers/clock_provider.dart';
import 'package:timecalc/features/settings/data/settings_repository.dart';
import 'package:timecalc/features/timetable/data/course_repository.dart';
import 'package:timecalc/features/timetable/domain/class_period.dart';
import 'package:timecalc/features/timetable/domain/course_palette.dart';

import '../../../shared/nav_helper.dart';

/// 课表页 Widget 测试（FR-10）。
///
/// 固定时钟 2026-09-14（周一，本学期第 2 教学周；第 1 周周一为 2026-09-07），
/// 覆盖：空态入口、按教学周筛选、翻周、今天高亮、未设学期基准的退化视图、
/// 导入对话框（粘贴 JSON → 校验 → 导入）与清空课表。
void main() {
  late AppDatabase db;
  late CourseRepository courses;
  late SettingsRepository settings;
  late DateTime fixedNow;

  Future<void> pumpApp(WidgetTester tester) async {
    // 课表网格 12 行 + 头部，需要足够高的视口（与其它网格类页面测试同款）。
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(() => fixedNow),
        ],
        child: const TimeCalcApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTimetable(WidgetTester tester) async {
    await tapNavDestination(tester, '课表');
  }

  /// 点头部「导入课表」按钮。
  ///
  /// 课表为空时空态 CTA 也叫「导入课表」（头部按钮 + 空态大按钮，两个
  /// 入口文案一致是刻意的），故按树序取第一个 = 头部按钮。
  Future<void> tapImportButton(WidgetTester tester) async {
    await tester.tap(find.text('导入课表').first);
    await tester.pumpAndSettle();
  }

  /// 写入一门课（默认：周一 5-8 节、2-18 周）。
  Future<void> addCourse(
    String title, {
    int weekday = 1,
    int startPeriod = 5,
    int endPeriod = 8,
    int startWeek = 2,
    int endWeek = 18,
    String? location,
    String? teacher,
    String? color,
  }) {
    return courses.create(
      title: title,
      weekday: weekday,
      startPeriod: startPeriod,
      endPeriod: endPeriod,
      startWeek: startWeek,
      endWeek: endWeek,
      location: location,
      teacher: teacher,
      color: color,
    );
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    courses = CourseRepository(db);
    settings = SettingsRepository(db);
    fixedNow = DateTime(2026, 9, 14, 10); // 周一，第 2 教学周
  });

  tearDown(() async {
    await db.close();
  });

  group('空态与入口', () {
    testWidgets('无课程时展示空态与「导入课表」入口', (tester) async {
      await pumpApp(tester);
      await openTimetable(tester);

      expect(find.text('还没有课程'), findsOneWidget);
      expect(
        find.text('导入课表文件（.ics / .json），或手动添加一门课'),
        findsOneWidget,
      );
      // 头部按钮 + 空态 CTA 共两个「导入课表」入口，另有「添加课程」。
      expect(find.text('导入课表'), findsNWidgets(2));
      expect(find.text('添加课程'), findsOneWidget);
    });

    testWidgets('未设学期基准时提示设置，并按「全部课程」展示', (tester) async {
      await addCourse('算法设计与分析', weekday: 4, startPeriod: 5, endPeriod: 8);
      await pumpApp(tester);
      await openTimetable(tester);

      // 未设基准：无法按教学周筛选，退化为全部课程 + 引导设置。
      expect(find.text('全部课程'), findsOneWidget);
      expect(find.text('设置开学第 1 周周一后，可按教学周查看'), findsOneWidget);
      expect(find.text('设置开学日期'), findsOneWidget);
      expect(find.text('算法设计与分析'), findsOneWidget);
    });
  });

  group('教学周网格', () {
    testWidgets('按当前教学周筛选：只显示本周有课的课程', (tester) async {
      await settings.updateSemesterStartDate('2026-09-07');
      // 本周（第 2 周）有课。
      await addCourse('软件需求工程', weekday: 2, startPeriod: 3, endPeriod: 4);
      // 第 11 周才开始：本周不显示。
      await addCourse('移动智能', weekday: 1, startPeriod: 5, endPeriod: 8,
          startWeek: 11, endWeek: 18);

      await pumpApp(tester);
      await openTimetable(tester);

      expect(find.text('第 2 周'), findsOneWidget);
      expect(find.text('软件需求工程'), findsOneWidget);
      expect(find.text('移动智能'), findsNothing);
      // 摘要：1 门课 2 节。
      expect(find.text('· 1 门课 · 2 节'), findsOneWidget);
      // 日期范围（第 2 周：9/14 - 9/20）。
      expect(find.text('9月14日 – 20日'), findsOneWidget);
      // 学期基准以按钮文本呈现，可点开修改。
      expect(find.text('学期：2026-09-07 起'), findsOneWidget);
    });

    testWidgets('翻到第 11 周显示晚开课程；跨月日期范围带月份', (tester) async {
      await settings.updateSemesterStartDate('2026-09-07');
      // 早段课程：第 2-10 周结束，第 11 周应已不在网格上。
      await addCourse('论文写作与学术规范', weekday: 2, startPeriod: 3, endPeriod: 4,
          startWeek: 2, endWeek: 10);
      await addCourse('移动智能', weekday: 1, startPeriod: 5, endPeriod: 8,
          startWeek: 11, endWeek: 18, location: '教A209', teacher: '杨欢');

      await pumpApp(tester);
      await openTimetable(tester);

      expect(find.text('论文写作与学术规范'), findsOneWidget);
      expect(find.text('移动智能'), findsNothing);

      // 连续点「下一周」9 次：第 2 周 → 第 11 周。
      for (var i = 0; i < 9; i++) {
        await tester.tap(find.byTooltip('下一周'));
        await tester.pumpAndSettle();
      }

      expect(find.text('第 11 周'), findsOneWidget);
      expect(find.text('移动智能'), findsOneWidget);
      expect(find.text('论文写作与学术规范'), findsNothing);
      // 第 11 周：2026-11-16 ~ 11-22。
      expect(find.text('11月16日 – 22日'), findsOneWidget);
      // 翻走后出现「回到本周」。
      await tester.tap(find.text('回到本周'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 周'), findsOneWidget);
      expect(find.text('论文写作与学术规范'), findsOneWidget);
    });

    testWidgets('单双周：单周课在双周不显示', (tester) async {
      await settings.updateSemesterStartDate('2026-09-07');
      await courses.create(
        title: '单周研讨课',
        weekday: 1,
        startPeriod: 5,
        endPeriod: 6,
        startWeek: 2,
        endWeek: 6,
        weekParity: 'odd',
      );

      await pumpApp(tester);
      await openTimetable(tester);

      // 第 2 周（偶数）不显示单周课。
      expect(find.text('单周研讨课'), findsNothing);
      await tester.tap(find.byTooltip('下一周'));
      await tester.pumpAndSettle();
      // 第 3 周（奇数）显示。
      expect(find.text('第 3 周'), findsOneWidget);
      expect(find.text('单周研讨课'), findsOneWidget);
    });

    testWidgets('课程卡片展示地点/教师，点击弹出详情并可编辑', (tester) async {
      await settings.updateSemesterStartDate('2026-09-07');
      await addCourse('移动智能',
          weekday: 1,
          startPeriod: 5,
          endPeriod: 8,
          location: '教A209',
          teacher: '杨欢');

      await pumpApp(tester);
      await openTimetable(tester);

      // 4 节跨度可容纳「地点 · 教师」副行。
      expect(find.text('教A209 · 杨欢'), findsOneWidget);

      await tester.tap(find.text('移动智能'));
      await tester.pumpAndSettle();

      // 详情把周次/节次/钟点补成完整语义。
      expect(find.textContaining('2-18 周 · 周一 第 5-8 节'), findsOneWidget);
      expect(find.textContaining('14:00-17:10'), findsOneWidget);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });
  });

  group('导入课表', () {
    testWidgets('粘贴课表 JSON：校验通过后可导入，课程与学期基准一并落库', (tester) async {
      await pumpApp(tester);
      await openTimetable(tester);

      await tapImportButton(tester);
      expect(find.text('导入课表'), findsWidgets); // 对话框标题

      await tester.enterText(
        find.byType(TextField).first,
        '{"timetable":{"semester_start":"2026-09-07"},'
        '"courses":[{"title":"算法设计与分析","teacher":"梁军","location":"教A309",'
        '"weekday":4,"start_period":5,"end_period":8,"start_week":2,"end_week":8,'
        '"category":"学科基础课"}]}',
      );
      // 400ms 防抖自动校验：pumpAndSettle 不会推进纯 Timer，需显式走时间。
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('校验通过：1 门课程'), findsOneWidget);
      expect(
        find.textContaining('将导入 1 门课程'),
        findsOneWidget,
      );

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      // 课程落库并渲染在第 2 周网格上。
      expect(find.text('算法设计与分析'), findsOneWidget);
      expect(await courses.all(), hasLength(1));
      // 学期基准由文件写入设置。
      final setting = await settings.get();
      expect(setting.semesterStartDate, '2026-09-07');
      expect(find.text('学期：2026-09-07 起'), findsOneWidget);
    });

    testWidgets('校验不通过时不写入任何课程，导入按钮不可用', (tester) async {
      await pumpApp(tester);
      await openTimetable(tester);
      await tapImportButton(tester);

      await tester.enterText(
        find.byType(TextField).first,
        '{"courses":[{"title":"缺星期","start_period":1,"end_period":2,'
        '"start_week":1,"end_week":2}]}',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('发现 1 个问题'), findsOneWidget);
      expect(find.textContaining('星期几不合法'), findsOneWidget);
      final importButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '导入'),
      );
      expect(importButton.onPressed, isNull);
      expect(await courses.all(), isEmpty);
    });

    testWidgets('替换/追加选择影响写入结果文案', (tester) async {
      await addCourse('原有课程');
      await pumpApp(tester);
      await openTimetable(tester);
      await tapImportButton(tester);

      await tester.enterText(
        find.byType(TextField).first,
        '{"courses":[{"title":"新课","weekday":2,"start_period":1,'
        '"end_period":2,"start_week":1,"end_week":4}]}',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      // 默认替换：说明文案提示会先清空。
      expect(find.text('先清空再写入（重复导入不翻倍）'), findsOneWidget);

      await tester.tap(find.text('追加到现有课表'));
      await tester.pumpAndSettle();
      expect(find.text('保留现有课程，仅追加新课'), findsOneWidget);

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      // 追加后两门课都在。
      expect(await courses.all(), hasLength(2));
      expect(find.text('原有课程'), findsOneWidget);
      expect(find.text('新课'), findsOneWidget);
    });
  });

  group('清空课表', () {
    testWidgets('二次确认后清空课程，学期设置保留', (tester) async {
      await settings.updateSemesterStartDate('2026-09-07');
      await addCourse('移动智能', weekday: 1, startPeriod: 5, endPeriod: 8);
      await pumpApp(tester);
      await openTimetable(tester);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空课表'));
      await tester.pumpAndSettle();

      expect(find.text('清空课表？'), findsOneWidget);
      // 确认对话框里的「清空」按钮。
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();

      expect(await courses.all(), isEmpty);
      expect(find.text('还没有课程'), findsOneWidget);
      // 学期基准不被清空（只影响课程）。
      final setting = await settings.get();
      expect(setting.semesterStartDate, '2026-09-07');
    });
  });

  group('新增课程表单', () {
    testWidgets('通过表单添加课程后立即出现在网格中', (tester) async {
      await settings.updateSemesterStartDate('2026-09-07');
      await pumpApp(tester);
      await openTimetable(tester);

      await tester.tap(find.text('添加课程'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '论文写作与学术规范');
      await tester.pumpAndSettle();

      // 表单默认周一 1-2 节、1-18 周；直接保存。
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      final saved = (await courses.all()).single;
      expect(saved.title, '论文写作与学术规范');
      expect(saved.weekday, 1);
      expect(saved.startPeriod, 1);
      expect(saved.endPeriod, 2);
      expect(saved.color, CoursePalette.at(0));
      expect(find.text('论文写作与学术规范'), findsOneWidget);
    });

    testWidgets('课程名为空时校验拦截，不写入', (tester) async {
      await pumpApp(tester);
      await openTimetable(tester);
      await tester.tap(find.text('添加课程'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      expect(find.text('请输入课程名'), findsOneWidget);
      expect(await courses.all(), isEmpty);
      // 表单未关闭，用户可继续输入。
      expect(find.text('添加课程'), findsWidgets);
    });
  });

  group('作息表联动', () {
    testWidgets('节次标签列展示 12 个节次与起止钟点', (tester) async {
      await addCourse('测试课');
      await pumpApp(tester);
      await openTimetable(tester);

      for (var period = 1; period <= ClassPeriods.count; period++) {
        expect(
          find.text('$period'),
          findsWidgets,
          reason: '节次标签列应包含第 $period 节',
        );
      }
      // 首节与末节的起始钟点。
      expect(find.text('08:30'), findsOneWidget);
      expect(find.text('21:30'), findsOneWidget);
    });
  });
}
