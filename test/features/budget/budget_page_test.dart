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

/// add 一律丟例外，用來驗儲存失敗路徑（sheet 仍要開著、內部顯示錯誤，不能被 pop 掉）。
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

  // 回傳型別交給推論：flutter_riverpod 3 沒有匯出 `Override` 這個型別名（同 stats_page_test.dart 慣例）。
  overridesFor({
    List<Category> categories = cats3,
    List<Entry> entries = const [],
    List<BudgetAllocation> allocations = const [],
    Ledger ledger = ledger10k,
    bool throwing = false,
    AllocationsNotifier Function()? allocationsNotifier,
  }) => [
        categoriesProvider.overrideWithValue(categories),
        ledgerProvider.overrideWithValue(ledger),
        entriesProvider.overrideWith(() => _FixedEntries(entries)),
        allocationsProvider.overrideWith(allocationsNotifier ??
            () => throwing ? _ThrowingAllocations(allocations) : _FixedAllocations(allocations)),
        // month_summary（衍生數字改吃 DB）：InMemory repo 餵同一份 fixture，
        // 讓 monthSummaryProvider 算出與畫面 fixture 一致的 server 值。
        ledgerRepositoryProvider.overrideWithValue(repoWith(
          ledger: ledger,
          categories: categories,
          entries: entries,
          allocations: allocations,
        )),
      ];

  Future<ProviderContainer> pumpBudget(
    WidgetTester tester, {
    List<Category> categories = cats3,
    List<Entry> entries = const [],
    List<BudgetAllocation> allocations = const [],
    Ledger ledger = ledger10k,
    bool throwing = false,
    ThemeData? theme,
    AllocationsNotifier Function()? allocationsNotifier,
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

  testWidgets('真實組裝：AccountingApp 根啟動點「預算」，頂部可用餘額／信封總額與 seed 手算一致', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();

    container.read(routerProvider).go('/budget');
    await tester.pumpAndSettle();

    // 手算同舊版檔頭：可用餘額 154,800（共同餘額）− 10,500（信封剩餘）＝ 144,300。
    expect(find.text('可用餘額'), findsOneWidget);
    expect(find.text(fmtMoney(144300)), findsOneWidget);
    expect(find.text('信封總額'), findsOneWidget);
    expect(find.text(fmtMoney(10500)), findsOneWidget);
    expect(find.text('食品'), findsOneWidget);

    // 整合回歸：切到上月，食品撥款 5,500／預算支出 6,200 → 超支 700（紅字），可用餘額同步扣成 134,700。
    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    expect(inRow('c-food', find.text(fmtAmount(700))), findsOneWidget, reason: '上月食品超支 700');
    final overText = tester.widget<Text>(inRow('c-food', find.text(fmtAmount(700))));
    expect(overText.style?.color, Theme.of(tester.element(find.byType(BudgetPage))).colorScheme.error);
    expect(find.text(fmtMoney(134700)), findsOneWidget, reason: '可用餘額同步扣');
  });

  testWidgets('頂部三數字：可用餘額／信封總額／本月超支；分類列三數字（撥款／已花／剩餘，超支時剩餘換成紅字超支）；未撥款列灰字', (tester) async {
    // 食品：撥款 5,000、預算支出 3,000 → 剩餘 2,000、超支 0 → 顯示「剩餘」
    // 餐飲：撥款 1,000、預算支出 1,500 → 剩餘 0、超支 500 → 那格換顯示紅字「超支」
    // 水電：無撥款無預算支出 → 未撥款
    // 共同餘額＝10,000 − (3,000＋1,500) ＝ 5,500；信封總額＝2,000＋0＝2,000；可用餘額＝5,500−2,000＝3,500
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 3000, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1500, categoryId: 'c-dining', occurredOn: day(12), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    expect(find.text(fmtMoney(3500)), findsOneWidget, reason: '可用餘額');
    expect(find.text(fmtMoney(2000)), findsOneWidget, reason: '信封總額');
    expect(find.text(fmtMoney(500)), findsOneWidget, reason: '本月超支');

    expect(inRow('c-food', find.text(fmtAmount(5000))), findsOneWidget, reason: '食品撥款');
    expect(inRow('c-food', find.text(fmtAmount(3000))), findsOneWidget, reason: '食品已花');
    expect(inRow('c-food', find.text(fmtAmount(2000))), findsOneWidget, reason: '食品剩餘');
    expect(inRow('c-food', find.text('超支')), findsNothing, reason: '食品沒超支，不該出現超支欄');

    expect(inRow('c-dining', find.text(fmtAmount(1000))), findsOneWidget, reason: '餐飲撥款');
    expect(inRow('c-dining', find.text(fmtAmount(1500))), findsOneWidget, reason: '餐飲已花');
    expect(inRow('c-dining', find.text(fmtAmount(500))), findsOneWidget, reason: '餐飲超支＝500（紅字，取代剩餘那格）');
    expect(inRow('c-dining', find.text('剩餘')), findsNothing, reason: '超支時不該再顯示剩餘欄');
    final overText = tester.widget<Text>(inRow('c-dining', find.text(fmtAmount(500))));
    expect(overText.style?.color, Theme.of(tester.element(find.byType(BudgetPage))).colorScheme.error);

    expect(inRow('c-util', find.text('未撥款')), findsOneWidget, reason: '水電沒撥款也沒預算支出');
  });

  testWidgets('全無撥款無預算支出時本月超支顯示「—」不上紅', (tester) async {
    await pumpBudget(tester);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('水位比例＝剩餘／撥款；超支時滿條錯誤色', (tester) async {
    // 食品：撥款 4,000、已花 1,000 → 剩餘 3,000、水位 0.75、不紅。
    // 餐飲：撥款 1,000、已花 1,500 → 超支、滿條 errorContainer。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1000, categoryId: 'c-food', occurredOn: day(5), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1500, categoryId: 'c-dining', occurredOn: day(6), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
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

  testWidgets('sheet 首列顯示「本月：撥款 N・已花 N・剩餘 N」', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 800, categoryId: 'c-food', occurredOn: day(5), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    expect(find.text('本月：撥款 ${fmtAmount(3000)}・已花 ${fmtAmount(800)}・剩餘 ${fmtAmount(2200)}'), findsOneWidget);
  });

  testWidgets('金額空白或 0：sheet 內顯示錯誤且不 pop（撥入／退回都擋）', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 2000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, allocations: allocations);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();
    expect(find.text('請輸入金額'), findsOneWidget);
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');

    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '0');
    await tester.tap(find.byKey(const Key('allocation-return-btn')));
    await tester.pumpAndSettle();
    expect(find.text('請輸入金額'), findsOneWidget);
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');
  });

  testWidgets('提示只在當月無撥款出現：本月已有撥款則不顯示', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 1000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, allocations: allocations);

    expect(find.text('設定本月預算'), findsNothing);
    expect(find.byKey(const Key('copy-last-month-btn')), findsNothing);
  });

  testWidgets('提示只在當月或未來月出現：過去月份即使無撥款也不顯示（即使該過去月的上月有撥款可複製，也不該被 canCopy 掩護）', (tester) async {
    // 檢視月＝上月，該月無任何撥款。但「上月的上月」（兩個月前）有食品撥款 3,000 可複製——
    // 如果 showPrompt 漏判「只在當月／未來月出現」，這裡會誤判成「當月無撥款」而顯示提示，
    // 且 canCopy 會是 true（複製來源抓得到），文字會變成「設定本月預算」＋按鈕可按，
    // 跟「本來就不該出現任何提示」的正確行為有明顯落差；用按鈕 key 判定「提示列有沒有畫出來」，
    // 不用文字內容（文字會因 canCopy 而二選一，用錯文字判斷會對這條變異視而不見）。
    final twoMonthsAgo = DateTime(prevMonth.year, prevMonth.month - 1, 1);
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: twoMonthsAgo, createdBy: kMeId)];
    await pumpBudget(tester, allocations: allocations);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text(fmtMonth(prevMonth)), findsOneWidget);
    expect(find.byKey(const Key('copy-last-month-btn')), findsNothing, reason: '不管 canCopy 是 true 或 false，只要按鈕存在就代表提示列有畫出來');
    expect(find.text('設定本月預算'), findsNothing);
    expect(find.text('上月沒有撥款'), findsNothing);
  });

  testWidgets('本月無撥款：提示出現＋複製上月建對筆數與金額（>0 才建，退回後淨額 0 的分類不建）', (tester) async {
    // 上月＝檢視月（本月，未切換）的前一個月：食品 3,000；餐飲 2,000；水電先撥 1,000 又全退回＝淨額 0（不該被複製）。
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 2000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-3', ledgerId: kLedgerId, categoryId: 'c-util', amount: 1000, occurredOn: pday(2), createdBy: kMeId),
      BudgetAllocation(id: 'a-4', ledgerId: kLedgerId, categoryId: 'c-util', amount: -1000, occurredOn: pday(3), createdBy: kMeId),
    ];
    final container = await pumpBudget(tester, allocations: allocations);
    final before = container.read(allocationsProvider).length;

    expect(find.text('設定本月預算'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byKey(const Key('copy-last-month-btn')));
    expect(btn.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('copy-last-month-btn')));
    await tester.pumpAndSettle();

    final after = container.read(allocationsProvider);
    expect(after.length, before + 2, reason: '只複製食品與餐飲，水電淨額 0 不建');
    final created = after.skip(before).toList();
    expect(created.every((a) => a.note == '複製上月'), isTrue);
    expect(created.every((a) => a.occurredOn == DateTime(thisMonth.year, thisMonth.month, 1)), isTrue);
    expect(created.where((a) => a.categoryId == 'c-food').single.amount, 3000);
    expect(created.where((a) => a.categoryId == 'c-dining').single.amount, 2000);
    expect(created.any((a) => a.categoryId == 'c-util'), isFalse);

    // 建完提示消失。
    expect(find.text('設定本月預算'), findsNothing);
  });

  testWidgets('複製上月寫到一半失敗：頁內講清楚已建幾筆／共幾筆，不靜默留半套', (tester) async {
    // 一列＝一次撥款，沒有批次入口，中途失敗就是「已建 N 筆」。已建的是有效撥款不回頭刪，
    // 但一定要把數字說清楚——不然使用者只看到信封多了一半，不知道缺什麼、也不敢再按一次。
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 2000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-3', ledgerId: kLedgerId, categoryId: 'c-util', amount: 1500, occurredOn: pday(1), createdBy: kMeId),
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
    expect(text, contains('已建 1／3 筆'));
    expect(text, contains('寫入被拒絕'));
  });

  testWidgets('切到下月：複製上月以「檢視月」為基準（不是以今天為基準），5 筆建立且 id 互異', (tester) async {
    // 本月（今天所在月）5 個分類都有撥款；view 切到下月後，「上月」＝本月（今天所在月），不是「今天再往前一個月」。
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

  testWidgets('本月與上月都無撥款：複製上月按鈕 disabled 並顯示「上月沒有撥款」', (tester) async {
    await pumpBudget(tester);

    expect(find.text('上月沒有撥款'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byKey(const Key('copy-last-month-btn')));
    expect(btn.onPressed, isNull);
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

  testWidgets('點列開 sheet：撥入成功後 sheet 關閉、可用餘額同步下降', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 2000, occurredOn: day(1), createdBy: kMeId)];
    final container = await pumpBudget(tester, allocations: allocations);

    expect(find.text(fmtMoney(8000)), findsOneWidget); // 10,000 − 2,000

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '1000');
    await tester.enterText(find.byKey(const Key('allocation-note-field')), '加碼');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsNothing, reason: 'sheet 該關閉');
    final added = container.read(allocationsProvider).last;
    expect(added.amount, 1000);
    expect(added.categoryId, 'c-food');
    expect(added.note, '加碼');
    expect(added.createdBy, kMeId);
    expect(find.text(fmtMoney(7000)), findsOneWidget); // 8,000 − 1,000
  });

  testWidgets('撥款可負（退回）成功：信封還回可用餘額', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: day(1), createdBy: kMeId)];
    final container = await pumpBudget(tester, allocations: allocations);

    expect(find.text(fmtMoney(7000)), findsOneWidget); // 10,000 − 3,000

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '1000');
    await tester.tap(find.byKey(const Key('allocation-return-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsNothing, reason: 'sheet 該關閉');
    expect(container.read(allocationsProvider).last.amount, -1000);
    expect(find.text(fmtMoney(8000)), findsOneWidget); // 7,000 + 1,000
  });

  testWidgets('退回超過剩餘被擋：sheet 內錯誤、state 不變', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 500, categoryId: 'c-food', occurredOn: day(5), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 2000, occurredOn: day(1), createdBy: kMeId)];
    final container = await pumpBudget(tester, entries: entries, allocations: allocations);
    final before = container.read(allocationsProvider).length;

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    // 剩餘＝2,000－500＝1,500，退回 2,000 應被擋。
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '2000');
    await tester.tap(find.byKey(const Key('allocation-return-btn')));
    await tester.pumpAndSettle();

    expect(find.text('退回不得超過剩餘 ${fmtAmount(1500)}'), findsOneWidget);
    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');
    expect(container.read(allocationsProvider).length, before);
  });

  testWidgets('撥款儲存失敗：sheet 仍開著、sheet 內顯示錯誤文字', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 2000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, allocations: allocations, throwing: true);

    await tester.tap(find.text('食品').first);
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

  testWidgets('過去月份：sheet 可開但撥入／退回按鈕 disabled', (tester) async {
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: pday(1), createdBy: kMeId)];
    await pumpBudget(tester, allocations: allocations);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(prevMonth)), findsOneWidget);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    expect(find.text('過去月份不可撥款'), findsOneWidget);
    final addBtn = tester.widget<FilledButton>(find.byKey(const Key('allocation-add-btn')));
    final returnBtn = tester.widget<OutlinedButton>(find.byKey(const Key('allocation-return-btn')));
    expect(addBtn.onPressed, isNull);
    expect(returnBtn.onPressed, isNull);
  });

  testWidgets('本月撥款流水：列出且可刪除', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: day(1), createdBy: kMeId, note: '本月食品'),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-food', amount: 1000, occurredOn: day(5), createdBy: kMeId, note: '加碼'),
    ];
    final container = await pumpBudget(tester, allocations: allocations);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    expect(find.text('本月食品'), findsOneWidget);
    expect(find.text('加碼'), findsOneWidget);

    await tester.tap(find.byKey(const Key('allocation-delete-a-2')));
    await tester.pumpAndSettle();

    expect(find.text('加碼'), findsNothing);
    expect(container.read(allocationsProvider).any((a) => a.id == 'a-2'), isFalse);
    expect(container.read(allocationsProvider).any((a) => a.id == 'a-1'), isTrue);
  });

  testWidgets('流水金額 6 位數不撐高列（單行不換行、不撐高列高）', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 100, occurredOn: day(1), createdBy: kMeId, note: '小筆'),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-food', amount: 123456, occurredOn: day(2), createdBy: kMeId, note: '大筆'),
    ];
    await pumpBudget(tester, allocations: allocations);

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    final paragraph = tester.renderObject<RenderParagraph>(find.text(fmtAmount(123456)));
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);

    final smallRowHeight = tester.getSize(find.byKey(const ValueKey('allocation-flow-a-1'))).height;
    final bigRowHeight = tester.getSize(find.byKey(const ValueKey('allocation-flow-a-2'))).height;
    expect(bigRowHeight, smallRowHeight, reason: '6 位數金額不該把這列撐得比其他列高');
  });

  testWidgets('390×844：分類列數字單行不截斷、不用 FittedBox 縮字級也不 overflow', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 123456, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, splitMethod: SplitMethod.common, funding: Funding.budget),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 100000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, entries: entries, allocations: allocations);

    final valueFinder = inRow('c-food', find.text(fmtAmount(123456)));
    final paragraph = tester.renderObject<RenderParagraph>(valueFinder);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色主題渲染不炸', (tester) async {
    await pumpBudget(
      tester,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D), brightness: Brightness.dark)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('真主題殼（buildTheme）：亮色渲染與撥款流程不炸', (tester) async {
    await pumpBudget(tester, theme: buildTheme(Brightness.light));
    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
