import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/trend_card.dart';
import 'package:accounting/features/stats/trend_math.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

/// [TrendCard] 的獨立 widget 測試（不吃 [StatsPage]／`MonthAppBar`，純粹餵
/// [Bucket]／[Member] 驗行為）：v1.5 三組線（花費、共同餘額、每人補入）、
/// 補入線只在月／年顆粒度出現、390px 不爆版。
void main() {
  final members = [
    Member(id: 'mike', ledgerId: 'l', userId: 'u1', displayName: 'Mike', joinedAt: DateTime(2026, 1, 1)),
    Member(id: 'wife', ledgerId: 'l', userId: 'u2', displayName: '老婆', joinedAt: DateTime(2026, 1, 1)),
  ];

  List<Bucket> bucketsWithTopup() => [
        for (var i = 0; i < 3; i++)
          Bucket(
            label: '${i + 1}月',
            start: DateTime(2026, i + 1, 1),
            end: DateTime(2026, i + 1, 28),
            spend: 100 * (i + 1),
            sharedBalance: 500,
            topupByMember: const {'mike': 1000, 'wife': 2000},
          ),
      ];

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget harness({
    required List<Bucket> buckets,
    Granularity granularity = Granularity.month,
    ValueChanged<Granularity>? onGranularityChanged,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            TrendCard(
              buckets: buckets,
              members: members,
              granularity: granularity,
              onGranularityChanged: onGranularityChanged ?? (_) {},
            ),
          ]),
        ),
      );

  int seriesCount(WidgetTester tester) =>
      tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).series.length;

  testWidgets('月顆粒度 legend 含每位成員「OO 補入」', (tester) async {
    await phone(tester);
    await tester.pumpWidget(harness(buckets: bucketsWithTopup()));
    await tester.pumpAndSettle();

    expect(find.text('花費'), findsOneWidget);
    expect(find.text('共同餘額'), findsOneWidget);
    expect(find.text('Mike 補入'), findsOneWidget);
    expect(find.text('老婆 補入'), findsOneWidget);
    // 花費（開）＋ Mike 補入（開）＋ 老婆 補入（開）；共同餘額預設收起。
    expect(seriesCount(tester), 3);
  });

  testWidgets('日／週顆粒度沒有補入線（TrendCard 依 granularity 決定，不看桶內資料）', (tester) async {
    await phone(tester);
    // 刻意連空 map 的桶都不用（bucketsWithTopup 本身有資料）：驗證是 granularity
    // 本身擋掉補入線，不是「剛好這批桶沒有補入資料」這種巧合。
    await tester.pumpWidget(harness(buckets: bucketsWithTopup(), granularity: Granularity.day));
    await tester.pumpAndSettle();

    expect(find.text('花費'), findsOneWidget);
    expect(find.text('共同餘額'), findsOneWidget);
    expect(find.text('Mike 補入'), findsNothing);
    expect(find.text('老婆 補入'), findsNothing);
    expect(seriesCount(tester), 1, reason: '只剩花費（開），共同餘額仍收起、沒有補入線可開');
  });

  testWidgets('四種顆粒度切換無 crash', (tester) async {
    await phone(tester);
    var granularity = Granularity.month;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) => harness(
        buckets: bucketsWithTopup(),
        granularity: granularity,
        onGranularityChanged: (g) => setState(() => granularity = g),
      ),
    ));
    await tester.pumpAndSettle();

    for (final label in ['日', '週', '月', '年']) {
      await tester.tap(find.descendant(
          of: find.byKey(const Key('trend-granularity')), matching: find.text(label)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '顆粒度 $label');
      expect(find.byType(SfCartesianChart), findsOneWidget, reason: '顆粒度 $label');
    }
  });

  testWidgets('390px 不爆版：顆粒度列與線別列都在單行高度內', (tester) async {
    await phone(tester);
    await tester.pumpWidget(harness(buckets: bucketsWithTopup()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(tester.getSize(find.byKey(const Key('trend-granularity'))).height, kTrendToggleHeight);
    expect(tester.getSize(find.byKey(const Key('trend-toggles'))).height, kTrendToggleHeight);
    expect(kTrendToggleHeight, greaterThanOrEqualTo(44.0), reason: 'spec v1.1：點擊目標 ≥44px');
  });

  testWidgets('切換線別開關：series 數量跟著變、全關顯示提示、圖高不變', (tester) async {
    await phone(tester);
    await tester.pumpWidget(harness(buckets: bucketsWithTopup()));
    await tester.pumpAndSettle();

    Future<void> toggle(String label) async {
      await tester.tap(find.descendant(of: find.byKey(const Key('trend-toggles')), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    expect(seriesCount(tester), 3);
    await toggle('花費');
    await toggle('Mike 補入');
    await toggle('老婆 補入');
    expect(seriesCount(tester), 0);
    expect(find.text('請至少開啟一條線'), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);

    await toggle('花費');
    expect(seriesCount(tester), 1);
    expect(find.text('請至少開啟一條線'), findsNothing);
  });

  testWidgets('全部桶都是 0：顯示「這個範圍沒有資料」', (tester) async {
    await phone(tester);
    final zero = [
      Bucket(
        label: '1月',
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        spend: 0,
        sharedBalance: 0,
        topupByMember: const {},
      ),
    ];
    await tester.pumpWidget(harness(buckets: zero));
    await tester.pumpAndSettle();
    expect(find.text('這個範圍沒有資料'), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);
  });
}
