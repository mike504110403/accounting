import 'package:accounting/app/month_app_bar.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/entries/entries_page.dart';
import 'package:accounting/features/entries/reversal.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// 把資料層換成指定內容的記憶體 repository（Notifier 的初值與寫入都吃它）。
ProviderContainer containerFor(LedgerRepository repo) =>
    ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);

Future<ProviderContainer> pumpApp(
  WidgetTester tester, [
  ProviderContainer? container,
  Size size = const Size(390, 844),
]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = container ?? ProviderContainer();
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AccountingApp()));
  await tester.pumpAndSettle();
  return c;
}

DateTime get _thisMonth => monthOf(DateTime.now());

/// 一筆本月支出。[payerId] null ＝共同錢包付。
Entry expense({
  required String id,
  required String note,
  int amount = 300,
  String categoryId = 'c-food',
  String? payerId,
  DateTime? on,
  bool isAdjustment = false,
}) =>
    Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: amount,
      categoryId: categoryId,
      occurredOn: on ?? DateTime(_thisMonth.year, _thisMonth.month, 10),
      createdBy: kMeId,
      note: note,
      payerId: payerId,
      isAdjustment: isAdjustment,
    );

/// 一組「原筆已被沖銷」的配對：沖銷筆的備註帶原筆短代碼，前端靠它配對
/// （DB 沒有指向欄，spec v1.5「沖銷」已知缺口）。id 一律 ≥8 碼，短代碼才成立。
final reversedOriginal = expense(id: 'e-orig-0001', note: '被沖銷的外送', amount: 1000, payerId: kMeId);
final reversalEntry = expense(
  id: 'e-rev-00001',
  note: '沖銷 #${reversalTag(reversedOriginal)}：被沖銷的外送',
  amount: -1000,
  payerId: kMeId,
  isAdjustment: true,
);

Finder payerChip(String entryId) => find.byKey(Key('payer-chip-$entryId'));

String chipText(WidgetTester tester, String entryId) =>
    tester.widget<Text>(find.descendant(of: payerChip(entryId), matching: find.byType(Text))).data!;

void main() {
  // ── v1.5：沒有視角、沒有結算 ────────────────────────────────────────

  testWidgets('帳目頁沒有視角切換，也沒有結算卡片與簽核入口', (tester) async {
    await pumpApp(tester);
    expect(find.byType(EntriesPage), findsOneWidget);

    expect(find.byKey(const Key('view-mode-toggle')), findsNothing);
    expect(find.text('家庭'), findsNothing);
    expect(find.text('個人'), findsNothing);
    expect(find.byKey(const Key('settlement-card')), findsNothing);
    expect(find.text('發起'), findsNothing);
    expect(find.text('同意'), findsNothing);
    expect(find.textContaining('待你簽核'), findsNothing);
    expect(find.textContaining('代墊'), findsNothing);
  });

  testWidgets('每筆支出列顯示付款人 chip（成員名或「共同」），收入列沒有 chip', (tester) async {
    await pumpApp(tester);

    // 波 1 假資料的本月帳目（in_memory_repository._seedEntries）：
    // e-1 薪水（收入）、e-2 水電（共同錢包）、e-3 本月買菜（Mike 先付）、e-4 週五晚餐（老婆先付）。
    expect(payerChip('e-1'), findsNothing, reason: '收入只有共同收入，沒有付款人');
    expect(chipText(tester, 'e-2'), '共同');
    expect(chipText(tester, 'e-3'), 'Mike');
    expect(chipText(tester, 'e-4'), '老婆');
  });

  testWidgets('月摘要顯示共同餘額 17,000（spec v1.5 三個數的已知資料集）', (tester) async {
    await pumpApp(tester);
    final summary = find.byKey(const Key('month-summary'));

    expect(find.descendant(of: summary, matching: find.text('共同餘額')), findsOneWidget);
    // 共同收入 20,000 − 共同錢包支出 3,000；成員先付的那幾筆一律不動它。
    expect(find.descendant(of: summary, matching: find.text('17,000')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('20,000')), findsOneWidget); // 收入
    expect(find.descendant(of: summary, matching: find.text('11,000')), findsOneWidget); // 支出
  });

  testWidgets('付款人 chip 隨資料走：共同錢包筆顯示「共同」而不是記帳人', (tester) async {
    await pumpApp(
      tester,
      containerFor(repoWith(entries: [
        expense(id: 'e-wallet-01', note: '共同錢包付'),
        expense(id: 'e-wife-0001', note: '老婆先付', payerId: kWifeId),
      ])),
    );
    expect(chipText(tester, 'e-wallet-01'), '共同');
    expect(chipText(tester, 'e-wife-0001'), '老婆');
  });

  testWidgets('付款人已不在成員清單（退出帳本／資料還沒同步）→ chip 顯示「成員」不是空白', (tester) async {
    await pumpApp(
      tester,
      containerFor(repoWith(
        // 只留 Mike：那筆 payerId 指到的成員查不到。
        members: [
          Member(
              id: kMeId,
              ledgerId: kLedgerId,
              userId: 'u1',
              displayName: 'Mike',
              joinedAt: DateTime(1970)),
        ],
        entries: [expense(id: 'e-ghost-001', note: '查不到的付款人', payerId: 'm-gone')],
      )),
    );
    expect(chipText(tester, 'e-ghost-001'), '成員',
        reason: '查不到成員時要退回可讀的字，不能讓 chip 變空白或整列不見');
    expect(find.text('查不到的付款人'), findsOneWidget);
  });

  testWidgets('收入列不留空標籤列：沒有 chip 也沒有標籤時整塊不畫', (tester) async {
    await pumpApp(
      tester,
      containerFor(repoWith(entries: [
        Entry(
          id: 'e-income-01',
          ledgerId: kLedgerId,
          kind: EntryKind.income,
          amount: 20000,
          categoryId: 'c-salary',
          occurredOn: DateTime(_thisMonth.year, _thisMonth.month, 5),
          createdBy: kMeId,
          note: '薪水',
        ),
        expense(id: 'e-wallet-01', note: '共同錢包付的水電'),
      ])),
    );
    expect(payerChip('e-income-01'), findsNothing);

    // 收入沒有付款人 chip、沒有細項、不是沖銷 → 那一列的子樹裡整個 Wrap 都不該存在。
    // 斷言範圍限定在「這一列」，不是全頁：全頁找 Wrap 會被別列的標籤救活，變成恆真。
    final incomeRow = find.widgetWithText(InkWell, '薪水');
    expect(incomeRow, findsOneWidget, reason: '先確定抓到的是這一列本身');
    expect(
      find.descendant(of: incomeRow, matching: find.byType(Wrap)),
      findsNothing,
      reason: '把 entries_page 的 `if (entry.isExpense || tags.isNotEmpty)` 拿掉，這條就會紅',
    );

    // 正向對照：支出列一定有標籤 Wrap（付款人 chip）。
    // 沒有這一條，上面的 findsNothing 可能只是因為 finder 根本抓不到東西。
    final expenseRow = find.widgetWithText(InkWell, '共同錢包付的水電');
    expect(expenseRow, findsOneWidget);
    expect(find.descendant(of: expenseRow, matching: find.byType(Wrap)), findsOneWidget);
  });

  // ── 刪除與守衛 ──────────────────────────────────────────────────────

  testWidgets('普通筆左滑可刪：確認框後從列表與 provider 移除', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: [
      expense(id: 'e-normal-01', note: '可刪的買菜', payerId: kMeId),
    ])));
    expect(find.text('可刪的買菜'), findsOneWidget);

    await tester.drag(find.text('可刪的買菜'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('刪除這筆帳目？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();

    expect(find.text('可刪的買菜'), findsNothing);
    expect(c.read(entriesProvider), isEmpty);
  });

  // 變異證明：把 entryRow 的 `isReversed(e)`／`e.isAdjustment` 從 immutable 條件拿掉，
  // 這兩條就會紅——滑得開就代表沖銷軌跡可以被刪掉，補入剩餘會憑空少一半。
  testWidgets('沖銷關係筆不可刪：被沖銷的原筆沒有左滑動作', (tester) async {
    await pumpApp(tester,
        containerFor(repoWith(entries: [reversedOriginal, reversalEntry])));

    expect(find.text('被沖銷的外送'), findsOneWidget);
    expect(find.text('已沖銷'), findsOneWidget, reason: '原筆要標已沖銷');
    expect(find.byKey(ValueKey('slide-${reversedOriginal.id}')), findsNothing);

    await tester.drag(find.text('被沖銷的外送'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('沖銷關係筆不可刪：沖銷筆本身也沒有左滑動作', (tester) async {
    await pumpApp(tester,
        containerFor(repoWith(entries: [reversedOriginal, reversalEntry])));

    expect(find.text('沖銷'), findsWidgets);
    expect(find.byKey(ValueKey('slide-${reversalEntry.id}')), findsNothing);

    await tester.drag(find.textContaining('沖銷 #'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('刪除失敗：toast 錯誤、列表一筆都沒少', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(FailingRepository(
        seed: snapshotWith(entries: [expense(id: 'e-normal-01', note: '刪不掉的買菜', payerId: kMeId)]),
        failRemoveEntry: true,
      )),
    );

    await tester.drag(find.text('刪不掉的買菜'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(entriesProvider).length, 1);
    expect(find.text('刪不掉的買菜'), findsOneWidget);
  });

  // ── 鎖月（v1.4 起，v1.5 沿用）────────────────────────────────────────

  testWidgets('已清帳月份的帳目：左滑沒有編輯／刪除；同一份資料裡未清月的照常', (tester) async {
    final cur = monthOf(DateTime.now());
    final prev = prevMonth(cur);

    await pumpApp(
      tester,
      containerFor(repoWith(
        entries: [
          expense(
              id: 'e-locked-01',
              note: '上月鎖住',
              payerId: kMeId,
              on: DateTime(prev.year, prev.month, 10)),
          expense(
              id: 'e-open-0001',
              note: '本月照常',
              payerId: kMeId,
              on: DateTime(cur.year, cur.month, 10)),
        ],
        closes: [closeFixture(month: prev)],
      )),
    );

    // 本月（未清）：滑得開，編輯／刪除都在。
    expect(find.byKey(const ValueKey('slide-e-open-0001')), findsOneWidget);
    await tester.drag(find.text('本月照常'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // 切到上個月（已清）：整排滑動動作拿掉。
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('上月鎖住'), findsOneWidget);
    expect(find.byKey(const ValueKey('slide-e-locked-01')), findsNothing);
    await tester.drag(find.text('上月鎖住'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  // ── 列表既有行為（篩選／排序／分頁／月份切換）────────────────────────

  testWidgets('分頁：預設建立時間倒序先出 20 筆，滑到底再放 20', (tester) async {
    final now = DateTime.now();
    final entries = [
      for (var i = 0; i < 25; i++)
        Entry(
          id: 'e-page-${i.toString().padLeft(4, '0')}',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          amount: 100 + i,
          categoryId: 'c-food',
          occurredOn: DateTime(now.year, now.month, 1),
          createdBy: kMeId,
          note: '批次 $i',
          payerId: kMeId,
          createdAt: now.subtract(Duration(minutes: i)), // i 越小越新
        ),
    ];
    await pumpApp(tester, containerFor(repoWith(entries: entries)));

    // 先只放行 20 筆：最新的 e-page-0000 在最上，第 21 筆之後連 widget 都還沒放行。
    expect(find.text('批次 0'), findsOneWidget);
    expect(find.text('批次 24'), findsNothing);

    // 滑到底 → NotificationListener 再放 20 筆 → 最後一筆進得來、載入提示消失。
    // 刻意不對「載入更多」提示做可見性斷言：它是清單最後一個 child，要看見它
    // 就一定已經進了「距底部 200px」的觸發區，放行後它自己就消失了（見順路發現）。
    await tester.dragUntilVisible(
        find.text('批次 24'), find.byType(ListView).first, const Offset(0, -400));
    expect(find.text('批次 24'), findsOneWidget);
    expect(find.byKey(const Key('load-more-hint')), findsNothing);
  });

  testWidgets('排序切金額高→低：攤平不分組、大額在上', (tester) async {
    final now = DateTime.now();
    final entries = [
      for (var i = 0; i < 3; i++)
        Entry(
          id: 'e-sort-000$i',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          amount: (i + 1) * 100, // 100/200/300
          categoryId: 'c-food',
          occurredOn: DateTime(now.year, now.month, i + 1),
          createdBy: kMeId,
          note: '排序 $i',
          payerId: kMeId,
          createdAt: now.subtract(Duration(minutes: i)),
        ),
    ];
    await pumpApp(tester, containerFor(repoWith(entries: entries)));

    await tester.tap(find.byKey(const Key('sort-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sort-amount-desc')));
    await tester.pumpAndSettle();

    expect(find.textContaining('小計'), findsNothing);
    final y300 = tester.getTopLeft(find.byKey(const ValueKey('slide-e-sort-0002'))).dy;
    final y100 = tester.getTopLeft(find.byKey(const ValueKey('slide-e-sort-0000'))).dy;
    expect(y300, lessThan(y100));
  });

  testWidgets('分類篩選：選了分類只剩該分類，摘要跟著變', (tester) async {
    final now = DateTime.now();
    final entries = [
      expense(
          id: 'e-filter-01',
          note: '買菜',
          amount: 100,
          payerId: kMeId,
          on: DateTime(now.year, now.month, 1)),
      expense(
          id: 'e-filter-02',
          note: '外食',
          amount: 250,
          categoryId: 'c-dining',
          payerId: kMeId,
          on: DateTime(now.year, now.month, 2)),
    ];
    await pumpApp(tester, containerFor(repoWith(entries: entries)));
    expect(find.text('買菜'), findsOneWidget);
    expect(find.text('外食'), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-category-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-cat-c-dining')));
    await tester.pumpAndSettle();

    expect(find.text('外食'), findsOneWidget);
    expect(find.text('買菜'), findsNothing);
    expect(find.text('250'), findsWidgets);
    expect(find.text('350'), findsNothing);

    await tester.tap(find.descendant(
        of: find.byKey(const Key('filter-category-chip')), matching: find.byType(Icon)));
    await tester.pumpAndSettle();
    expect(find.text('買菜'), findsOneWidget);
  });

  testWidgets('頂部列用共用 MonthAppBar：搜尋在左、齒輪在右、月份標題在中間', (tester) async {
    await pumpApp(tester);
    final bar = find.descendant(of: find.byType(EntriesPage), matching: find.byType(MonthAppBar));
    expect(bar, findsOneWidget);
    for (final f in [
      find.byTooltip('搜尋'),
      find.byTooltip('設定'),
      find.byKey(const Key('month-title')),
    ]) {
      expect(find.descendant(of: bar, matching: f), findsOneWidget);
    }
    expect(
      tester.getCenter(find.descendant(of: bar, matching: find.byTooltip('搜尋'))).dx,
      lessThan(tester.getCenter(find.descendant(of: bar, matching: find.byTooltip('設定'))).dx),
    );
    expect(find.descendant(of: bar, matching: find.byKey(const Key('view-mode-toggle'))), findsNothing);
  });

  testWidgets('月份標題右滑：切到上個月', (tester) async {
    await pumpApp(tester);
    expect(find.text('本月買菜'), findsOneWidget);
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('本月買菜'), findsNothing);
    expect(find.text('上月買菜'), findsOneWidget);
  });

  // ── 版面 ────────────────────────────────────────────────────────────

  testWidgets('390×844 不爆版', (tester) async {
    await pumpApp(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('390×667 不爆版', (tester) async {
    await pumpApp(tester, null, const Size(390, 667));
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色模式：帳目頁正常渲染', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    expect(find.text('本月買菜'), findsOneWidget);
    expect(chipText(tester, 'e-3'), 'Mike');
    expect(tester.takeException(), isNull);
  });
}
