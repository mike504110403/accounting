/// 預算頁（v1.5／ADR-0009）：頂部四數字、分類列、設定本月預算 sheet、複製上月（預算）、
/// 月份切換、版面。個人補入區塊的行為在 `topup_section_test.dart`／`topup_sheet_test.dart`。
///
/// 真組裝：只 override `ledgerRepositoryProvider` 為 `repoWith(...)`，其餘 provider
/// 走真的 `snapshotProvider` 重算路徑（不把 provider 釘成常數遮掉重算邏輯）。
library;

import 'package:accounting/app/format.dart';
import 'package:accounting/app/theme.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/budget/allocation_sheet.dart';
import 'package:accounting/features/budget/budget_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 只有下面兩條「真實組裝」測試需要 main.dart／router.dart（team-lead 2026-09-05 授權
// 的明確例外，見規則張力）；其餘測試一律不碰這兩個檔案。budget_page.dart 本身透過
// `app/tutorial.dart → app/router.dart` 早已把整個 import graph 拉進來，所以這兩個
// import 不會讓「本檔可不可以編過」這件事變得更糟——本檔本來就得靠本地 router stub
// 才編得動（其他 feature 目錄尚未對齊 v1.5）。
import 'package:accounting/app/router.dart';
import 'package:accounting/main.dart';

import '../../support/fixtures.dart';

void main() {
  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month, 1);
  final prevMonthStart = DateTime(now.year, now.month - 1, 1);
  final nextMonthStart = DateTime(now.year, now.month + 1, 1);
  DateTime day(int d) => DateTime(now.year, now.month, d);
  DateTime pday(int d) => DateTime(prevMonthStart.year, prevMonthStart.month, d);

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

  /// 大部分測試不關心「個人補入」區塊：清空 members／topups，區塊只剩標題一行，
  /// 不會跟分類列或頂部數字的斷言互相污染。
  InMemoryLedgerRepository repoFor({
    List<Category> categories = cats3,
    List<Entry> entries = const [],
    List<BudgetAllocation> allocations = const [],
    List<PersonalTopup> topups = const [],
    List<Member> members = const [],
    List<MonthClose> closes = const [],
  }) =>
      repoWith(
        categories: categories,
        entries: entries,
        allocations: allocations,
        topups: topups,
        members: members,
        closes: closes,
        currentMemberId: kMeId,
      );

  Future<ProviderContainer> pumpBudget(
    WidgetTester tester, {
    InMemoryLedgerRepository? repository,
    Size size = const Size(390, 844),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [ledgerRepositoryProvider.overrideWithValue(repository ?? repoFor())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: theme, home: const BudgetPage()),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Finder inRow(String categoryId, Finder f) =>
      find.descendant(of: find.byKey(ValueKey('category-row-$categoryId')), matching: f);

  // ── 真實組裝（未達成，環境阻擋——見規則張力）───────────────────────────
  //
  // 這兩條用 `AccountingApp`＋真 `routerProvider`，budget worktree 這裡只能靠本地
  // 暫時把 `lib/app/router.dart` 換成只註冊 `/budget` 的最小版本才跑得動（team-lead
  // 授權、跑完已 `git checkout -- lib/app/router.dart` 還原，不落地）。內容已依現行
  // v1.5 seed（`lib/data/in_memory_repository.dart`）手算更新；合併點請大腦用真
  // router 重跑一次才算數。

  testWidgets(
      '真實組裝：AccountingApp 根啟動點「預算」tab → 點住房列（seed 本月未設定）→ 設定金額 → 存 → 列顯示金額且再點開沒有輸入欄',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();

    container.read(routerProvider).go('/budget');
    await tester.pumpAndSettle();

    // v1.5 手算（現行 seed）：本月預算合計＝食品 6,000＋餐飲 4,000＋水電 3,000＝13,000。
    expect(find.text(fmtMoney(13000)), findsOneWidget, reason: '本月預算合計（頂部四格）');

    // ListView 的子項超出視窗＋cacheExtent 不會建 Element：真 app 的 SummaryCard／
    // 個人補入區塊比 pumpBudget 那組乾淨 fixture 高得多，住房列（c-house）會被推到
    // 800×600 預設視窗外，先捲到看得到再斷言／點擊。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-row-c-house')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 住房（c-house）本月沒有任何帳目、也從沒設過預算：noActivity，只顯示「未設定」。
    expect(inRow('c-house', find.text('未設定')), findsOneWidget);
    expect(inRow('c-house', find.text('超支')), findsNothing);

    await tester.tap(find.text('住房').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '30000');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsNothing, reason: 'sheet 應已關閉');
    // 住房本月沒有任何支出（現行 seed 與舊版不同，舊版房租 26,000 讓三個數字互不相同）：
    // 剛設定 30,000 後 spent=0，「剩餘」與「預算」同值，都會顯示 30,000，findsWidgets
    // 才是正確斷言（見上面 c-util 那條「已花與超支都是 8,000」同理）。
    expect(inRow('c-house', find.text(fmtAmount(30000))), findsWidgets, reason: '列上顯示剛設定的預算');

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

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    // v1.5 手算（現行 seed）：上月食品預算 5,000／已花 1,200（Mike 先付）、餐飲預算
    // 3,000／已花 800（老婆先付），上月沒有任何共同錢包支出或收入——共同餘額（累計
    // 水位）停在 0。
    expect(find.text(fmtMonth(prevMonthStart)), findsOneWidget);
    expect(find.text(fmtMoney(0)), findsOneWidget, reason: '上月底共同餘額');

    // 同上一條的理由：先捲到分類列可見範圍再斷言（食品／餐飲排序較前，通常已在
    // 視窗內，這裡仍照同一手法做防禦性檢查，不假設視窗高度）。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('category-row-c-dining')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(inRow('c-food', find.text(fmtAmount(1200))), findsOneWidget, reason: '上月食品已花');
    expect(inRow('c-dining', find.text(fmtAmount(800))), findsOneWidget, reason: '上月餐飲已花');
  });

  // ── 共用驗收 1／7：seed 下頂部四數字＋分類已花含兩種付款 ─────────────────

  testWidgets('seed 下頂部四數字：共同餘額 17,000／本月支出 11,000（不分共同錢包／成員先付）', (tester) async {
    // 波 1 假資料本身就是 spec v1.5「三個數」那組已知資料集：seed 全用，不清 topups/members，
    // 直接驗證真正的預設種子（其餘測試才用乾淨 fixture 排除干擾）。
    await pumpBudget(tester, repository: InMemoryLedgerRepository());

    expect(find.text('共同餘額'), findsOneWidget);
    expect(find.text(fmtMoney(17000)), findsOneWidget, reason: '共同收入 20,000 − 共同錢包支出 3,000');
    expect(find.text('本月預算合計'), findsOneWidget);
    expect(find.text(fmtMoney(13000)), findsOneWidget, reason: '食品 6,000＋餐飲 4,000＋水電 3,000');
    expect(find.text('本月支出'), findsOneWidget);
    expect(find.text(fmtMoney(11000)), findsOneWidget, reason: '全部支出：3,000＋6,000＋2,000＋1,000－1,000（沖銷）');
    expect(find.text('本月超支'), findsOneWidget);
    final overStat = find.ancestor(of: find.text('本月超支'), matching: find.byType(Column)).first;
    expect(find.descendant(of: overStat, matching: find.text('—')), findsOneWidget, reason: '三分類都沒超支');
  });

  testWidgets('分類列「已花」＝全部支出：seed 內同分類共同錢包付與成員先付各一筆時斷言合計', (tester) async {
    // 驗收標準 7 的字面前提（「seed 內同分類兩種付款各一筆」）與波 1 全域假資料不符——
    // 波 1 假資料裡本月沒有任何一個分類同時有共同錢包付與成員先付兩筆（規則張力，
    // 已在完成回報列出）；這裡改用針對性 fixture 直接驗證同一件事：
    // 水電本月一筆共同錢包付 2,000、一筆 Mike 先付 1,500，已花應該是兩者合計 3,500。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 2000, categoryId: 'c-util', occurredOn: day(3), createdBy: kMeId, note: '共同錢包水電'),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1500, categoryId: 'c-util', occurredOn: day(5), createdBy: kMeId, payerId: kMeId, note: 'Mike 先付水電'),
    ];
    await pumpBudget(tester, repository: repoFor(entries: entries));

    expect(inRow('c-util', find.text('未設定')), findsOneWidget);
    expect(inRow('c-util', find.text(fmtAmount(3500))), findsWidgets, reason: '已花＝共同錢包 2,000＋先付 1,500');
  });

  // ── 變異證明（d）：spent 改回只算共同錢包付會讓上面那條測試變紅 ──────────
  //
  // 若有人把 `spentIn`／頁面層改回「只加 payerId == null 的支出」，上一條測試的
  // 已花會變成 2,000（漏掉 Mike 先付的 1,500），`findsWidgets` 對 3,500 落空、測試變紅。

  // ── 頂部四格與分類列（沿用波 1／v1.4 的既有覆蓋，改用 v1.5 建構子）───────

  testWidgets('頂部四格文字與數字：共同餘額／本月預算合計／本月支出／本月超支', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 4000, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, payerId: kMeId),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1500, categoryId: 'c-dining', occurredOn: day(12), createdBy: kMeId, payerId: kMeId),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 6000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, repository: repoFor(entries: entries, allocations: allocations));

    expect(find.text('共同餘額'), findsOneWidget);
    expect(find.text(fmtMoney(0)), findsOneWidget, reason: '共同錢包沒動（兩筆都是代墊 payerId=kMeId），也無收入');
    expect(find.text('本月預算合計'), findsOneWidget);
    expect(find.text(fmtMoney(6000)), findsOneWidget);
    expect(find.text('本月支出'), findsOneWidget);
    expect(find.text(fmtMoney(5500)), findsOneWidget, reason: '4,000 + 1,500，不分 payer');
    expect(find.text('本月超支'), findsOneWidget);
    expect(find.text(fmtMoney(1500)), findsOneWidget, reason: '食品不超支；餐飲無預算，1,500 全記超支');
  });

  testWidgets('monthSummary 尚未回應：頂部四格與分類列吃 balance_math 本地公式 fallback，不是靜靜畫 0', (tester) async {
    final entries = [
      // payerId＝成員先付：不動共同餘額，讓「共同餘額本地手算＝0」這個斷言乾淨（跟
      // 「本月支出」斷言互不干擾——共同錢包付會讓 sharedBalance 變成 -4,000）。
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 4000, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId, payerId: kMeId),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 6000, occurredOn: day(1), createdBy: kMeId)];
    final repo = NeverRespondingMonthSummaryRepository(
      seed: snapshotWith(categories: cats3, entries: entries, allocations: allocations, members: const [], topups: const []),
    );
    await pumpBudget(tester, repository: repo);

    expect(find.text(fmtMoney(0)), findsOneWidget, reason: '共同餘額本地手算＝0（沒有收入也沒有共同錢包支出）');
    expect(find.text(fmtMoney(6000)), findsOneWidget, reason: '本月預算合計 6,000 本地手算');
    expect(find.text(fmtMoney(4000)), findsOneWidget, reason: '本月支出 4,000 本地手算');
    expect(inRow('c-food', find.text(fmtAmount(2000))), findsOneWidget, reason: '食品剩餘 6,000－4,000＝2,000 本地手算');
  });

  testWidgets('全無預算無支出時本月超支顯示「—」不上紅', (tester) async {
    await pumpBudget(tester);

    final overStat = find.ancestor(of: find.text('本月超支'), matching: find.byType(Column)).first;
    final dash = find.descendant(of: overStat, matching: find.text('—'));
    expect(dash, findsOneWidget);
    final scheme = Theme.of(tester.element(find.byType(BudgetPage))).colorScheme;
    expect(tester.widget<Text>(dash).style?.color, isNot(scheme.error), reason: '0 時不上紅');
  });

  testWidgets('分類列文案：已設定顯示「預算／已花／剩餘」，超支顯示「超支」，未設定顯示「未設定」且不畫三數字', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 3000, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1500, categoryId: 'c-dining', occurredOn: day(12), createdBy: kMeId),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, repository: repoFor(entries: entries, allocations: allocations));

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

  testWidgets('無預算但有支出的分類：列顯示「未設定」＋已花與超支兩數字，且頂部超支含它', (tester) async {
    // 水電從沒設過預算，但本月已有支出 8,000（allocated==0 && spent>0）：不是真空的
    // noActivity（allocated0 && spent0），不可藏成「未設定」四字了事，要把已花與超支
    // 都攤出來——它照樣計入頂部本月超支。食品另設預算 5,000、花 3,000（沒超支），
    // 純粹讓頂部「本月支出」（11,000）與「本月超支」（8,000，只來自水電）數字不同，
    // 斷言才不會撞號。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 8000, categoryId: 'c-util', occurredOn: day(5), createdBy: kMeId),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 3000, categoryId: 'c-food', occurredOn: day(6), createdBy: kMeId),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, repository: repoFor(entries: entries, allocations: allocations));

    expect(inRow('c-util', find.text('未設定')), findsOneWidget);
    expect(inRow('c-util', find.text('已花')), findsOneWidget);
    expect(inRow('c-util', find.text('超支')), findsOneWidget);
    expect(inRow('c-util', find.text(fmtAmount(8000))), findsWidgets, reason: '已花與超支都是 8,000（allocated=0）');

    expect(find.text('本月支出'), findsOneWidget);
    expect(find.text(fmtMoney(11000)), findsOneWidget, reason: '8,000（水電）＋3,000（食品）');
    expect(find.text('本月超支'), findsOneWidget);
    expect(find.text(fmtMoney(8000)), findsOneWidget, reason: '頂部本月超支只來自水電（食品有預算沒超支）');
  });

  testWidgets('無預算、當月淨額被沖銷成負數的分類：列顯示「未設定」＋已花負數，不畫「超支」', (tester) async {
    // 水電從沒設過預算；當月唯一一筆是沖銷筆（負 26,000，模擬「原筆在別的統計範圍、
    // 這裡只看得到反向那筆淨額」的邊界情況）：allocated=0、spent=-26,000，over 被
    // balance_math 夾在 0。已花是「全部支出」的事實，負數也不能藏；超支沒有意義
    // （over<=0）就不該再畫一行「超支 0」。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: -26000, categoryId: 'c-util', occurredOn: day(5), createdBy: kMeId, isAdjustment: true),
    ];
    await pumpBudget(tester, repository: repoFor(entries: entries));

    expect(inRow('c-util', find.text('未設定')), findsOneWidget);
    expect(inRow('c-util', find.text('已花')), findsOneWidget);
    expect(inRow('c-util', find.text(fmtAmount(-26000))), findsOneWidget, reason: '已花 -26,000 不可藏');
    expect(inRow('c-util', find.text('超支')), findsNothing, reason: 'over 被夾在 0，不畫超支那組');
  });

  testWidgets('水位比例＝剩餘／預算；超支時滿條錯誤色', (tester) async {
    // 食品：預算 4,000、已花 1,000 → 剩餘 3,000、水位 0.75、不紅。
    // 餐飲：預算 1,000、已花 1,500 → 超支、滿條 errorContainer。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1000, categoryId: 'c-food', occurredOn: day(5), createdBy: kMeId),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1500, categoryId: 'c-dining', occurredOn: day(6), createdBy: kMeId),
    ];
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 4000, occurredOn: day(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: day(1), createdBy: kMeId),
    ];
    await pumpBudget(tester, repository: repoFor(entries: entries, allocations: allocations));
    final scheme = Theme.of(tester.element(find.byType(BudgetPage))).colorScheme;

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
    expect(find.text(fmtMonth(nextMonthStart)), findsOneWidget);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '800');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    final added = container.read(allocationsProvider).last;
    expect(added.occurredOn, DateTime(nextMonthStart.year, nextMonthStart.month, 1));
  });

  testWidgets('設定儲存失敗：sheet 仍開著、sheet 內顯示錯誤文字', (tester) async {
    final repo = FailingRepository(
      seed: snapshotWith(categories: cats3, entries: const [], allocations: const [], members: const [], topups: const []),
      failAddAllocation: true,
    );
    await pumpBudget(tester, repository: repo);

    await tester.tap(find.text('餐飲').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('allocation-amount-field')), '1234');
    await tester.tap(find.byKey(const Key('allocation-add-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('allocation-amount-field')), findsOneWidget, reason: 'sheet 仍開著');
    // `FailingRepository` 丟的是 `LedgerException('boom')`，sheet 直接顯示 `e.message`
    // （見 `AllocationSheet._submit` 的 catch），不是走非 LedgerException 的「儲存失敗」fallback。
    expect(find.text('boom'), findsOneWidget);
    expect(find.text('處理中…'), findsNothing, reason: '_saving 要解除，不能卡住');
    final btn = tester.widget<FilledButton>(find.byKey(const Key('allocation-add-btn')));
    expect(btn.onPressed, isNotNull, reason: '失敗後應可重試');
  });

  testWidgets('unique 23505（前端快取還沒同步、伺服器早有這筆）：sheet 內顯示含「本月已設定」', (tester) async {
    final existing = BudgetAllocation(id: 'a-server', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(1), createdBy: kMeId);
    final repo = InMemoryLedgerRepository(
      seed: snapshotWith(categories: cats3, entries: const [], allocations: [existing], members: const [], topups: const []),
    );
    // 這條測試的前提就是「本地快取與 repository 快照不同步」，真組裝（`repoWith` 兩者
    // 同源）做不出這個分歧——刻意疊一個空的 `allocationsProvider` 覆寫才模擬得出
    // 「本地還沒看到 server 早有的那筆」，不是要遮掉重算邏輯（其餘測試都不這樣做）。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(repo),
      allocationsProvider.overrideWith(_EmptyAllocations.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: BudgetPage()),
    ));
    await tester.pumpAndSettle();

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
    final repo = InMemoryLedgerRepository(
      seed: snapshotWith(categories: cats3, entries: const [], allocations: const [], members: const [], topups: const [])
          .copyWith(closes: [closeFixture(month: thisMonth)]),
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

  testWidgets('已設定：sheet 唯讀顯示金額／備註／設定者／日期，無輸入欄', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: day(3), createdBy: kMeId, note: '本月食品'),
    ];
    final members = [Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: thisMonth)];
    await pumpBudget(tester, repository: repoFor(allocations: allocations, members: members));

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('退回'), findsNothing);
    expect(find.text('刪除'), findsNothing);
    expect(find.text('修改'), findsNothing);
    expect(find.text(fmtAmount(5000)), findsWidgets, reason: '「金額」欄位顯示 5,000');
    expect(find.text('本月食品'), findsOneWidget, reason: '備註');
    expect(find.text(fmtDate(day(3))), findsOneWidget, reason: '日期');
    // 「Mike」在個人補入區塊也會出現一次（該區塊列出所有成員），限定在 sheet 內找
    // 才是真正驗證「設定者」欄位。
    expect(find.descendant(of: find.byType(AllocationSheet), matching: find.text('Mike')), findsOneWidget, reason: '設定者');
  });

  testWidgets('過去月份未設定：顯示「已過期，不可設定」且無輸入欄', (tester) async {
    await pumpBudget(tester);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(prevMonthStart)), findsOneWidget);

    await tester.tap(find.text('水電').first);
    await tester.pumpAndSettle();

    expect(find.text('已過期，不可設定'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('複製上月（預算）：本月完全無預算 → 提示出現，複製建對筆數與金額', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 1000, occurredOn: pday(1), createdBy: kMeId),
    ];
    final container = await pumpBudget(tester, repository: repoFor(allocations: allocations));
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
    expect(created.every((a) => a.occurredOn == DateTime(thisMonth.year, thisMonth.month, 1)), isTrue, reason: '複製到本月 1 號');
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
    await pumpBudget(tester, repository: repoFor(allocations: allocations));

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
    final twoMonthsAgo = DateTime(prevMonthStart.year, prevMonthStart.month - 1, 1);
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: twoMonthsAgo, createdBy: kMeId)];
    await pumpBudget(tester, repository: repoFor(allocations: allocations));

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text(fmtMonth(prevMonthStart)), findsOneWidget);
    expect(find.byKey(const Key('copy-last-month-btn')), findsNothing);
    expect(find.text('設定本月預算'), findsNothing);
  });

  testWidgets('複製上月寫到一半失敗：頁內講清楚已建幾筆／共幾筆', (tester) async {
    final allocations = [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: pday(1), createdBy: kMeId),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 2000, occurredOn: pday(1), createdBy: kMeId),
    ];
    final repo = _PartlyFailingAllocationRepository(
      seed: snapshotWith(categories: cats3, allocations: allocations, entries: const [], members: const [], topups: const []),
      okCount: 1,
    );
    final container = await pumpBudget(tester, repository: repo);
    final before = container.read(allocationsProvider).length;

    await tester.tap(find.byKey(const Key('copy-last-month-btn')));
    await tester.pumpAndSettle();

    expect(container.read(allocationsProvider).length, before + 1, reason: '第一筆成功、第二筆炸掉');
    final error = find.byKey(const Key('copy-last-month-error'));
    expect(error, findsOneWidget);
    final text = tester.widget<Text>(error).data!;
    expect(text, contains('已建 1／2 筆'));
    expect(text, contains('寫入被拒絕'));
  });

  testWidgets('切到下月：複製上月以「檢視月」為基準，5 筆建立且 id 互異', (tester) async {
    final allocations = [
      for (var i = 0; i < cats5.length; i++)
        BudgetAllocation(id: 'a-${i + 1}', ledgerId: kLedgerId, categoryId: cats5[i].id, amount: 1000 * (i + 1), occurredOn: day(1), createdBy: kMeId),
    ];
    final container = await pumpBudget(tester, repository: repoFor(categories: cats5, allocations: allocations));
    final before = container.read(allocationsProvider).length;

    await tester.tap(find.byKey(const Key('month-next')));
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(nextMonthStart)), findsOneWidget);
    expect(find.text('設定本月預算'), findsOneWidget);

    await tester.tap(find.byKey(const Key('copy-last-month-btn')));
    await tester.pumpAndSettle();

    final after = container.read(allocationsProvider);
    expect(after.length, before + 5);
    final created = after.skip(before).toList();
    expect(created.map((a) => a.id).toSet().length, 5, reason: '5 個 id 互異');
    expect(created.every((a) => sameMonth(a.occurredOn, nextMonthStart)), isTrue);
    for (var i = 0; i < cats5.length; i++) {
      expect(created.singleWhere((a) => a.categoryId == cats5[i].id).amount, 1000 * (i + 1));
    }
  });

  testWidgets('月份標題左滑切下月、右滑切回上月', (tester) async {
    await pumpBudget(tester);
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(nextMonthStart)), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
  });

  testWidgets('點月份標題開底部年月滾輪、點窗外套用', (tester) async {
    await pumpBudget(tester);

    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();

    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
  });

  testWidgets('390×844：分類列數字單行不截斷', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 123456, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 100000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, repository: repoFor(entries: entries, allocations: allocations));

    final valueFinder = inRow('c-food', find.text(fmtAmount(123456)));
    final paragraph = tester.renderObject<RenderParagraph>(valueFinder);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('390×667：含個人補入區塊在內不爆版', (tester) async {
    await pumpBudget(tester, repository: InMemoryLedgerRepository(), size: const Size(390, 667));
    expect(tester.takeException(), isNull);
  });

  testWidgets('390 寬：頂部第二列三欄六位數金額縮字級頂住、不截斷也不炸版', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 723456, categoryId: 'c-food', occurredOn: day(10), createdBy: kMeId),
    ];
    final allocations = [BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 100000, occurredOn: day(1), createdBy: kMeId)];
    await pumpBudget(tester, repository: repoFor(entries: entries, allocations: allocations));

    for (final value in [fmtMoney(100000), fmtMoney(723456), fmtMoney(623456)]) {
      final finder = find.text(value);
      expect(finder, findsOneWidget, reason: '$value 應該只出現一次（頂部那一格）');
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      expect(paragraph.didExceedMaxLines, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色主題渲染不炸', (tester) async {
    await pumpBudget(
      tester,
      repository: InMemoryLedgerRepository(),
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

/// 空的 `allocationsProvider`：只給「unique 23505／前端快取落後」那條測試模擬
/// 本地快取與 repository 快照分歧用，不是一般的 seam 覆寫手法。
class _EmptyAllocations extends AllocationsNotifier {
  @override
  List<BudgetAllocation> build() => const [];
}

/// `addAllocation` 前 [okCount] 次成功、之後全丟 [LedgerException]（複製上月批次寫到一半）。
class _PartlyFailingAllocationRepository extends InMemoryLedgerRepository {
  _PartlyFailingAllocationRepository({super.seed, required this.okCount});
  final int okCount;
  int _n = 0;

  @override
  Future<BudgetAllocation> addAllocation(BudgetAllocation a) {
    if (_n++ >= okCount) throw const LedgerException('寫入被拒絕');
    return super.addAllocation(a);
  }
}
