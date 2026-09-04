import 'package:accounting/data/month_summary_provider.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/domain/month_summary.dart' as domain_summary;
import 'package:accounting/app/month_app_bar.dart';
import 'package:accounting/app/router.dart';
import 'package:accounting/features/entries/entries_page.dart';
import 'package:accounting/features/stats/pie_card.dart';
import 'package:accounting/features/stats/stats_page.dart';
import 'package:accounting/features/stats/trend_card.dart';
import 'package:accounting/features/stats/trend_math.dart';
import 'package:accounting/features/stats/view_math.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// 注意：`router`（`lib/app/router.dart`）是 top-level 單例，**跨測試共用**。
/// 任何用 `AccountingApp` 開機的測試都會沿用上一條測試留下的路由位置，
/// 所以需要特定分頁時一律先 `router.go(...)`，不要假設開機在 `/entries`。
class _FixedEntries extends EntriesNotifier {
  _FixedEntries(this.seed);
  final List<Entry> seed;
  @override
  List<Entry> build() => seed;
}

class _FixedAllocations extends AllocationsNotifier {
  _FixedAllocations(this.seed);
  final List<BudgetAllocation> seed;
  @override
  List<BudgetAllocation> build() => seed;
}

class _FixedSettlements extends SettlementsNotifier {
  _FixedSettlements(this.seed);
  final List<Settlement> seed;
  @override
  List<Settlement> build() => seed;
}

class _FixedMonthCloses extends MonthClosesNotifier {
  _FixedMonthCloses(this.seed);
  final List<MonthClose> seed;
  @override
  List<MonthClose> build() => seed;
}

void main() {
  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month, 1);
  DateTime day(int d) => DateTime(now.year, now.month, d);

  const ledger = Ledger(
    id: kLedgerId,
    name: '我們的家',
    inviteCode: 'A7K3QZ',
    defaultRatio: {kMeId: 50, kWifeId: 50},
    openingBalanceShared: 5000,
  );
  // v1.4：個人餘額＝每月補入額 × 未清帳月份數 ＋ 淨變動；加入月＝本月 → 只補一次。
  final members = [
    Member(
        id: kMeId,
        ledgerId: kLedgerId,
        userId: 'u1',
        displayName: 'Mike',
        monthlyTopup: 1000,
        joinedAt: DateTime(now.year, now.month, 1)),
    Member(
        id: kWifeId,
        ledgerId: kLedgerId,
        userId: 'u2',
        displayName: '老婆',
        joinedAt: DateTime(now.year, now.month, 1)),
  ];
  const categories = [
    Category(
        id: 'c-food',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        name: '食品',
        icon: 'restaurant',
        sort: 0),
    Category(
        id: 'c-salary',
        ledgerId: kLedgerId,
        kind: EntryKind.income,
        name: '薪水',
        icon: 'payments',
        sort: 0),
  ];

  final seed = <Entry>[
    Entry(
      id: 'x-1',
      ledgerId: kLedgerId,
      kind: EntryKind.income,
      scope: EntryScope.shared,
      amount: 1000,
      categoryId: 'c-salary',
      occurredOn: day(2),
      createdBy: kMeId,
    ),
    Entry(
      id: 'x-2',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: 400,
      categoryId: 'c-food',
      occurredOn: day(3),
      createdBy: kMeId,
      splitMethod: SplitMethod.common,
    ),
    Entry(
      id: 'x-3',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.private,
      amount: 100,
      categoryId: 'c-food',
      occurredOn: day(4),
      createdBy: kMeId,
      payerId: kMeId,
    ),
  ];

  final allocations = <BudgetAllocation>[
    BudgetAllocation(
      id: 'al-1',
      ledgerId: kLedgerId,
      categoryId: 'c-food',
      amount: 3000,
      occurredOn: day(1),
      createdBy: kMeId,
    ),
  ];

  // 回傳型別交給推論：flutter_riverpod 3 沒有匯出 `Override` 這個型別名。
  overridesFor({
    List<Entry>? entries,
    List<BudgetAllocation>? allocations,
    Ledger? ledgerValue,
    List<Category>? categoriesValue,
    List<Member>? membersValue,
    List<Settlement>? settlementsValue,
    List<MonthClose>? closes,
    // 少數測試（server 未回應時的 fallback）需要換掉整個 repository 實作，不能再疊一個
    // `ledgerRepositoryProvider.overrideWithValue`——同一個 provider 在同一個 container
    // 覆寫兩次會被 Riverpod 直接擋下來。
    InMemoryLedgerRepository? repository,
  }) => [
        ledgerProvider.overrideWithValue(ledgerValue ?? ledger),
        membersProvider.overrideWithValue(membersValue ?? members),
        categoriesProvider.overrideWithValue(categoriesValue ?? categories),
        entriesProvider.overrideWith(() => _FixedEntries(entries ?? seed)),
        allocationsProvider.overrideWith(() => _FixedAllocations(allocations ?? const [])),
        // 這組 fixture 自成一格：結算狀態也要顯式控制，個人餘額斷言才不會
        // 暗中吃到全域 mock 的 s-1（雖然它是 pending、目前算不到，但別讓
        // 測試的正確性依賴「剛好沒被算到」這種巧合）。
        settlementsProvider.overrideWith(() => _FixedSettlements(settlementsValue ?? const [])),
        // 清帳紀錄（v1.4／ADR-0008）：預設空，個人餘額月份語意測試會顯式帶入。
        monthClosesProvider.overrideWith(() => _FixedMonthCloses(closes ?? const [])),
        // month_summary（衍生數字改吃 DB）：InMemory repo 餵同一份 fixture。
        ledgerRepositoryProvider.overrideWithValue(repository ??
            repoWith(
              ledger: ledgerValue ?? ledger,
              members: membersValue ?? members,
              categories: categoriesValue ?? categories,
              entries: entries ?? seed,
              allocations: allocations ?? const [],
              settlements: settlementsValue ?? const [],
              closes: closes ?? const [],
            )),
      ];

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // 月份標題斷言一律限定在 MonthTitle 內：卡片副標也可能出現月份字樣。
  Finder monthTitle(DateTime m) => find.descendant(
        of: find.byKey(const Key('month-title')),
        matching: find.text('${m.year}年${m.month}月'),
      );

  // 分類名稱同時出現在圓餅圖例與趨勢的分類切換列，斷言一律限定範圍。
  Finder inPie(Finder f) => find.descendant(of: find.byType(PieCard), matching: f);
  Finder inTrend(Finder f) => find.descendant(of: find.byType(TrendCard), matching: f);
  Finder inSummary(Finder f) =>
      find.descendant(of: find.byKey(const Key('month-summary')), matching: f);

  Future<void> pumpStats(
    WidgetTester tester, {
    List<Entry>? entries,
    List<BudgetAllocation>? allocations,
    Ledger? ledgerValue,
    List<Category>? categoriesValue,
    List<Member>? membersValue,
    List<Settlement>? settlementsValue,
    List<MonthClose>? closes,
  }) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(
        entries: entries,
        allocations: allocations,
        ledgerValue: ledgerValue,
        categoriesValue: categoriesValue,
        membersValue: membersValue,
        settlementsValue: settlementsValue,
        closes: closes,
      ),
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('真實組裝：從根 App 點「統計」Tab 看到月摘要', (tester) async {
    await phone(tester);
    await tester.pumpWidget(const ProviderScope(child: AccountingApp()));
    await tester.pumpAndSettle();

    expect(find.text('帳目'), findsWidgets); // 底部 Tab 與 AppBar 皆可命中，不綁定帳目頁內容

    await tester.tap(find.text('統計'));
    await tester.pumpAndSettle();

    expect(find.byType(StatsPage), findsOneWidget);
    expect(find.text('月摘要'), findsOneWidget);
    // 月摘要卡的 balance 格借用趨勢 legend 同一個 label（v1.4）：家庭視角是「共同餘額」。
    expect(inSummary(find.text('共同餘額')), findsOneWidget);
    expect(find.text('支出分布'), findsOneWidget);
    expect(find.text('趨勢'), findsOneWidget);
    expect(find.text('家庭'), findsOneWidget);
    expect(find.byType(SfCircularChart), findsOneWidget);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    // 自製切換列一排三條線，取代原本的 FilterChip 與 Syncfusion 內建 legend
    // （趨勢線的 balance legend 家庭視角叫「共同餘額」，v1.4，ADR-0008）。
    for (final l in ['花費', '超支', '共同餘額']) {
      expect(find.descendant(of: find.byType(TrendCard), matching: find.text(l)), findsOneWidget,
          reason: '切換列應有 $l');
    }
    expect(find.byType(FilterChip), findsNothing);
  });

  testWidgets('視角切換用共用 ViewModeToggle，不自製', (tester) async {
    await pumpStats(tester);
    final toggle = find.byKey(const Key('view-mode-toggle'));
    expect(toggle, findsOneWidget);
    // 頁面上只有這一個視角切換，沒有自製的第二份
    expect(find.byType(SegmentedButton<ViewMode>), findsOneWidget);

    // 透過共用元件切到個人，頁面確實跟著換算
    // v1.3 個人餘額（personalBalance）：期初 1000 − 私人支出 100（x-3）＝900
    // （x-1 是 shared 收入、x-2 是無 payerId 的共同錢包支出，皆不動個人餘額）。
    await tester.tap(find.descendant(of: toggle, matching: find.text('個人')));
    await tester.pumpAndSettle();
    expect(inSummary(find.text('900')), findsOneWidget);
  });

  testWidgets('趨勢預設顆粒度是「月」', (tester) async {
    await pumpStats(tester);
    final seg = tester.widget<SegmentedButton<Granularity>>(
      find.byKey(const Key('trend-granularity')),
    );
    expect(seg.selected, {Granularity.month});
  });

  testWidgets('月摘要：家庭視角數值 ＋ 切個人後改成我的份額', (tester) async {
    await pumpStats(tester);

    // 家庭：收入 1000、支出 400（私人 100 不算）、損益 600
    // 餘額（v1.4 sharedBalance）：期初 5000 ＋1000 收入 −400 共同錢包支出＝5600
    expect(inSummary(find.text('1,000')), findsOneWidget);
    expect(inSummary(find.text('400')), findsOneWidget);
    expect(inSummary(find.text('600')), findsOneWidget);
    expect(inSummary(find.text('5,600')), findsOneWidget);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();

    // 個人：收入 0（x-1 共同收入進共同餘額，不進個人視角）、支出 200+100=300、損益 −300
    // 餘額（v1.4 personalBalance）：本月補入額 1000 − 私人支出 100（x-3）＝900
    // （x-2 的 200 是我在共同支出的份額，viewEntries 換算給月摘要「支出」看，
    //  但 personalBalance 只認 payerId==me 的代墊全額，x-2 沒有 payerId 不算）
    expect(inSummary(find.text('0')), findsOneWidget);
    expect(inSummary(find.text('300')), findsOneWidget);
    expect(inSummary(find.text('-300')), findsOneWidget);
    expect(inSummary(find.text('900')), findsOneWidget);
  });

  testWidgets('點月份標題開年月滾輪：點彈窗外不變、「本月」跳回本月', (tester) async {
    await pumpStats(tester);
    final prev = DateTime(thisMonth.year, thisMonth.month - 1, 1);
    expect(monthTitle(thisMonth), findsOneWidget);
    expect(find.byKey(const Key('month-prev')), findsOneWidget, reason: '箭頭與滾輪並存（Mike 裁示）');

    // 年份／月份兩個獨立滾輪
    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-year')), findsOneWidget);
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);

    await tester.tapAt(const Offset(200, 20)); // 點彈窗外：沒動滾輪 → 關閉且不變
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-month')), findsNothing, reason: '彈窗應已關閉');
    expect(monthTitle(thisMonth), findsOneWidget);

    // 先離開本月，「本月」才驗得出東西（停在本月按本月是假守衛）
    await tester.fling(find.byKey(const Key('month-title')), const Offset(120, 0), 800);
    await tester.pumpAndSettle();
    expect(monthTitle(prev), findsOneWidget);

    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('month-picker-today')));
    await tester.pumpAndSettle();
    expect(monthTitle(thisMonth), findsOneWidget);
  });

  testWidgets('左右滑月份標題切上下月並重算', (tester) async {
    await pumpStats(tester);
    final prev = DateTime(thisMonth.year, thisMonth.month - 1, 1);

    // 往右滑 → 上個月
    await tester.fling(find.byKey(const Key('month-title')), const Offset(120, 0), 800);
    await tester.pumpAndSettle();
    expect(monthTitle(prev), findsOneWidget);
    // 上個月沒帳 → 圓餅顯示提示不畫圖
    expect(find.text('這個期間沒有支出'), findsOneWidget);

    // 往左滑 → 回本月
    await tester.fling(find.byKey(const Key('month-title')), const Offset(-120, 0), 800);
    await tester.pumpAndSettle();
    expect(monthTitle(thisMonth), findsOneWidget);
    expect(find.text('這個期間沒有支出'), findsNothing);
  });

  testWidgets('空資料顯示提示、不畫圖', (tester) async {
    // 真的什麼都沒有：無帳、無預算、期初也是 0
    const empty = Ledger(
      id: kLedgerId,
      name: '我們的家',
      inviteCode: 'A7K3QZ',
      defaultRatio: {kMeId: 50, kWifeId: 50},
    );
    await pumpStats(tester, entries: const [], ledgerValue: empty);
    expect(find.text('這個期間沒有支出'), findsOneWidget);
    expect(find.text('這個範圍沒有資料'), findsOneWidget);
    // 圓餅沒東西可畫；趨勢圖區保留（軸與 legend 仍可用），只蓋一層提示
    expect(find.byType(SfCircularChart), findsNothing);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);
  });

  testWidgets('個人視角空資料同樣顯示提示、圖區保留高度（兩線都 0，過濾邏輯沒被視角改壞）',
      (tester) async {
    // 個人視角只有花費／餘額兩線，要讓兩者都是 0：Mike 期初改 0、無帳。
    final zeroMembers = [
      Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: DateTime(now.year, now.month, 1)),
      Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: DateTime(now.year, now.month, 1)),
    ];
    await pumpStats(tester, entries: const [], membersValue: zeroMembers);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();

    expect(inTrend(find.text('超支')), findsNothing, reason: '個人視角本來就沒有超支 toggle');
    expect(find.text('這個範圍沒有資料'), findsOneWidget);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有收入時趨勢照畫（餘額也算資料）', (tester) async {
    const zeroOpening = Ledger(
      id: kLedgerId,
      name: '我們的家',
      inviteCode: 'A7K3QZ',
      defaultRatio: {kMeId: 50, kWifeId: 50},
    );
    final incomeOnly = [seed.first]; // 只留那筆 1,000 收入
    await pumpStats(tester, entries: incomeOnly, ledgerValue: zeroOpening);

    // 沒有支出 → 圓餅不畫；但餘額有東西 → 趨勢要畫
    expect(find.text('這個期間沒有支出'), findsOneWidget);
    expect(find.text('這個範圍沒有資料'), findsNothing);
    expect(find.byType(SfCartesianChart), findsOneWidget);

    // 點切換列的「共同餘額」打開該線，圖仍正常（家庭視角標籤，v1.4）
    await tester.tap(inTrend(find.text('共同餘額')));
    await tester.pumpAndSettle();
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有期初餘額（無任何帳）時趨勢照畫', (tester) async {
    await pumpStats(tester, entries: const []); // 預設 ledger 期初 5000
    expect(find.text('這個範圍沒有資料'), findsNothing);
    expect(find.byType(SfCartesianChart), findsOneWidget);
  });

  testWidgets('圓餅依成員分組：common 錢包歸「共同錢包」', (tester) async {
    await pumpStats(tester);
    expect(inPie(find.text('食品')), findsOneWidget);

    await tester.tap(find.text('成員'));
    await tester.pumpAndSettle();
    expect(inPie(find.text('共同錢包')), findsOneWidget);
  });

  testWidgets('個人視角隱藏「成員」切換，切回家庭才出現', (tester) async {
    await pumpStats(tester);
    expect(find.text('分類'), findsOneWidget);
    expect(find.text('成員'), findsOneWidget);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    expect(find.text('成員'), findsNothing);
    expect(find.text('分類'), findsNothing);
    // 切換沒了，但圓餅仍以分類畫得出來
    expect(inPie(find.text('食品')), findsOneWidget);
    expect(find.byType(SfCircularChart), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    expect(find.text('成員'), findsOneWidget);
  });

  testWidgets('家庭選了「成員」後切個人：不殘留成員分佈', (tester) async {
    await pumpStats(tester);
    await tester.tap(find.text('成員'));
    await tester.pumpAndSettle();
    expect(inPie(find.text('共同錢包')), findsOneWidget);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    expect(inPie(find.text('共同錢包')), findsNothing);
    expect(inPie(find.text('食品')), findsOneWidget);

    // 切回家庭：state 已被拉回「依分類」，不會冒出使用者在個人視角看不到的選擇
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    expect(inPie(find.text('共同錢包')), findsNothing);
    expect(inPie(find.text('食品')), findsOneWidget);
  });

  testWidgets('圓餅切到週：出現週選擇 chips', (tester) async {
    await pumpStats(tester);
    final weekBtn = find.descendant(of: find.byType(PieCard), matching: find.text('單週'));
    expect(weekBtn, findsOneWidget);

    await tester.tap(weekBtn);
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsAtLeastNWidgets(4));
  });

  testWidgets('趨勢：四種顆粒度都畫得出來', (tester) async {
    await pumpStats(tester, allocations: allocations);

    for (final g in ['日', '週', '月', '年']) {
      await tester.tap(find.descendant(of: find.byType(TrendCard), matching: find.text(g)));
      await tester.pumpAndSettle();
      expect(find.byType(SfCartesianChart), findsOneWidget, reason: '顆粒度 $g');
      expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight,
          reason: '顆粒度 $g 圖區高度固定');
      expect(tester.takeException(), isNull, reason: '顆粒度 $g');
    }
  });

  testWidgets('切換列開關線別：series 數量隨之增減、全關顯示提示、圖區高度不變', (tester) async {
    await pumpStats(tester, allocations: allocations);

    int seriesCount() =>
        tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).series.length;
    Future<void> toggle(String label) async {
      await tester.tap(find.descendant(of: find.byType(TrendCard), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    // 餘額預設收起 → 兩條
    expect(seriesCount(), 2);
    expect(find.text('請至少開啟一條線'), findsNothing);

    // 打開共同餘額（家庭視角標籤，v1.4） → 三條
    await toggle('共同餘額');
    expect(seriesCount(), 3);

    // 逐條關掉，series 跟著減少
    await toggle('共同餘額');
    expect(seriesCount(), 2);
    await toggle('超支');
    expect(seriesCount(), 1);

    // 三條全關 → series 空、提示出現、圖區高度不變
    await toggle('花費');
    expect(seriesCount(), 0);
    expect(find.text('請至少開啟一條線'), findsOneWidget);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);
    expect(tester.takeException(), isNull);

    // 再打開一條就收起提示
    await toggle('花費');
    expect(seriesCount(), 1);
    expect(find.text('請至少開啟一條線'), findsNothing);
  });

  testWidgets('餘額為負但餘額線隱藏時，y 軸下界仍釘 0', (tester) async {
    const zeroOpening = Ledger(
      id: kLedgerId,
      name: '我們的家',
      inviteCode: 'A7K3QZ',
      defaultRatio: {kMeId: 50, kWifeId: 50},
    );
    // 只有一筆 400 支出、期初 0 → 餘額 −400
    await pumpStats(tester, entries: [seed[1]], ledgerValue: zeroOpening);

    NumericAxis yAxis() =>
        tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).primaryYAxis
            as NumericAxis;

    // 餘額線預設隱藏 → 負區間沒有任何線經過，下界不該放開
    expect(yAxis().minimum, 0);

    // 打開共同餘額線（家庭視角標籤，v1.4） → 下界放開，讓 −400 畫得出來
    await tester.tap(inTrend(find.text('共同餘額')));
    await tester.pumpAndSettle();
    expect(yAxis().minimum, isNull);

    // 再關回去 → 又釘回 0
    await tester.tap(inTrend(find.text('共同餘額')));
    await tester.pumpAndSettle();
    expect(yAxis().minimum, 0);
  });

  testWidgets('同名分類在圓餅各自成一片，不會被併掉', (tester) async {
    const dup = [
      Category(
          id: 'c-a',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          name: '食品',
          icon: 'restaurant',
          sort: 0),
      Category(
          id: 'c-b',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          name: '食品', // 與 c-a 同名
          icon: 'local_dining',
          sort: 1),
    ];
    final entries = [
      Entry(
        id: 'd-1',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 300,
        categoryId: 'c-a',
        occurredOn: day(3),
        createdBy: kMeId,
        splitMethod: SplitMethod.common,
      ),
      Entry(
        id: 'd-2',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 100,
        categoryId: 'c-b',
        occurredOn: day(4),
        createdBy: kMeId,
        splitMethod: SplitMethod.common,
      ),
    ];
    await pumpStats(tester, entries: entries, categoriesValue: dup);

    final chart = tester.widget<SfCircularChart>(find.byType(SfCircularChart));
    final series = chart.series.first as DoughnutSeries<PieSlice, String>;

    // 直接檢查 mapper 的輸出：x 值必須是 key。
    // （只斷言 dataSource 長度或圖例文字是假守衛——xValueMapper 改回 labelFor 也照樣綠。）
    final xs = [
      for (var i = 0; i < series.dataSource!.length; i++)
        series.xValueMapper!(series.dataSource![i], i),
    ];
    expect(xs, ['c-a', 'c-b'], reason: 'x 值用 key，同名分類才不會被併成一片');

    // 名稱走 dataLabelMapper，兩片都叫「食品」
    final labels = [
      for (var i = 0; i < series.dataSource!.length; i++)
        series.dataLabelMapper!(series.dataSource![i], i),
    ];
    expect(labels, ['食品', '食品']);

    // 圖例列表也是兩列同名、金額各自獨立
    expect(inPie(find.text('食品')), findsNWidgets(2));
    expect(find.text('300'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('390px 不爆版（無 overflow）＋切換列維持單排', (tester) async {
    await pumpStats(tester);
    expect(tester.takeException(), isNull);

    // 單排：四格切換擠在一列內，高度不得因換行而長高
    final toggles = find.byKey(const Key('trend-toggles'));
    expect(tester.getSize(toggles).height, lessThanOrEqualTo(48.0));
    expect(tester.getSize(toggles).height, kTrendToggleHeight);
    // spec v1.1：點擊目標 ≥ 44px
    expect(kTrendToggleHeight, greaterThanOrEqualTo(44.0));

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(toggles).height, lessThanOrEqualTo(48.0));
  });

  testWidgets('頂部列用共用 MonthAppBar，位置與帳目頁一致', (tester) async {
    await phone(tester);
    // router 現在是 per-container（routerProvider），開機一定停在 /entries。
    await tester.pumpWidget(const ProviderScope(child: AccountingApp()));
    await tester.pumpAndSettle();

    // 先確定真的站在帳目頁，再取它的月份標題與視角切換位置
    expect(find.byType(EntriesPage), findsOneWidget, reason: '必須先渲染帳目頁');
    expect(find.byType(StatsPage), findsNothing);
    expect(
      find.descendant(of: find.byType(EntriesPage), matching: find.byType(MonthAppBar)),
      findsOneWidget,
      reason: '帳目頁也用共用 MonthAppBar，才有比較基準',
    );
    final entriesTitle = tester.getRect(find.byKey(const Key('month-title')));
    final entriesToggle = tester.getRect(find.byKey(const Key('view-mode-toggle')));

    await tester.tap(find.text('統計'));
    await tester.pumpAndSettle();

    expect(find.byType(StatsPage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(StatsPage), matching: find.byType(MonthAppBar)),
      findsOneWidget,
      reason: '統計頁不自製 AppBar',
    );
    // 兩頁的標題與切換列位置必須完全重合
    expect(tester.getRect(find.byKey(const Key('month-title'))), entriesTitle);
    expect(tester.getRect(find.byKey(const Key('view-mode-toggle'))), entriesToggle);
  });

  testWidgets('趨勢 tab：總覽 ↔ 各分類，切換保留顆粒度', (tester) async {
    await pumpStats(tester);
    int seriesCount() =>
        tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).series.length;

    // 總覽：兩條（餘額預設收起）
    expect(seriesCount(), 2);
    expect(inTrend(find.text('花費')), findsOneWidget);

    // 先改顆粒度，驗證切 tab 不會被重設
    await tester.tap(inTrend(find.text('年')));
    await tester.pumpAndSettle();

    await tester.tap(inTrend(find.text('各分類')));
    await tester.pumpAndSettle();

    // 依分類：每個支出分類一條線（測試資料只有 c-food 一個支出分類）
    expect(seriesCount(), 1);
    expect(inTrend(find.text('食品')), findsOneWidget);
    expect(inTrend(find.text('花費')), findsNothing, reason: '線別切換列換成分類清單');
    expect(find.byKey(const Key('trend-category-toggles')), findsOneWidget);

    // 顆粒度保留在「年」
    expect(
      tester.widget<SegmentedButton<Granularity>>(find.byKey(const Key('trend-granularity'))).selected,
      {Granularity.year},
    );

    // 關掉唯一的分類 → 提示；再打開恢復
    await tester.tap(inTrend(find.text('食品')));
    await tester.pumpAndSettle();
    expect(seriesCount(), 0);
    expect(find.text('請至少開啟一個分類'), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);

    await tester.tap(inTrend(find.text('食品')));
    await tester.pumpAndSettle();
    expect(seriesCount(), 1);

    // 切回總覽，線別切換列回來且顆粒度仍是年
    await tester.tap(inTrend(find.text('總覽')));
    await tester.pumpAndSettle();
    expect(inTrend(find.text('花費')), findsOneWidget);
    expect(seriesCount(), 2);
    expect(
      tester.widget<SegmentedButton<Granularity>>(find.byKey(const Key('trend-granularity'))).selected,
      {Granularity.year},
    );
  });

  testWidgets('各分類：有撥款但整段沒花錢，仍算沒資料', (tester) async {
    // 分類版只畫花費線，拿別的欄位一起判會讓圖上一條平的 0 被當成「有資料」
    await pumpStats(tester, entries: const [], allocations: allocations);
    await tester.tap(inTrend(find.text('各分類')));
    await tester.pumpAndSettle();

    expect(find.text('這個範圍沒有資料'), findsOneWidget);
    expect(tester.getSize(find.byType(SfCartesianChart)).height, kTrendChartHeight);
  });

  testWidgets('分類被刪掉又加回來時，不會殘留在「已收起」狀態', (tester) async {
    const a = Category(
        id: 'k-a',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        name: '甲類',
        icon: 'restaurant',
        sort: 0);
    const b = Category(
        id: 'k-b',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        name: '乙類',
        icon: 'bolt',
        sort: 1);

    List<Bucket> buckets() => [
          for (var i = 0; i < 3; i++)
            Bucket(
              label: '$i月',
              start: DateTime(2026, i + 1, 1),
              end: DateTime(2026, i + 1, 28),
              spend: 100,
              over: 100,
              balance: 0,
            ),
        ];

    Widget harness(List<Category> cats) => MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              TrendCard(
                buckets: buckets(),
                byCategory: {for (final c in cats) c.id: buckets()},
                expenseCategories: cats,
                granularity: Granularity.month,
                onGranularityChanged: (_) {},
                viewMode: ViewMode.family,
              ),
            ]),
          ),
        );

    await phone(tester);
    await tester.pumpWidget(harness(const [a, b]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('各分類'));
    await tester.pumpAndSettle();

    int seriesCount() =>
        tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).series.length;
    expect(seriesCount(), 2);

    // 收起甲類
    await tester.tap(find.text('甲類'));
    await tester.pumpAndSettle();
    expect(seriesCount(), 1);

    // 甲類被刪除
    await tester.pumpWidget(harness(const [b]));
    await tester.pumpAndSettle();
    expect(seriesCount(), 1);

    // 甲類加回來：應該是展開的，不該記著被刪除前的「已收起」
    await tester.pumpWidget(harness(const [a, b]));
    await tester.pumpAndSettle();
    expect(seriesCount(), 2, reason: '刪掉的分類 id 不該殘留在 _hiddenCats');
  });

  testWidgets('圓餅分組與趨勢檢視的文案不撞名', (tester) async {
    await pumpStats(tester);

    // 這 6 個字是本次改名的**目標字**，不是「全頁文字都唯一」這種不變式。
    // 改名前圓餅的「依分類」「月」「週」會與趨勢 tab／顆粒度同時出現，讀者分不清是兩件事，
    // 所以只把這幾個控制字釘成唯一，避免同一組操作在兩處用同一個詞。
    //
    // 已知且刻意保留的例外（不要拿這條守衛去「修」它們）：
    //   - 「預算」：趨勢的線別 vs 底部 Tab 的頁名，跨層級，不會被誤讀成同一個控制。
    //   （月摘要卡的「餘額」與趨勢線的「共同餘額」／「個人餘額」v1.4 起是不同字面，
    //    不再有「可用餘額」這種兩處共用同一個詞的情況，見 trend_card.TrendLineX.labelFor。）
    //
    // 更重要的是：**分類名稱由使用者自訂**，完全可能取名叫「總覽」「整月」甚至「花費」，
    // 屆時這條會紅——那是資料造成的，不是程式壞了，調整測試資料即可。
    // 絕對不要把「文案唯一」寫成程式裡的不變式（例如去擋使用者命名、或改用文字當 key）。
    for (final label in ['分類', '成員', '總覽', '各分類', '整月', '單週']) {
      expect(find.text(label), findsOneWidget, reason: '「$label」應該全頁唯一');
    }
  });

  testWidgets('資訊密度：月摘要一列四格、圓餅圖例只有名稱與金額', (tester) async {
    await pumpStats(tester);

    // 月摘要四格，沒有額外說明列（balance 標籤依視角，家庭是「共同餘額」，v1.4）
    for (final l in ['收入', '支出', '損益', '共同餘額']) {
      expect(inSummary(find.text(l)), findsOneWidget);
    }
    expect(find.text('累計餘額'), findsNothing);

    // 圓餅圖例：名稱＋金額，不放百分比
    expect(inPie(find.text('食品')), findsOneWidget);
    expect(inPie(find.textContaining('%')), findsNothing);

    // 趨勢控制只有兩列（tab／顆粒度同列，切換列一列）
    expect(find.byKey(const Key('trend-tab')), findsOneWidget);
    expect(find.byKey(const Key('trend-granularity')), findsOneWidget);
    final tabRect = tester.getRect(find.byKey(const Key('trend-tab')));
    final gRect = tester.getRect(find.byKey(const Key('trend-granularity')));
    expect(tabRect.top, gRect.top, reason: 'tab 與顆粒度同列');
    expect(tabRect.right, lessThanOrEqualTo(gRect.left), reason: 'tab 在左、顆粒度在右');
  });

  testWidgets('版面：卡片不自帶樣式，一律吃 theme.cardTheme', (tester) async {
    await pumpStats(tester);
    final cards = find.byType(Card);
    expect(cards, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      final c = tester.widget<Card>(cards.at(i));
      expect(c.color, isNull, reason: '卡片不該自帶底色');
      expect(c.shape, isNull, reason: '圓角交給主題');
      expect(c.margin, isNull, reason: '卡間距交給主題');
    }
  });

  testWidgets('版面幾何：真實主題下頁面左右 16、卡間距 12', (tester) async {
    // 間距來自 theme.cardTheme.margin，必須走真實 App 才量得到（裸 MaterialApp 是預設主題）
    await phone(tester);
    await tester.pumpWidget(const ProviderScope(child: AccountingApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('統計'));
    await tester.pumpAndSettle();

    final cards = find.descendant(of: find.byType(StatsPage), matching: find.byType(Card));
    expect(cards, findsNWidgets(3));
    expect(
      Theme.of(tester.element(cards.first)).cardTheme.margin,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    );

    // 實際畫出來的卡片框
    Rect painted(int i) => tester.getRect(
          find.descendant(of: cards.at(i), matching: find.byType(Material)).first,
        );
    expect(painted(0).left, 16, reason: '頁面左留白 16');
    expect(390 - painted(0).right, 16, reason: '頁面右留白 16');
    expect(painted(1).top - painted(0).bottom, 12, reason: '卡間距 12（上下各 6）');
  });

  testWidgets('桌面寬度限寬置中、不爆版', (tester) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(),
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ListView)).width, 560);
  });

  testWidgets('深色主題渲染不炸、顏色由 colorScheme 派生', (tester) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(),
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2F6F6D),
            brightness: Brightness.dark,
          ),
        ),
        home: const StatsPage(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SfCircularChart), findsOneWidget);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    // 自製切換列一排三條線，取代原本的 FilterChip 與 Syncfusion 內建 legend
    for (final l in ['花費', '超支', '共同餘額']) {
      expect(find.descendant(of: find.byType(TrendCard), matching: find.text(l)), findsOneWidget,
          reason: '切換列應有 $l');
    }
    expect(find.byType(FilterChip), findsNothing);

    // 深色主題下切個人視角：不炸，balance 標籤跟著換成「個人餘額」（v1.4）。
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(inTrend(find.text('個人餘額')), findsOneWidget);
  });

  testWidgets('個人視角超支恆 0：TrendInput.overspendAt 不吃 totalOverspend（不靠 UI 沒畫出來就當沒事）',
      (tester) async {
    // 「超支」toggle 在個人視角本來就不畫（見下一條測試），光看畫面測不出
    // overspendAt 有沒有被錯接成 totalOverspend；直接讀 TrendCard.buckets 是
    // stats_page._mode==personal 分支「overspendAt 恆傳回 0」這條規則唯一的守衛，
    // 屬合法的 widget 層斷言（不是繞過畫面，是畫面本來就不呈現這個量）。
    // 用真的會超支的資料（預算 1000、共同支出 5000）：家庭視角這個月 over 必須 > 0，
    // 若個人視角量到同一個非 0 值，就代表 overspendAt 被錯接了。
    final overspendEntries = [
      Entry(
        id: 'ov-1',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 5000,
        categoryId: 'c-food',
        occurredOn: day(5),
        createdBy: kMeId,
        splitMethod: SplitMethod.common,
      ),
    ];
    final overspendAllocations = [
      BudgetAllocation(
        id: 'ov-al-1',
        ledgerId: kLedgerId,
        categoryId: 'c-food',
        amount: 1000,
        occurredOn: day(1),
        createdBy: kMeId,
      ),
    ];

    await pumpStats(tester, entries: overspendEntries, allocations: overspendAllocations);
    final familyOver =
        tester.widget<TrendCard>(find.byType(TrendCard)).buckets.last.over;
    expect(familyOver, greaterThan(0), reason: '固定樣本應該真的超支，這條斷言才有意義');

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();

    final personalOver =
        tester.widget<TrendCard>(find.byType(TrendCard)).buckets.last.over;
    expect(personalOver, 0,
        reason: '個人視角沒有信封，overspendAt 應恆傳回 0，不是 totalOverspend 的真實計算值');
  });

  testWidgets('線別依視角：家庭三個 toggle、個人兩個且無「超支」；切視角 _hidden 不殘留不存在的線',
      (tester) async {
    await pumpStats(tester, allocations: allocations);

    int seriesCount() =>
        tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).series.length;
    Future<void> tapToggle(String label) async {
      await tester.tap(find.descendant(of: find.byType(TrendCard), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    // 家庭：三個 toggle，預設花費／超支開、共同餘額關 → 2 條 series
    for (final l in ['花費', '超支', '共同餘額']) {
      expect(inTrend(find.text(l)), findsOneWidget);
    }
    expect(seriesCount(), 2);

    // 使用者手動收起「超支」，模擬帶著設定切視角
    await tapToggle('超支');
    expect(seriesCount(), 1);

    // 切個人：沒有「超支」toggle（個人沒有預算，v1.4），只剩花費／個人餘額兩個
    // （balance 標籤依視角變：家庭「共同餘額」、個人「個人餘額」，見 TrendLineX.labelFor）
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    expect(inTrend(find.text('超支')), findsNothing);
    expect(inTrend(find.text('花費')), findsOneWidget);
    expect(inTrend(find.text('共同餘額')), findsNothing, reason: '個人視角不該出現家庭字面');
    expect(inTrend(find.text('個人餘額')), findsOneWidget);
    expect(seriesCount(), 1, reason: '花費仍開、個人餘額仍收起（沿用切視角前的設定）');

    // 切回家庭：超支重新出現，字面換回「共同餘額」，且回到「預設可見」——不殘留切個人
    // 前手動關閉的狀態（它在個人視角期間並不存在，不該假裝「還記得」；比照分類刪除又
    // 復原的既有規則）
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    expect(inTrend(find.text('超支')), findsOneWidget);
    expect(inTrend(find.text('共同餘額')), findsOneWidget);
    expect(inTrend(find.text('個人餘額')), findsNothing, reason: '切回家庭不該殘留個人字面');
    expect(seriesCount(), 2, reason: '花費＋重新可見的超支；共同餘額仍收起');
  });

  testWidgets('真實組裝：家庭視角月摘要餘額符合 v1.4 手算基準（本月 154,800／上月 134,800）',
      (tester) async {
    await phone(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/stats');
    await tester.pumpAndSettle();

    expect(find.byType(StatsPage), findsOneWidget);
    // v1.4：sharedBalance（月底）＝154,800，預算不再預扣。
    expect(inSummary(find.text('154,800')), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(120, 0), 800);
    await tester.pumpAndSettle();
    // 上月底的共同餘額＝120,000 ＋ 52,000 − 37,200 ＝ 134,800
    expect(inSummary(find.text('134,800')), findsOneWidget);
  });

  testWidgets('真實組裝（seam）：AccountingApp 開機切個人視角，沒有「超支」toggle，月摘要餘額＝手算個人餘額',
      (tester) async {
    await phone(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/stats');
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.byKey(const Key('view-mode-toggle')), matching: find.text('個人')));
    await tester.pumpAndSettle();

    // 個人視角沒有「超支」toggle（v1.4：個人沒有預算，恆 0 不給開關）
    // personalBalance 手算：補入額 10,000 × 2 個未清帳月份（假資料加入月＝上月）＝20,000
    //   ＋ 私人收入 8,000（接案）− 私人支出 350（Steam）
    //   − 未結算代墊全額 567（全聯 e-5，payerId Mike）− 1,520（Costco e-7，payerId Mike）＝25,563
    // （期初個人餘額已廢用；與 view_math_test 的手算對照一致）
    expect(inTrend(find.text('超支')), findsNothing);
    expect(inSummary(find.text('25,563')), findsOneWidget);
  });

  testWidgets('月摘要卡：server 給定值優先於前端本地公式（sharedBalance／personalBalance）',
      (tester) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...overridesFor(),
        // server 值刻意跟本地公式手算值（家庭 5,600、個人 900，見上面兩條測試）不同，
        // 卡片顯示哪個就代表接的是哪一路——不刻意造出差異就測不出「有沒有真的吃 server」。
        monthSummaryProvider.overrideWith((ref, until) async => const domain_summary.MonthSummary(
              sharedBalance: 7500,
              budgetTotal: 0,
              spentTotal: 0,
              overspendTotal: 0,
              categories: [],
              memberId: kMeId,
              personalBalance: 8700,
              monthlyTopup: 1000,
              monthNet: 0,
            )),
      ],
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();

    expect(inSummary(find.text('7,500')), findsOneWidget);
    expect(inSummary(find.text('5,600')), findsNothing, reason: '不該是本地公式值');
    expect(inSummary(find.text('共同餘額')), findsOneWidget);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();

    expect(inSummary(find.text('8,700')), findsOneWidget);
    expect(inSummary(find.text('900')), findsNothing, reason: '不該是本地公式值');
    expect(inSummary(find.text('個人餘額')), findsOneWidget);
  });

  testWidgets('月摘要卡：server 未回應時 fallback 前端本地公式值', (tester) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      // 用一個 monthSummary 永遠不 resolve 的 repo：monthSummaryProvider(...).value
      // 恆是 null，逼卡片走 server==null 的 fallback 分支（走 `repository:` 換掉整個
      // repo，不能再疊一個 ledgerRepositoryProvider.overrideWithValue——同一個
      // provider 覆寫兩次會被 Riverpod 擋下來）。
      overrides: overridesFor(
        repository: NeverRespondingMonthSummaryRepository(
          seed: snapshotWith(
            ledger: ledger,
            members: members,
            categories: categories,
            entries: seed,
          ),
        ),
      ),
      child: const MaterialApp(home: StatsPage()),
    ));
    await tester.pumpAndSettle();

    // 家庭：sharedBalance 本地手算＝5600（同「月摘要：家庭視角數值」測試）
    expect(inSummary(find.text('5,600')), findsOneWidget);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    // 個人：personalBalance 本地手算＝900（同上）
    expect(inSummary(find.text('900')), findsOneWidget);
  });

  testWidgets('個人餘額月份語意：已清帳月個人卡讀快照 ending，看未來月出現投影小字', (tester) async {
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final close = MonthClose(
      id: 'mc-1',
      ledgerId: kLedgerId,
      month: lastMonth,
      closedBy: kMeId,
      closedAt: DateTime(lastMonth.year, lastMonth.month, 28),
      details: MonthCloseDetails(
        month: lastMonth,
        members: const [
          MonthCloseMemberLine(
              memberId: kMeId, displayName: 'Mike', topup: 1000, net: -300, ending: 700),
          MonthCloseMemberLine(
              memberId: kWifeId, displayName: '老婆', topup: 0, net: 0, ending: 0),
        ],
        sharedDelta: 0,
      ),
    );

    await pumpStats(tester, entries: const [], closes: [close]);
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('personal-balance-projection-note')), findsNothing,
        reason: '本月不是未來月');

    // 切到上月（已清帳）：個人卡讀快照 ending 700——不是即時公式／server 對已清帳月
    // 恆給的 0（isMonthClosed 讓兩者都排除該月）。
    await tester.tap(find.byKey(const Key('month-prev')));
    await tester.pumpAndSettle();
    expect(inSummary(find.text('700')), findsOneWidget);
    expect(find.byKey(const Key('personal-balance-projection-note')), findsNothing);

    // 回本月，再往後一個月（未來月）：小字出現
    await tester.tap(find.byKey(const Key('month-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('month-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('personal-balance-projection-note')), findsOneWidget);

    // 切回家庭視角（還停在未來月）：小字不該出現——投影只對「不含未來補入額」的
    // 個人餘額有意義，共同餘額沒有補入額這回事。
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('personal-balance-projection-note')), findsNothing,
        reason: '家庭視角未來月不該有投影小字');
  });

  testWidgets('個人餘額月份語意：已清帳月快照裡找不到本人 → 個人卡顯示「—」', (tester) async {
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final close = MonthClose(
      id: 'mc-2',
      ledgerId: kLedgerId,
      month: lastMonth,
      closedBy: kWifeId,
      closedAt: DateTime(lastMonth.year, lastMonth.month, 28),
      // 快照裡沒有 kMeId 這一行（資料異常／成員在清帳後才加入之類的邊界情況）。
      details: MonthCloseDetails(
        month: lastMonth,
        members: const [
          MonthCloseMemberLine(memberId: kWifeId, displayName: '老婆', topup: 0, net: 0, ending: 0),
        ],
        sharedDelta: 0,
      ),
    );

    await pumpStats(tester, entries: const [], closes: [close]);
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('month-prev')));
    await tester.pumpAndSettle();

    // balance 格顯示「—」，不假裝有一個算得出來的數字（不是 0——0 是一個真的算出來的
    // 值，「—」是「這個問題在已清帳月份沒有答案」）。
    expect(inSummary(find.text('—')), findsOneWidget);
  });

  testWidgets('個人餘額月份語意：前史月份（≤ 最後清帳月但這個月本身沒有列）個人卡顯示 0，不是「—」',
      (tester) async {
    // closes 只有上月一筆；再往前一個月（更早於任何清帳列）沒有自己的列，但因為
    // isMonthClosed 是級聯定義（≤ 最後清帳月），即時公式仍然會判定它「已清帳」而
    // 把 N 與淨變動都算成 0——這才是正確答案：那個月根本沒發生過清帳，個人餘額
    // 本來就是 0，不是「有列找不到本人」的「—」。
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final preHistoryMonth = DateTime(now.year, now.month - 2, 1);
    final close = MonthClose(
      id: 'mc-6',
      ledgerId: kLedgerId,
      month: lastMonth,
      closedBy: kMeId,
      closedAt: DateTime(lastMonth.year, lastMonth.month, 28),
      details: MonthCloseDetails(
        month: lastMonth,
        members: const [
          MonthCloseMemberLine(
              memberId: kMeId, displayName: 'Mike', topup: 1000, net: 0, ending: 1000),
          MonthCloseMemberLine(memberId: kWifeId, displayName: '老婆', topup: 0, net: 0, ending: 0),
        ],
        sharedDelta: 0,
      ),
    );
    // 收支各給一筆非 0 值：income／expense／net 都不是 0，這樣「balance 顯示 0」
    // 才是頁面上唯一一個 0，斷言才不會因為別格也剛好是 0 而假陽性。
    final preHistoryEntries = [
      Entry(
        id: 'ph-1',
        ledgerId: kLedgerId,
        kind: EntryKind.income,
        scope: EntryScope.private,
        amount: 500,
        categoryId: 'c-salary',
        occurredOn: DateTime(preHistoryMonth.year, preHistoryMonth.month, 5),
        createdBy: kMeId,
      ),
      Entry(
        id: 'ph-2',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.private,
        amount: 200,
        categoryId: 'c-food',
        occurredOn: DateTime(preHistoryMonth.year, preHistoryMonth.month, 6),
        createdBy: kMeId,
        payerId: kMeId,
      ),
    ];

    await pumpStats(tester, entries: preHistoryEntries, closes: [close]);
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('month-prev')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('month-prev')));
    await tester.pumpAndSettle();

    expect(inSummary(find.text('500')), findsOneWidget, reason: '收入 500（前史月份的私人收入）');
    expect(inSummary(find.text('200')), findsOneWidget, reason: '支出 200（前史月份的私人支出）');
    expect(inSummary(find.text('300')), findsOneWidget, reason: '損益 500−200');
    expect(inSummary(find.text('0')), findsOneWidget, reason: 'balance 格＝0（前史月份，不是「—」）');
    expect(inSummary(find.text('—')), findsNothing);
  });

  testWidgets(
      '個人趨勢餘額線：closes 含上月 → 上月桶末值讀快照 ending、本月桶末值扣掉整個已清帳的上月',
      (tester) async {
    // 注意：這條測試刻意只 pump 一次——flutter_riverpod 的 ProviderScope 在同一顆
    // widget tree 上重複 pumpWidget 時，State.didUpdateWidget 會重用既有
    // ProviderContainer 並呼叫 updateOverrides（而非整個重建），對 NotifierProvider
    // 覆寫（如 monthClosesProvider）不保證重跑 build()；驗「清帳前後」這種對比
    // 要嘛拆兩條各自獨立 pump 的測試，要嘛像這裡一樣把「清帳前應該是多少」寫死在
    // 註解裡當手算依據，只驗清帳後那個唯一畫面。
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    // 加入月＝上月：上月是 N=1 的邊界情況，該月自己的 topup+net 剛好等於累計到
    // 該月為止的 personalBalance，快照 ending 才能跟「假設清帳前的桶末值」對得上號
    // （清帳明細的 ending 定義是「該月自己的 topup+net」，見
    // InMemoryLedgerRepository._closeDetails，不是累計值）。
    final joinLastMonthMembers = [
      Member(
          id: kMeId,
          ledgerId: kLedgerId,
          userId: 'u1',
          displayName: 'Mike',
          monthlyTopup: 1000,
          joinedAt: lastMonth),
      Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: lastMonth),
    ];
    final closeEntries = [
      Entry(
        id: 'ce-1',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.private,
        amount: 300,
        categoryId: 'c-food',
        occurredOn: DateTime(lastMonth.year, lastMonth.month, 10),
        createdBy: kMeId,
        payerId: kMeId,
      ),
      Entry(
        id: 'ce-2',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.private,
        amount: 150,
        categoryId: 'c-food',
        occurredOn: day(10),
        createdBy: kMeId,
        payerId: kMeId,
      ),
    ];
    // 假設清帳前（closes=[]）：V(上月)＝補入額 1000 − 私人支出 300＝700；
    // V(本月)＝補入額 1000×2 − 300 − 150＝1550（與 trend_math_test.dart／
    // view_math_test.dart 同一套 personalBalance 手算法，這裡不重新 pump 驗證，
    // 只當作下面「清帳後」斷言的算式依據）。
    final close = MonthClose(
      id: 'mc-1',
      ledgerId: kLedgerId,
      month: lastMonth,
      closedBy: kMeId,
      closedAt: DateTime(lastMonth.year, lastMonth.month, 28),
      details: MonthCloseDetails(
        month: lastMonth,
        members: const [
          MonthCloseMemberLine(
              memberId: kMeId, displayName: 'Mike', topup: 1000, net: -300, ending: 700),
          MonthCloseMemberLine(
              memberId: kWifeId, displayName: '老婆', topup: 0, net: 0, ending: 0),
        ],
        sharedDelta: 0,
      ),
    );

    await pumpStats(tester,
        entries: closeEntries, membersValue: joinLastMonthMembers, closes: [close]);
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    final buckets = tester.widget<TrendCard>(find.byType(TrendCard)).buckets;

    // 上月已清帳：即時公式會把該月整個排除（回 0），這裡驗的正是「桶末值改讀快照」
    // 而不是巧合對到 0——快照 ending 700 與「假設清帳前」的桶末值 700 相等
    // （N=1 的邊界情況：該月自己的 topup+net 就是累計到該月為止的全部）。
    expect(buckets[buckets.length - 2].balance, 700,
        reason: '上月桶末值＝快照 ending，不是即時公式排除該月後的 0');
    // 本月：即時公式扣掉整個已清帳的上月（topup 1000＋net −300）＝1550 − 700＝850
    expect(buckets.last.balance, 850, reason: '本月桶末值＝假設清帳前 1550 − (topup 1000＋上月 net −300)');
  });

  testWidgets('個人趨勢餘額線：非月顆粒度落在已清帳月的桶不畫點（線斷開），家庭線不受影響',
      (tester) async {
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final joinLastMonthMembers = [
      Member(
          id: kMeId,
          ledgerId: kLedgerId,
          userId: 'u1',
          displayName: 'Mike',
          monthlyTopup: 1000,
          joinedAt: lastMonth),
      Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: lastMonth),
    ];
    final close = MonthClose(
      id: 'mc-4',
      ledgerId: kLedgerId,
      month: lastMonth,
      closedBy: kMeId,
      closedAt: DateTime(lastMonth.year, lastMonth.month, 28),
      details: MonthCloseDetails(
        month: lastMonth,
        members: const [
          MonthCloseMemberLine(
              memberId: kMeId, displayName: 'Mike', topup: 1000, net: -300, ending: 700),
          MonthCloseMemberLine(
              memberId: kWifeId, displayName: '老婆', topup: 0, net: 0, ending: 0),
        ],
        sharedDelta: 0,
      ),
    );

    await pumpStats(tester, entries: const [], membersValue: joinLastMonthMembers, closes: [close]);
    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();
    await tester.tap(inTrend(find.text('週')));
    await tester.pumpAndSettle();

    final weekBuckets = tester.widget<TrendCard>(find.byType(TrendCard)).buckets;
    final lastMonthWeeks = weekBuckets
        .where((b) => b.end.year == lastMonth.year && b.end.month == lastMonth.month)
        .toList();
    expect(lastMonthWeeks, isNotEmpty, reason: '固定樣本應該真的有整週落在上月，這條斷言才有意義');
    for (final b in lastMonthWeeks) {
      expect(b.balance, isNull, reason: '週顆粒度落在已清帳月的桶不畫個人餘額點');
    }
    final thisMonthWeeks =
        weekBuckets.where((b) => b.end.year == now.year && b.end.month == now.month).toList();
    expect(thisMonthWeeks, isNotEmpty);
    for (final b in thisMonthWeeks) {
      expect(b.balance, isNotNull, reason: '本月未清帳，週顆粒度照樣有值');
    }

    // 切回月顆粒度：上月桶末值改讀快照 700，不是 null
    await tester.tap(inTrend(find.text('月')));
    await tester.pumpAndSettle();
    final monthBuckets = tester.widget<TrendCard>(find.byType(TrendCard)).buckets;
    expect(monthBuckets[monthBuckets.length - 2].balance, 700);

    // 家庭視角：同一個已清帳月，週顆粒度不受影響，恆有值（共同餘額不吃 closes）
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    await tester.tap(inTrend(find.text('週')));
    await tester.pumpAndSettle();
    final familyWeekBuckets = tester.widget<TrendCard>(find.byType(TrendCard)).buckets;
    final familyLastMonthWeeks = familyWeekBuckets
        .where((b) => b.end.year == lastMonth.year && b.end.month == lastMonth.month)
        .toList();
    expect(familyLastMonthWeeks, isNotEmpty);
    for (final b in familyLastMonthWeeks) {
      expect(b.balance, isNotNull, reason: '家庭線（共同餘額）不受清帳影響，恆有值');
    }
  });
}
