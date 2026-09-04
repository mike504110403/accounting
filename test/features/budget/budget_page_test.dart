import 'package:accounting/app/format.dart';
import 'package:accounting/app/router.dart';
import 'package:accounting/app/theme.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/budget/budget_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

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

/// add 一律丟通用例外（非 [LedgerException]）：驗「儲存失敗，請重試」那條 fallback 訊息、
/// loading 解除、sheet 不 pop。
class _ThrowingAllocations extends AllocationsNotifier {
  _ThrowingAllocations(this.seed);
  final List<BudgetAllocation> seed;
  @override
  List<BudgetAllocation> build() => seed;
  @override
  Future<BudgetAllocation> add(BudgetAllocation a) => throw Exception('boom');
}

/// 前 [okCount] 次 add 成功、之後失敗：驗「複製上月」批次寫到一半爆掉。
class _PartlyFailingAllocations extends AllocationsNotifier {
  _PartlyFailingAllocations(this.seed, this.okCount);
  final List<BudgetAllocation> seed;
  final int okCount;
  int _n = 0;

  @override
  List<BudgetAllocation> build() => seed;

  @override
  Future<BudgetAllocation> add(BudgetAllocation a) {
    if (_n++ >= okCount) throw const LedgerException('寫入被拒絕');
    return super.add(a);
  }
}

void main() {
  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month, 1);
  final prevMonth = DateTime(now.year, now.month - 1, 1);
  final nextMonth = DateTime(now.year, now.month + 1, 1);
  DateTime day(int d) => DateTime(now.year, now.month, d);
  DateTime pday(int d) => DateTime(prevMonth.year, prevMonth.month, d);

  const cats3 = [
    Category(id: 'c-food', ledgerId: kLedgerId, kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0),
    Category(id: 'c-dining', ledgerId: kLedgerId, kind: EntryKind.expense, name: '餐飲', icon: 'local_dining', sort: 1),
    Category(id: 'c-util', ledgerId: kLedgerId, kind: EntryKind.expense, name: '水電', icon: 'bolt', sort: 2),
  ];

  const cats5 = [
    Category(id: 'c-food', ledgerId: kLedgerId, kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0),
    Category(id: 'c-dining', ledgerId: kLedgerId, kind: EntryKind.expense, name: '餐飲', icon: 'local_dining', sort: 1),
    Category(id: 'c-daily', ledgerId: kLedgerId, kind: EntryKind.expense, name: '日常用品', icon: 'inventory_2', sort: 2),
    Category(id: 'c-util', ledgerId: kLedgerId, kind: EntryKind.expense, name: '水電', icon: 'bolt', sort: 3),
    Category(id: 'c-transport', ledgerId: kLedgerId, kind: EntryKind.expense, name: '交通', icon: 'directions_car', sort: 4),
  ];

  const ledger10k = Ledger(id: kLedgerId, name: '測試帳本', inviteCode: 'ABC123', defaultRatio: {kMeId: 100}, openingBalanceShared: 10000);
  const ledger7500 = Ledger(id: kLedgerId, name: '測試帳本', inviteCode: 'ABC123', defaultRatio: {kMeId: 100}, openingBalanceShared: 7500);

  MonthClose closeOf(DateTime month) => MonthClose(
        id: 'mc-${month.year}-${month.month}',
        ledgerId: kLedgerId,
        month: month,
        closedBy: kMeId,
        closedAt: month,
        details: MonthCloseDetails(month: month, members: const [], sharedDelta: 0),
      );

  // 回傳型別交給推論：flutter_riverpod 3 沒有匯出 `Override` 這個型別名（同 stats_page_test.dart 慣例）。
  overridesFor({
    List<Category> categories = cats3,
    List<Entry> entries = const [],
    List<BudgetAllocation> allocations = const [],
    Ledger ledger = ledger10k,
    bool throwing = false,
    AllocationsNotifier Function()? allocationsNotifier,
    InMemoryLedgerRepository? repository,
  }) => [
        categoriesProvider.overrideWithValue(categories),
        ledgerProvider.overrideWithValue(ledger),
        entriesProvider.overrideWith(() => _FixedEntries(entries)),
        allocationsProvider.overrideWith(allocationsNotifier ??
            () => throwing ? _ThrowingAllocations(allocations) : _FixedAllocations(allocations)),
        // month_summary（衍生數字改吃 DB）：InMemory repo 餵同一份 fixture，
        // 讓 monthSummaryProvider 算出與畫面 fixture 一致的 server 值。
        ledgerRepositoryProvider.overrideWithValue(
          repository ?? repoWith(ledger: ledger, categories: categories, entries: entries, allocations: allocations),
        ),
      ];

  Future<ProviderContainer> pumpBudget(
    WidgetTester tester, {
    List<Category> categories = cats3,
    List<Entry> entries = const [],
    List<BudgetAllocation> allocations = const [],
    Ledger ledger = ledger10k,
    ThemeData? theme,
    bool throwing = false,
    AllocationsNotifier Function()? allocationsNotifier,
    InMemoryLedgerRepository? repository,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: overridesFor(
        categories: categories,
        entries: entries,
        allocations: allocations,
        ledger: ledger,
        throwing: throwing,
        allocationsNotifier: allocationsNotifier,
        repository: repository,
      ),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: theme, home: const BudgetPage()),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Finder inRow(String categoryId, Finder f) => find.descendant(of: find.byKey(ValueKey('category-row-$categoryId')), matching: f);

  testWidgets('真實組裝：AccountingApp 根啟動點「預算」tab → 點住房列（seed 本月未設定）→ 設定金額 → 存 → 列顯示金額且再點開沒有輸入欄', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();

    container.read(routerProvider).go('/budget');
    await tester.pumpAndSettle();

    // v1.4 手算：本月預算合計＝6,000＋4,000＋1,500＋3,000＋2,000＝16,500
    //（食品／餐飲／日常用品／水電／交通五個分類都有預算，住房與娛樂沒有）。
    expect(find.text(fmtMoney(16500)), findsOneWidget, reason: '本月預算合計（頂部四格）');

    // 住房在波 1 假資料裡本月已有共同支出（房租 26,000）但從沒設過預算：
    // allocated==0 && spent>0，顯示「未設定」＋已花／超支兩數字（不是真空的 noActivity），
    // 沒設過預算就仍是可編輯表單（過去有花費不代表本月已設定）。
    expect(inRow('c-house', find.text('未設定')), findsOneWidget);
    expect(inRow('c-house', find.text('超支')), findsOneWidget);

    await tester.tap(find.text('住房').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '30000');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsNothing, reason: 'sheet 應已關閉');
    expect(inRow('c-house', find.text(fmtAmount(30000))), findsOneWidget, reason: '列上顯示剛設定的預算');

    await tester.tap(find.text('住房').first);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '已設定，不該再有輸入欄');
    expect(find.text(fmtAmount(30000)), findsWidgets, reason: '唯讀明細顯示金額');
  });

  testWidgets('真實組裝：切上月數字回歸（seed 手算基準）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();

    container.read(routerProvider).go('/budget');
    await tester.pumpAndSettle();

    // 整合回歸：切到上月，食品預算 5,500／已花 6,200 → 超支 700（紅字），共同餘額 134,800。
    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    expect(inRow('c-food', find.text(fmtAmount(700))), findsOneWidget, reason: '上月食品超支 700');
    final overText = tester.widget<Text>(inRow('c-food', find.text(fmtAmount(700))));
    expect(overText.style?.color, Theme.of(tester.element(find.byType(BudgetPage))).colorScheme.error);
    expect(find.text(fmtMoney(134800)), findsOneWidget, reason: '上月底的共同餘額');
  });

  testWidgets('頂部四格文字與數字：共同餘額／本月預算／本月共同支出／本月超支', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 4000, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, payerId: kMeId, splitMethod: SplitMethod.equal),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1500, categoryId: 'c-dining', occurredOn: day(12), createdBy: kMeId, payerId: kMeId, splitMethod: SplitMethod.equal),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 6000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, entries: entries, allocations: allocations, ledger: ledger7500);

    expect(find.text('共同餘額'), findsOneWidget);
    expect(find.text(fmtMoney(7500)), findsOneWidget, reason: '共同錢包沒動（兩筆都是代墊 payerId=kMeId）');
    expect(find.text('本月預算'), findsOneWidget);
    expect(find.text(fmtMoney(6000)), findsOneWidget);
    expect(find.text('本月共同支出'), findsOneWidget);
    expect(find.text(fmtMoney(5500)), findsOneWidget, reason: '4,000 + 1,500，不分 payer');
    expect(find.text('本月超支'), findsOneWidget);
    expect(find.text(fmtMoney(1500)), findsOneWidget, reason: '食品不超支；餐飲無預算，1,500 全記超支');
  });

  testWidgets('全無預算無共同支出時本月超支顯示「—」不上紅', (tester) async {
    await pumpBudget(tester);

    // 限定在「本月超支」那一格找（_stat 的 Column：label 在上、值在下，同一個 Column
    // 底下才是同一格），不是隨便哪裡出現一個「—」都算數。
    final overStat = find.ancestor(of: find.text('本月超支'), matching: find.byType(Column)).first;
    final dash = find.descendant(of: overStat, matching: find.text('—'));
    expect(dash, findsOneWidget);
    // 不能斷言 `style?.color` 為 null：`_stat` 用 `titleMedium?.copyWith(color: color)`，
    // `color` 傳 null 時 `copyWith` 語意是「不覆蓋」而非「清成 null」，resolve 出來的
    // color 恆是 titleMedium 本來的顏色（近黑），不會是字面 null——用「不等於 error 色」
    // 才是這裡真正要守的事（不上紅），照同檔 c-dining 紅字那條的驗證方向。
    final scheme = Theme.of(tester.element(find.byType(BudgetPage))).colorScheme;
    expect(tester.widget<Text>(dash).style?.color, isNot(scheme.error), reason: '0 時不上紅');
  });

  testWidgets('分類列文案：已設定顯示「預算／已花／剩餘」，超支顯示「超支」，未設定顯示「未設定」且不畫三數字', (tester) async {
    // 食品：預算 5,000、共同支出 3,000 → 剩餘 2,000。
    // 餐飲：預算 1,000、共同支出 1,500 → 超支 500（那格換顯示紅字「超支」，「剩餘」不出現）。
    // 水電：無預算無共同支出 → 未設定。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 3000, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, splitMethod: SplitMethod.common),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1500, categoryId: 'c-dining', occurredOn: day(12), createdBy: kMeId, splitMethod: SplitMethod.common),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    expect(inRow('c-food', find.text('預算')), findsOneWidget);
    expect(inRow('c-food', find.text(fmtAmount(5000))), findsOneWidget);
    expect(inRow('c-food', find.text('已花')), findsOneWidget);
    expect(inRow('c-food', find.text(fmtAmount(3000))), findsOneWidget);
    expect(inRow('c-food', find.text('剩餘')), findsOneWidget);
    expect(inRow('c-food', find.text(fmtAmount(2000))), findsOneWidget);
    expect(inRow('c-food', find.text('超支')), findsNothing);

    expect(inRow('c-dining', find.text('超支')), findsOneWidget);
    expect(inRow('c-dining', find.text(fmtAmount(500))), findsOneWidget);
    expect(inRow('c-dining', find.text('剩餘')), findsNothing);
    final overText = tester.widget<Text>(inRow('c-dining', find.text(fmtAmount(500))));
    expect(overText.style?.color, Theme.of(tester.element(find.byType(BudgetPage))).colorScheme.error);

    expect(inRow('c-util', find.text('未設定')), findsOneWidget);
    expect(inRow('c-util', find.text('預算')), findsNothing, reason: '未設定不畫三數字標籤');
  });

  testWidgets('無預算但有共同支出的分類：列顯示「未設定」＋已花與超支兩數字，且頂部超支含它', (tester) async {
    // 水電從沒設過預算，但本月已有共同支出 8,000（allocated==0 && spent>0）：
    // 不是真空的 noActivity（allocated0 && spent0），不可藏成「未設定」四字了事，
    // 要把已花與超支都攤出來——它照樣計入頂部本月超支。
    // 食品另設預算 5,000、花 3,000（沒超支），純粹讓頂部「本月共同支出」（11,000）
    // 與「本月超支」（8,000，只來自水電）數字不同，斷言才不會撞號。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 8000, categoryId: 'c-util', occurredOn: day(5), createdBy: kMeId, splitMethod: SplitMethod.common),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 3000, categoryId: 'c-food', occurredOn: day(6), createdBy: kMeId, splitMethod: SplitMethod.common),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    expect(inRow('c-util', find.text('未設定')), findsOneWidget);
    expect(inRow('c-util', find.text('已花')), findsOneWidget);
    expect(inRow('c-util', find.text('超支')), findsOneWidget);
    expect(inRow('c-util', find.text(fmtAmount(8000))), findsWidgets, reason: '已花與超支都是 8,000（allocated=0）');

    expect(find.text('本月共同支出'), findsOneWidget);
    expect(find.text(fmtMoney(11000)), findsOneWidget, reason: '8,000（水電）＋3,000（食品）');
    expect(find.text('本月超支'), findsOneWidget);
    expect(find.text(fmtMoney(8000)), findsOneWidget, reason: '頂部本月超支只來自水電（食品有預算沒超支）');
  });

  testWidgets('無預算、當月淨額被沖銷成負數的分類：列顯示「未設定」＋已花負數，不畫「超支」', (tester) async {
    // 水電從沒設過預算；當月唯一一筆是沖銷筆（負 26,000，模擬「原筆在別的統計範圍、
    // 這裡只看得到反向那筆淨額」的邊界情況）：allocated=0、spent=-26,000、over 被
    // balance_math 夾在 0。已花是「所有共同支出」的事實，負數也不能藏；超支沒有意義
    // （over<=0）就不該再畫一行「超支 0」。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: -26000, categoryId: 'c-util', occurredOn: day(5), createdBy: kMeId, splitMethod: SplitMethod.common, isAdjustment: true),
    ];
    await pumpBudget(tester, entries: entries);

    expect(inRow('c-util', find.text('未設定')), findsOneWidget);
    expect(inRow('c-util', find.text('已花')), findsOneWidget);
    expect(inRow('c-util', find.text(fmtAmount(-26000))), findsOneWidget, reason: '已花 -26,000 不可藏');
    expect(inRow('c-util', find.text('超支')), findsNothing, reason: 'over 被夾在 0，不畫超支那組');
  });

  testWidgets('水位比例＝剩餘／預算；超支時滿條錯誤色', (tester) async {
    // 食品：預算 4,000、已花 1,000 → 剩餘 3,000、水位 0.75、不紅。
    // 餐飲：預算 1,000、已花 1,500 → 超支、滿條 errorContainer。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1000, categoryId: 'c-food', occurredOn: day(5), createdBy: kMeId, splitMethod: SplitMethod.common),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1500, categoryId: 'c-dining', occurredOn: day(6), createdBy: kMeId, splitMethod: SplitMethod.common),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 4000, occurredOn: day(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, entries: entries, allocations: allocations);
    final scheme = Theme.of(tester.element(find.byType(BudgetPage))).colorScheme;

    // pumpBudget 已 pumpAndSettle，水位補間動畫（0 → 目標）跑完才量 widthFactor。
    FractionallySizedBox fillOf(String id) => tester.widget<FractionallySizedBox>(find.ancestor(
        of: find.byKey(ValueKey('water-fill-$id')), matching: find.byType(FractionallySizedBox)));
    ColoredBox boxOf(String id) => tester.widget<ColoredBox>(find.byKey(ValueKey('water-fill-$id')));

    expect(fillOf('c-food').widthFactor, closeTo(0.75, 0.0001));
    expect(boxOf('c-food').color, scheme.primaryContainer);

    expect(fillOf('c-dining').widthFactor, closeTo(1.0, 0.0001));
    expect(boxOf('c-dining').color, scheme.errorContainer);
  });

  testWidgets('本月未設定：sheet 有金額欄、備註欄與「設定」鈕，抬頭吃當月月份字串', (tester) async {
    await pumpBudget(tester);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget);
    expect(find.byKey(const Key('allocation-note-field')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '設定'), findsOneWidget);
    // 抬頭「N已花」的 N 吃 widget.month（同 AppBar 的 MonthTitle 那份資料），
    // 不是寫死的「本月」；這裡看的是當月，字串應該是 fmtMonth(thisMonth)。
    expect(find.textContaining('${fmtMonth(thisMonth)}已花'), findsOneWidget);
  });

  testWidgets('金額空白或 0：sheet 內顯示錯誤且不送出', (tester) async {
    await pumpBudget(tester);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();
    expect(find.text('請輸入金額'), findsOneWidget);
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');

    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '0');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();
    expect(find.text('請輸入金額'), findsOneWidget);
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');
  });

  testWidgets('設定成功（看本月）：allocationsProvider 多一筆，occurredOn＝今天', (tester) async {
    final container = await pumpBudget(tester);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '1000');
    await tester.enterText(find.byKey(const Key('allocation-note-field')), '加碼');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsNothing, reason: 'sheet 該關閉');
    final added = container.read(allocationsProvider).last;
    expect(added.amount, 1000);
    expect(added.categoryId, 'c-util');
    expect(added.note, '加碼');
    expect(added.createdBy, kMeId);
    expect(added.occurredOn, DateTime(now.year, now.month, now.day));
  });

  testWidgets('設定成功（看未來月）：occurredOn＝該月 1 號', (tester) async {
    final container = await pumpBudget(tester);

    await tester.tap(find.byKey(const Key('month-next')));
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(nextMonth)), findsOneWidget);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '800');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    final added = container.read(allocationsProvider).last;
    expect(added.occurredOn, DateTime(nextMonth.year, nextMonth.month, 1));
  });

  testWidgets('設定儲存失敗：sheet 仍開著、sheet 內顯示錯誤文字', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 2000, occurredOn: day(1), createdBy: kMeId)];
    // 食品本月已設定會走唯讀分支（沒有輸入欄可測失敗路徑），挑一個本月還沒設定的分類（餐飲）。
    await pumpBudget(tester, allocations: allocations, throwing: true);

    await tester.tap(find.text('餐飲').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '1234');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 仍開著');
    expect(find.text('儲存失敗，請重試'), findsOneWidget, reason: 'sheet 內顯示錯誤文字');
    expect(find.text('處理中…'), findsNothing, reason: '_saving 要解除，不能卡住');
    final btn = tester.widget<FilledButton>(find.byKey(const Key('allocation-add-btn')));
    expect(btn.onPressed, isNotNull, reason: '失敗後應可重試');
  });

  testWidgets('unique 23505（前端快取還沒同步、伺服器早有這筆）：sheet 內顯示含「本月已設定」', (tester) async {
    // 模擬競態：allocationsProvider 的本地快取是空的（sheet 因此判斷未設定、放行編輯表單），
    // 但底層 repository 的快照其實已經有這個分類這個月的預算——送出時撞上 DB 的
    // unique (ledger_id, category_id, month)，InMemory 守衛丟同一句中文。
    final existing = BudgetAllocation(id: 'a-server', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId);
    final repo = InMemoryLedgerRepository(
      seed: snapshotWith(categories: cats3, entries: const [], allocations: [existing]),
    );
    await pumpBudget(tester, repository: repo);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: '前端快取沒看到那筆，仍顯示可編輯表單');

    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '3000');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 仍開著，不 pop');
    expect(find.textContaining('本月已設定'), findsOneWidget);
  });

  testWidgets('已清帳月（資料異常防線）：sheet 內顯示含「已清帳」', (tester) async {
    // 正常路徑下 _isPastMonth 就會擋過去月份；這裡刻意讓「已清帳的月份」與「檢視月＝當月」
    // 同時成立（資料異常／補記競態），驗證即使前端日期守衛放行，repository 那道鎖月 trigger
    // 仍是最後防線，錯誤訊息一樣經 errors.dart 轉成「已清帳」。
    final repo = InMemoryLedgerRepository(
      seed: snapshotWith(categories: cats3, entries: const [], allocations: const [])
          .copyWith(closes: [closeOf(thisMonth)]),
    );
    await pumpBudget(tester, repository: repo);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: '本月非過去月，前端日期守衛放行');

    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '1000');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 仍開著，不 pop');
    expect(find.textContaining('已清帳'), findsOneWidget);
  });

  testWidgets('已設定：sheet 唯讀顯示金額／備註／設定者／日期，無輸入欄、無退回刪除修改文字', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(3), createdBy: kMeId, note: '本月食品'),
    ];
    await pumpBudget(tester, allocations: allocations);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('退回'), findsNothing);
    expect(find.text('刪除'), findsNothing);
    expect(find.text('修改'), findsNothing);
    expect(find.text(fmtAmount(5000)), findsWidgets, reason: '「金額」欄位顯示 5,000');
    expect(find.text('本月食品'), findsOneWidget, reason: '備註');
    expect(find.text('Mike'), findsOneWidget, reason: '設定者');
    expect(find.text(fmtDate(day(3))), findsOneWidget, reason: '日期');
  });

  testWidgets('過去月份未設定：顯示「已過期，不可設定」且無輸入欄', (tester) async {
    await pumpBudget(tester);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(prevMonth)), findsOneWidget);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();

    expect(find.text('已過期，不可設定'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('複製上月：本月完全無預算 → 提示出現，複製建對筆數與金額（cat1、cat2 兩筆）', (tester) async {
    // spec 口徑：showPrompt 只看「本月完全沒有任何預算」，不是「還有分類沒設定」。
    // 上月：食品 5,000、餐飲 1,000；水電上月沒有值——本月三個分類都還沒設定，
    // 複製只會建有上月值的兩筆（食品、餐飲），水電沒有來源不建。
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: pday(1), createdBy: kMeId),
    ];
    final container = await pumpBudget(tester, allocations: allocations);
    final before = container.read(allocationsProvider).length;

    expect(find.text('設定本月預算'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byKey(const Key('copy-last-month-btn')));
    expect(btn.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('copy-last-month-btn')));
    await tester.pumpAndSettle();

    final after = container.read(allocationsProvider);
    expect(after.length, before + 2);
    final created = after.skip(before).toList();
    expect(created.every((a) => a.note == '複製上月'), isTrue);
    expect(created.every((a) => a.occurredOn == DateTime(thisMonth.year, thisMonth.month, 1)), isTrue);
    expect(created.where((a) => a.categoryId == 'c-food').single.amount, 5000);
    expect(created.where((a) => a.categoryId == 'c-dining').single.amount, 1000);
    expect(created.any((a) => a.categoryId == 'c-util'), isFalse);

    expect(find.text('設定本月預算'), findsNothing, reason: '建完提示消失（本月現在有預算了）');
  });

  testWidgets('本月已有任一預算 → 不顯示提示（即使其他分類還沒設定）', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-3', ledgerId: kLedgerId, categoryId: 'c-food', amount: 4000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, allocations: allocations);

    expect(find.text('設定本月預算'), findsNothing, reason: '食品本月已設定，即使餐飲、水電還沒設定也不提示');
    expect(find.byKey(const Key('copy-last-month-btn')), findsNothing);
  });

  testWidgets('上月無任何設定：提示出現但複製鈕 disabled，文字「上月沒有預算」', (tester) async {
    await pumpBudget(tester);

    expect(find.text('上月沒有預算'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byKey(const Key('copy-last-month-btn')));
    expect(btn.onPressed, isNull);
  });

  testWidgets('提示只在當月或未來月出現：過去月份即使有未設定分類也不顯示', (tester) async {
    final twoMonthsAgo = DateTime(prevMonth.year, prevMonth.month - 1, 1);
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: twoMonthsAgo, createdBy: kMeId)];
    await pumpBudget(tester, allocations: allocations);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text(fmtMonth(prevMonth)), findsOneWidget);
    expect(find.byKey(const Key('copy-last-month-btn')), findsNothing);
    expect(find.text('設定本月預算'), findsNothing);
  });

  testWidgets('複製上月寫到一半失敗：頁內講清楚已建幾筆／共幾筆，不靜默留半套', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 2000, occurredOn: pday(1), createdBy: kMeId),
    ];
    final container = await pumpBudget(
      tester,
      allocations: allocations,
      allocationsNotifier: () => _PartlyFailingAllocations(allocations, 1),
    );
    final before = container.read(allocationsProvider).length;

    await tester.tap(find.byKey(const Key('copy-last-month-btn')));
    await tester.pumpAndSettle();

    expect(container.read(allocationsProvider).length, before + 1, reason: '第一筆成功、第二筆炸掉');
    final error = find.byKey(const Key('copy-last-month-error'));
    expect(error, findsOneWidget, reason: '頁內顯示，不用會自己消失的 SnackBar');
    final text = tester.widget<Text>(error).data!;
    expect(text, contains('已建 1／2 筆'));
    expect(text, contains('寫入被拒絕'));
  });

  testWidgets('切到下月：複製上月以「檢視月」為基準（不是以今天為基準），5 筆建立且 id 互異', (tester) async {
    // 本月（今天所在月）5 個分類都有預算；view 切到下月後，「上月」＝本月（今天所在月），
    // 不是「今天再往前一個月」。
    final allocations = [
      for (var i = 0; i < cats5.length; i++)
        BudgetAllocation(id: 'a-${i + 1}', ledgerId: kLedgerId, categoryId: cats5[i].id, amount: 1000 * (i + 1), occurredOn: day(1), createdBy: kMeId),
    ];
    final container = await pumpBudget(tester, categories: cats5, allocations: allocations);
    final before = container.read(allocationsProvider).length;

    await tester.tap(find.byKey(const Key('month-next')));
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(nextMonth)), findsOneWidget);
    expect(find.text('設定本月預算'), findsOneWidget);

    await tester.tap(find.byKey(const Key('copy-last-month-btn')));
    await tester.pumpAndSettle();

    final after = container.read(allocationsProvider);
    expect(after.length, before + 5);
    final created = after.skip(before).toList();
    expect(created.map((a) => a.id).toSet().length, 5, reason: '5 個 id 互異');
    expect(created.every((a) => sameMonth(a.occurredOn, nextMonth)), isTrue, reason: '複製到檢視月（下月）');
    for (var i = 0; i < cats5.length; i++) {
      expect(created.singleWhere((a) => a.categoryId == cats5[i].id).amount, 1000 * (i + 1));
    }
  });

  testWidgets('月份標題左滑切下月、右滑切回上月', (tester) async {
    await pumpBudget(tester);
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(nextMonth)), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
  });

  testWidgets('點月份標題開底部年月滾輪、點窗外套用', (tester) async {
    await pumpBudget(tester);

    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);

    await tester.tapAt(const Offset(200, 20)); // 點彈窗外即套用目前滾到的值
    await tester.pumpAndSettle();

    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
  });

  testWidgets('390×844：分類列數字單行不截斷、不用 FittedBox 縮字級也不 overflow', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 123456, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, splitMethod: SplitMethod.common),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 100000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    final valueFinder = inRow('c-food', find.text(fmtAmount(123456)));
    final paragraph = tester.renderObject<RenderParagraph>(valueFinder);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('390 寬：頂部第二列三欄六位數金額縮字級頂住、不截斷也不炸版', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 723456, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, splitMethod: SplitMethod.common),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 100000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    // 本月預算 100,000／本月共同支出 723,456／本月超支 623,456：三欄都撐到六位數＋「元」。
    // 金額不能用省略號截斷（會讓人看錯錢）：`_stat` 改用 FittedBox(scaleDown) 縮字級頂住，
    // 所以這裡要驗證的是「六位數金額三欄下 didExceedMaxLines == false」——文字完整顯示，
    // 只是被縮小，不是被砍字。
    for (final value in [fmtMoney(100000), fmtMoney(723456), fmtMoney(623456)]) {
      final finder = find.text(value);
      expect(finder, findsOneWidget, reason: '$value 應該只出現一次（頂部那一格）');
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      expect(paragraph.didExceedMaxLines, isFalse, reason: '$value 縮字級顯示完整，不截斷');
    }
    expect(tester.takeException(), isNull, reason: 'FittedBox(scaleDown) 接住了，不該有 RenderFlex overflow 或其他例外');
  });

  testWidgets('深色主題渲染不炸', (tester) async {
    await pumpBudget(
      tester,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D), brightness: Brightness.dark)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('真主題殼（buildTheme）：亮色渲染與設定流程不炸', (tester) async {
    await pumpBudget(tester, theme: buildTheme(Brightness.light));
    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
