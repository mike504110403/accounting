import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/pie_card.dart';
import 'package:accounting/features/stats/stats_page.dart';
import 'package:accounting/features/stats/trend_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../support/fixtures.dart';

/// 真實組裝（common 紀律）：`ProviderScope` override `ledgerRepositoryProvider`
/// 為 `repoWith(...)`，讓 [StatsPage] 走真正的 `snapshotProvider` → Notifier
/// → provider 這條路，不釘死任何一顆 provider 的值。
void main() {
  const ledger = Ledger(id: kLedgerId, name: '我們的家', inviteCode: 'A7K3QZ');
  final members = [
    Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: DateTime(2026, 1, 1)),
    Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: DateTime(2026, 1, 1)),
  ];
  const categories = [
    Category(id: 'c-food', ledgerId: kLedgerId, kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0),
    Category(id: 'c-transport', ledgerId: kLedgerId, kind: EntryKind.expense, name: '交通', icon: 'directions_car', sort: 1),
    Category(id: 'c-salary', ledgerId: kLedgerId, kind: EntryKind.income, name: '薪水', icon: 'payments', sort: 0),
  ];

  final now = DateTime.now();
  DateTime day(int d) => DateTime(now.year, now.month, d);

  // 摘要：收入 20,000／支出 11,000（Mike 6,000＋老婆 2,000＋共同錢包 3,000）／
  // 損益 9,000／共同餘額 20,000（收入）−3,000（共同錢包支出）＝17,000。
  final seedEntries = <Entry>[
    Entry(
      id: 'inc-1',
      ledgerId: kLedgerId,
      kind: EntryKind.income,
      amount: 20000,
      categoryId: 'c-salary',
      occurredOn: day(2),
      createdBy: kMeId,
    ),
    Entry(
      id: 'e-mike-1',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: 4000,
      categoryId: 'c-food',
      occurredOn: day(3),
      createdBy: kMeId,
      payerId: kMeId,
    ),
    Entry(
      id: 'e-mike-2',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: 2000,
      categoryId: 'c-transport',
      occurredOn: day(4),
      createdBy: kMeId,
      payerId: kMeId,
    ),
    Entry(
      id: 'e-wife-1',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: 2000,
      categoryId: 'c-food',
      occurredOn: day(5),
      createdBy: kWifeId,
      payerId: kWifeId,
    ),
    Entry(
      id: 'e-common-1',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: 3000,
      categoryId: 'c-food',
      occurredOn: day(6),
      createdBy: kMeId,
    ),
  ];

  final seedTopups = [
    topupFixture(memberId: kMeId, amount: 10000, occurredOn: day(1)),
    topupFixture(memberId: kWifeId, amount: 10000, occurredOn: day(1)),
  ];

  // 回傳型別交給推論：flutter_riverpod 3 沒有匯出 `Override` 這個型別名。
  overridesFor({
    List<Entry>? entries,
    List<PersonalTopup>? topups,
    List<MonthClose>? closes,
    List<Member>? membersValue,
  }) =>
      [
        ledgerRepositoryProvider.overrideWithValue(repoWith(
          ledger: ledger,
          members: membersValue ?? members,
          categories: categories,
          entries: entries ?? seedEntries,
          topups: topups ?? seedTopups,
          closes: closes ?? const [],
        )),
      ];

  Future<void> phone(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Finder inSummary(Finder f) =>
      find.descendant(of: find.byKey(const Key('month-summary')), matching: f);
  Finder inPie(Finder f) => find.descendant(of: find.byType(PieCard), matching: f);
  Finder inTrend(Finder f) => find.descendant(of: find.byType(TrendCard), matching: f);

  Future<void> pumpStats(
    WidgetTester tester, {
    List<Entry>? entries,
    List<PersonalTopup>? topups,
    List<MonthClose>? closes,
  }) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(entries: entries, topups: topups, closes: closes),
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('月摘要四數字：收入 20,000／支出 11,000／損益 9,000／共同餘額 17,000', (tester) async {
    await pumpStats(tester);

    expect(inSummary(find.text('收入')), findsOneWidget);
    expect(inSummary(find.text('20,000')), findsOneWidget);
    expect(inSummary(find.text('支出')), findsOneWidget);
    expect(inSummary(find.text('11,000')), findsOneWidget);
    expect(inSummary(find.text('損益')), findsOneWidget);
    expect(inSummary(find.text('9,000')), findsOneWidget);
    expect(inSummary(find.text('共同餘額')), findsOneWidget);
    expect(inSummary(find.text('17,000')), findsOneWidget);
  });

  testWidgets('變異證明：sharedBalance 桶末誤用桶內淨額（seed 恆真，需上月有共同收支才測得出）',
      (tester) async {
    // seed 本身只有本月資料，累計水位跟「只算本月」的錯誤算法碰巧同值（17,000），
    // 測不出誰對誰錯；這裡另造上月有共同收入 5,000 的 fixture 才能真的分辨兩者。
    final prevMonth = DateTime(now.year, now.month - 1, 15);
    final withPriorIncome = [
      Entry(
        id: 'inc-prev',
        ledgerId: kLedgerId,
        kind: EntryKind.income,
        amount: 5000,
        categoryId: 'c-salary',
        occurredOn: prevMonth,
        createdBy: kMeId,
      ),
      ...seedEntries,
    ];
    await pumpStats(tester, entries: withPriorIncome);

    // 累計水位＝上月 5,000 ＋ 本月（20,000 − 3,000）＝22,000；若實作誤把
    // sharedBalance 算成「本月桶內淨額」（不含上月累計）會紅成 17,000。
    expect(inSummary(find.text('22,000')), findsOneWidget,
        reason: 'sharedBalance 該是累計水位，不是本月桶內淨額');
    expect(inSummary(find.text('17,000')), findsNothing,
        reason: '17,000 是「只算本月」的錯誤值，不該出現');
  });

  testWidgets('月摘要卡：monthSummaryProvider 未回應時 fallback 本地 balance_math 公式', (tester) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ledgerRepositoryProvider.overrideWithValue(
          NeverRespondingMonthSummaryRepository(
            seed: snapshotWith(
              ledger: ledger,
              members: members,
              categories: categories,
              entries: seedEntries,
              topups: seedTopups,
            ),
          ),
        ),
      ],
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();

    // server（monthSummaryProvider）永遠不 resolve → `.value` 恆 null，卡片必須
    // fallback 本地 balance_math.sharedBalance（17,000），不是空白或丟例外。
    expect(inSummary(find.text('17,000')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('圓餅依付款人：Mike 6,000／老婆 2,000／共同錢包 3,000', (tester) async {
    await pumpStats(tester);

    await tester.tap(find.text('付款人'));
    await tester.pumpAndSettle();

    expect(inPie(find.text('Mike')), findsOneWidget);
    expect(inPie(find.text('6,000')), findsOneWidget);
    expect(inPie(find.text('老婆')), findsOneWidget);
    expect(inPie(find.text('2,000')), findsOneWidget);
    expect(inPie(find.text('共同錢包')), findsOneWidget);
    expect(inPie(find.text('3,000')), findsOneWidget);
  });

  testWidgets('圓餅依分類：與 seed 分類合計一致（食品 9,000／交通 2,000）', (tester) async {
    await pumpStats(tester);

    expect(inPie(find.text('食品')), findsOneWidget);
    expect(inPie(find.text('9,000')), findsOneWidget);
    expect(inPie(find.text('交通')), findsOneWidget);
    expect(inPie(find.text('2,000')), findsOneWidget);
  });

  testWidgets('趨勢：月顆粒度 legend 含每位成員「補入」；四種顆粒度切換無 crash', (tester) async {
    await pumpStats(tester);

    expect(inTrend(find.text('花費')), findsOneWidget);
    expect(inTrend(find.text('共同餘額')), findsOneWidget);
    expect(inTrend(find.text('Mike 補入')), findsOneWidget);
    expect(inTrend(find.text('老婆 補入')), findsOneWidget);

    for (final g in ['日', '週', '月', '年']) {
      await tester.tap(find.descendant(of: find.byType(TrendCard), matching: find.text(g)));
      await tester.pumpAndSettle();
      expect(find.byType(SfCartesianChart), findsOneWidget, reason: '顆粒度 $g');
      expect(tester.takeException(), isNull, reason: '顆粒度 $g');
    }

    // 切回日／週：legend 不該再出現補入線
    await tester.tap(find.descendant(of: find.byType(TrendCard), matching: find.text('日')));
    await tester.pumpAndSettle();
    expect(inTrend(find.text('Mike 補入')), findsNothing);
    expect(inTrend(find.text('老婆 補入')), findsNothing);
  });

  // 拆成兩個獨立 test（而不是同一個 test 裡連續兩次 pumpWidget(ProviderScope(...))）：
  // flutter_riverpod 3.4.2 對同一顆 tree 連續 pump 兩次 ProviderScope 會重用既有
  // container，「先驗 A 尺寸再驗 B 尺寸」這種寫法有假陽性風險（見 common 紀律）。
  testWidgets('390×844 不爆版', (tester) async {
    await pumpStats(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('390×667 不爆版', (tester) async {
    await phone(tester, size: const Size(390, 667));
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(),
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('空資料：圓餅與趨勢都顯示提示、不炸', (tester) async {
    await pumpStats(tester, entries: const [], topups: const []);

    expect(find.text('這個期間沒有支出'), findsOneWidget);
    expect(find.byType(SfCircularChart), findsNothing);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面寬度限寬置中、不爆版', (tester) async {
    await phone(tester, size: const Size(1440, 1200));
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(),
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('stats-list'))).width, 560);
  });
}
