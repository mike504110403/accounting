import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
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

/// 注意：`router`（`lib/app/router.dart`）是 top-level 單例，**跨測試共用**。
/// 任何用 `AccountingApp` 開機的測試都會沿用上一條測試留下的路由位置，
/// 所以需要特定分頁時一律先 `router.go(...)`，不要假設開機在 `/entries`。
class _FixedEntries extends EntriesNotifier {
  _FixedEntries(this.seed);
  final List<Entry> seed;
  @override
  List<Entry> build() => seed;
}

class _FixedBudgets extends BudgetsNotifier {
  _FixedBudgets(this.seed);
  final List<Budget> seed;
  @override
  List<Budget> build() => seed;
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
  const members = [
    Member(
        id: kMeId,
        ledgerId: kLedgerId,
        userId: 'u1',
        displayName: 'Mike',
        openingBalancePersonal: 1000),
    Member(
        id: kWifeId,
        ledgerId: kLedgerId,
        userId: 'u2',
        displayName: '老婆',
        openingBalancePersonal: 0),
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

  // 回傳型別交給推論：flutter_riverpod 3 沒有匯出 `Override` 這個型別名。
  overridesFor({
    List<Entry>? entries,
    List<Budget>? budgets,
    Ledger? ledgerValue,
    List<Category>? categoriesValue,
  }) => [
        ledgerProvider.overrideWithValue(ledgerValue ?? ledger),
        membersProvider.overrideWithValue(members),
        categoriesProvider.overrideWithValue(categoriesValue ?? categories),
        entriesProvider.overrideWith(() => _FixedEntries(entries ?? seed)),
        budgetsProvider.overrideWith(() => _FixedBudgets(budgets ?? const [])),
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
    List<Budget>? budgets,
    Ledger? ledgerValue,
    List<Category>? categoriesValue,
  }) async {
    await phone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: overridesFor(
        entries: entries,
        budgets: budgets,
        ledgerValue: ledgerValue,
        categoriesValue: categoriesValue,
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
    expect(inSummary(find.text('餘額')), findsOneWidget);
    expect(find.text('支出分布'), findsOneWidget);
    expect(find.text('趨勢'), findsOneWidget);
    expect(find.text('家庭'), findsOneWidget);
    expect(find.byType(SfCircularChart), findsOneWidget);
    expect(find.byType(SfCartesianChart), findsOneWidget);
    // 自製切換列一排四條線，取代原本的 FilterChip 與 Syncfusion 內建 legend
    // （限定在 TrendCard 內找：'預算' 同時也是底部 Tab 的名稱）
    for (final l in ['花費', '預算', '超支', '餘額']) {
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
    await tester.tap(find.descendant(of: toggle, matching: find.text('個人')));
    await tester.pumpAndSettle();
    expect(inSummary(find.text('1,200')), findsOneWidget);
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

    // 家庭：收入 1000、支出 400（私人 100 不算）、損益 600、餘額 5000+600
    expect(inSummary(find.text('1,000')), findsOneWidget);
    expect(inSummary(find.text('400')), findsOneWidget);
    expect(inSummary(find.text('600')), findsOneWidget);
    expect(inSummary(find.text('5,600')), findsOneWidget);

    await tester.tap(find.text('個人'));
    await tester.pumpAndSettle();

    // 個人：收入 500、支出 200+100=300、損益 200、餘額 1000+200
    expect(inSummary(find.text('500')), findsOneWidget);
    expect(inSummary(find.text('300')), findsOneWidget);
    expect(inSummary(find.text('200')), findsOneWidget);
    expect(inSummary(find.text('1,200')), findsOneWidget);
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

    // 點切換列的「餘額」打開該線，圖仍正常
    await tester.tap(inTrend(find.text('餘額')));
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

  testWidgets('趨勢：四種顆粒度都畫得出來、四條線可開關', (tester) async {
    final budgets = [
      Budget(id: 'b', ledgerId: kLedgerId, categoryId: 'c-food', month: thisMonth, limit: 3000),
    ];
    await pumpStats(tester, budgets: budgets);

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
    final budgets = [
      Budget(id: 'b', ledgerId: kLedgerId, categoryId: 'c-food', month: thisMonth, limit: 3000),
    ];
    await pumpStats(tester, budgets: budgets);

    int seriesCount() =>
        tester.widget<SfCartesianChart>(find.byType(SfCartesianChart)).series.length;
    Future<void> toggle(String label) async {
      await tester.tap(find.descendant(of: find.byType(TrendCard), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    // 餘額預設收起 → 三條
    expect(seriesCount(), 3);
    expect(find.text('請至少開啟一條線'), findsNothing);

    // 打開餘額 → 四條
    await toggle('餘額');
    expect(seriesCount(), 4);

    // 逐條關掉，series 跟著減少
    await toggle('餘額');
    expect(seriesCount(), 3);
    await toggle('超支');
    expect(seriesCount(), 2);
    await toggle('預算');
    expect(seriesCount(), 1);

    // 四條全關 → series 空、提示出現、圖區高度不變
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

    // 打開餘額線 → 下界放開，讓 −400 畫得出來
    await tester.tap(inTrend(find.text('餘額')));
    await tester.pumpAndSettle();
    expect(yAxis().minimum, isNull);

    // 再關回去 → 又釘回 0
    await tester.tap(inTrend(find.text('餘額')));
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
    // router 是 top-level 單例，會帶著前一條測試留下的位置。不能假設開機在 /entries，
    // 否則「帳目頁的 rect」量到的其實是統計頁自己，比對就變成恆真的假守衛。
    router.go('/entries');
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

    // 總覽：三條（餘額預設收起）
    expect(seriesCount(), 3);
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
    expect(seriesCount(), 3);
    expect(
      tester.widget<SegmentedButton<Granularity>>(find.byKey(const Key('trend-granularity'))).selected,
      {Granularity.year},
    );
  });

  testWidgets('各分類：有預算但整段沒花錢，仍算沒資料', (tester) async {
    // 分類版只畫花費線，拿 budget 一起判會讓圖上一條平的 0 被當成「有資料」
    final budgets = [
      Budget(id: 'b', ledgerId: kLedgerId, categoryId: 'c-food', month: thisMonth, limit: 3000),
    ];
    await pumpStats(tester, entries: const [], budgets: budgets);
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
              budget: 0,
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
    //   - 「餘額」：月摘要的一格 vs 趨勢的線別，兩者確實是同一個量、不同呈現。
    //   - 「預算」：趨勢的線別 vs 底部 Tab 的頁名，跨層級，不會被誤讀成同一個控制。
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

    // 月摘要四格，沒有額外說明列
    for (final l in ['收入', '支出', '損益', '餘額']) {
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
    // 自製切換列一排四條線，取代原本的 FilterChip 與 Syncfusion 內建 legend
    // （限定在 TrendCard 內找：'預算' 同時也是底部 Tab 的名稱）
    for (final l in ['花費', '預算', '超支', '餘額']) {
      expect(find.descendant(of: find.byType(TrendCard), matching: find.text(l)), findsOneWidget,
          reason: '切換列應有 $l');
    }
    expect(find.byType(FilterChip), findsNothing);
  });
}
