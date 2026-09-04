import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/app/month_app_bar.dart';
import 'package:accounting/features/entries/entries_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// 三人帳本、還有兩個人要簽的 pending settlement（我只是其中一個簽核人）。
final twoSignerSettlement = Settlement(
  id: 's-multi',
  ledgerId: kLedgerId,
  status: SettlementStatus.pending,
  initiatedBy: kWifeId,
  createdAt: DateTime.now(),
  nets: const {kMeId: -300, kWifeId: 500, 'm-kid': -200},
  entryIds: const ['e-6'],
  approvedBy: const {},
);

final kidMember = Member(id: 'm-kid', ledgerId: kLedgerId, userId: 'u3', displayName: '小孩', joinedAt: DateTime(1970));

/// 兩筆互相抵銷的代墊：淨額全為 0。
List<Entry> balancedEntries() => [
      Entry(
        id: 'e-a',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: 'Mike 代墊',
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
        splits: const [
          EntrySplit(entryId: 'e-a', memberId: kMeId, share: 500),
          EntrySplit(entryId: 'e-a', memberId: kWifeId, share: 500),
        ],
      ),
      Entry(
        id: 'e-b',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kWifeId,
        note: '老婆代墊',
        payerId: kWifeId,
        splitMethod: SplitMethod.equal,
        splits: const [
          EntrySplit(entryId: 'e-b', memberId: kMeId, share: 500),
          EntrySplit(entryId: 'e-b', memberId: kWifeId, share: 500),
        ],
      ),
    ];

/// 只有發起人淨額非零（分攤沒攤到別人）→ 沒有人需要簽。
List<Entry> soloNetEntries() => [
      Entry(
        id: 'e-solo',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '只有我有淨額',
        payerId: kMeId,
        splitMethod: SplitMethod.amount,
        splits: const [EntrySplit(entryId: 'e-solo', memberId: kMeId, share: 500)],
      ),
    ];

/// 把資料層換成指定內容的記憶體 repository（Notifier 的初值與寫入都吃它）。
ProviderContainer containerFor(LedgerRepository repo) =>
    ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);

/// 帳目頁的共用視角切換（避開統計頁同名元件）。
Finder viewMode(String label) => find.descendant(
      of: find.descendant(of: find.byType(EntriesPage), matching: find.byKey(const Key('view-mode-toggle'))),
      matching: find.text(label),
    );

Future<ProviderContainer> pumpApp(WidgetTester tester, [ProviderContainer? container]) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = container ?? ProviderContainer();
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AccountingApp()));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('根啟動＋切 Tab 回帳目：看得到列表與假資料', (tester) async {
    await pumpApp(tester);
    expect(find.text('菜市場'), findsOneWidget);

    await tester.tap(find.text('統計'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('帳目'));
    await tester.pumpAndSettle();

    // 往下捲到月初的資料
    await tester.dragUntilVisible(find.text('全聯買菜'), find.byType(ListView).first, const Offset(0, -120));
    expect(find.text('全聯買菜'), findsOneWidget);
    await tester.dragUntilVisible(find.text('房租'), find.byType(ListView).first, const Offset(0, -120));
    expect(find.text('房租'), findsOneWidget);
  });

  testWidgets('列左滑顯示編輯／刪除：刪除經確認框後從列表與 provider 移除', (tester) async {
    final container = await pumpApp(tester);
    expect(find.text('菜市場'), findsOneWidget);

    await tester.drag(find.text('菜市場'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    // 圓形 icon、無文字（2026-09-03）。
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('刪除這筆帳目？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();

    expect(find.text('菜市場'), findsNothing);
    expect(container.read(entriesProvider).any((e) => e.note == '菜市場'), isFalse);
  });

  testWidgets('視角切換：家庭看不到私人、個人看得到自己的私人', (tester) async {
    await pumpApp(tester);
    expect(find.text('Steam'), findsNothing);

    await tester.tap(viewMode('個人'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.text('Steam'), find.byType(ListView).first, const Offset(0, -120));
    expect(find.text('Steam'), findsOneWidget);
  });

  testWidgets('個人視角只列私人帳：共同筆不出現（份額歸統計頁）', (tester) async {
    await pumpApp(tester);
    await tester.tap(viewMode('個人'));
    await tester.pumpAndSettle();

    expect(find.text('全聯買菜'), findsNothing, reason: '共同支出不進個人分頁（2026-09-04 裁示）');
    await tester.dragUntilVisible(find.text('Steam'), find.byType(ListView).first, const Offset(0, -120));
    expect(find.text('Steam'), findsOneWidget, reason: '自己的私人帳全額顯示');
  });

  testWidgets('分頁：預設建立時間倒序先出 20 筆，滑到底再放 20', (tester) async {
    final now = DateTime.now();
    final entries = [
      for (var i = 0; i < 25; i++)
        Entry(
          id: 'e-p$i',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 100 + i,
          categoryId: 'c-food',
          occurredOn: DateTime(now.year, now.month, 1),
          createdBy: kMeId,
          note: '批次 $i',
          splitMethod: SplitMethod.common,
          createdAt: now.subtract(Duration(minutes: i)), // i 越小越新
        ),
    ];
    await pumpApp(tester, containerFor(repoWith(entries: entries, settlements: const [])));

    // 先只渲染 20 筆：最新的 e-p0 在最上、e-p24 連 widget 都還沒放行。
    expect(find.text('批次 0'), findsOneWidget);
    expect(find.byKey(const ValueKey('slide-e-p24')), findsNothing);
    await tester.dragUntilVisible(
        find.byKey(const Key('load-more-hint')), find.byType(ListView).first, const Offset(0, -400));
    expect(find.textContaining('20/25'), findsOneWidget);

    // 再往下滑觸發載入，最後一筆出現。
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
          id: 'e-s$i',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: (i + 1) * 100, // 100/200/300
          categoryId: 'c-food',
          occurredOn: DateTime(now.year, now.month, i + 1),
          createdBy: kMeId,
          note: '排序 $i',
          splitMethod: SplitMethod.common,
          createdAt: now.subtract(Duration(minutes: i)),
        ),
    ];
    await pumpApp(tester, containerFor(repoWith(entries: entries, settlements: const [])));

    await tester.tap(find.byKey(const Key('sort-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sort-amount-desc')));
    await tester.pumpAndSettle();

    // 金額排序：沒有日期小標（攤平），且 300 在 100 上面。
    expect(find.textContaining('小計'), findsNothing);
    final y300 = tester.getTopLeft(find.byKey(const ValueKey('slide-e-s2'))).dy;
    final y100 = tester.getTopLeft(find.byKey(const ValueKey('slide-e-s0'))).dy;
    expect(y300, lessThan(y100));
  });

  testWidgets('分類篩選：選了分類只剩該分類，摘要跟著變', (tester) async {
    final now = DateTime.now();
    final entries = [
      Entry(id: 'e-f1', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 100, categoryId: 'c-food', occurredOn: DateTime(now.year, now.month, 1), createdBy: kMeId, note: '買菜', splitMethod: SplitMethod.common),
      Entry(id: 'e-f2', ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 250, categoryId: 'c-dining', occurredOn: DateTime(now.year, now.month, 2), createdBy: kMeId, note: '外食', splitMethod: SplitMethod.common),
    ];
    await pumpApp(tester, containerFor(repoWith(entries: entries, settlements: const [])));
    expect(find.text('買菜'), findsOneWidget);
    expect(find.text('外食'), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-category-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-cat-c-dining')));
    await tester.pumpAndSettle();

    expect(find.text('外食'), findsOneWidget);
    expect(find.text('買菜'), findsNothing);
    // 摘要吃篩選結果：支出只剩 250。
    expect(find.text('250'), findsWidgets);
    expect(find.text('350'), findsNothing);

    // 清掉篩選（chip 的 x）回全部。
    await tester.tap(find.descendant(
        of: find.byKey(const Key('filter-category-chip')), matching: find.byType(Icon)));
    await tester.pumpAndSettle();
    expect(find.text('買菜'), findsOneWidget);
  });

  testWidgets('待簽核卡片：同意 → settlement settled、涵蓋 entries settled', (tester) async {
    final container = await pumpApp(tester);
    expect(find.textContaining('待你簽核'), findsOneWidget);
    expect(find.textContaining('應付 430'), findsOneWidget);

    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();

    final s = container.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.settled);
    expect(s.approvedBy, contains(kMeId));
    expect(s.settledAt, isNotNull);
    final entries = container.read(entriesProvider);
    for (final id in const ['e-6', 'e-7', 'e-9', 'e-10']) {
      expect(entries.firstWhere((e) => e.id == id).settledState, SettledState.settled);
    }
  });

  testWidgets('多簽：還有人沒簽時只累加 approvedBy，不落 settled', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(repoWith(
        members: [
          Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: DateTime(1970)),
          Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: DateTime(1970)),
          kidMember,
        ],
        settlements: [twoSignerSettlement],
      )),
    );

    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();

    final s = c.read(settlementsProvider).single;
    expect(s.requiredSigners, {kMeId, 'm-kid'});
    expect(s.approvedBy, {kMeId});
    expect(s.status, SettlementStatus.pending, reason: '小孩還沒簽');
    expect(s.settledAt, isNull);
    expect(c.read(entriesProvider).firstWhere((e) => e.id == 'e-6').settledState, SettledState.settling);
    expect(find.textContaining('簽核 1/2'), findsOneWidget);
  });

  testWidgets('簽核失敗：settlement 與 entries 都不動，並顯示錯誤', (tester) async {
    // 原子性由 `approve_settlement` RPC 保證（簽名與落 settled 在同一交易），
    // 前端沒有補償段可寫——要驗的是「失敗時前端狀態一格都沒動」。
    final c = await pumpApp(tester, containerFor(FailingRepository(failApproveSettlement: true)));
    final before = {for (final e in c.read(entriesProvider)) e.id: e.settledState};

    await tester.tap(find.text('同意'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('boom'), findsOneWidget);

    final s = c.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.pending);
    expect(s.approvedBy, isEmpty);
    expect(s.settledAt, isNull);
    for (final e in c.read(entriesProvider)) {
      expect(e.settledState, before[e.id], reason: e.id);
    }
  });

  testWidgets('沒有 pending 時顯示發起結算，發起後涵蓋 entries 轉 settling', (tester) async {
    final container = await pumpApp(tester, containerFor(repoWith(settlements: const [])));
    expect(find.textContaining('代墊淨額 +284'), findsOneWidget);

    await tester.tap(find.text('發起'));
    await tester.pumpAndSettle();

    final s = container.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.pending);
    expect(s.initiatedBy, kMeId);
    expect(s.nets[kMeId], 284);
    expect(s.nets[kWifeId], -284);
    expect(s.entryIds, const ['e-5']);
    final entries = container.read(entriesProvider);
    for (final id in s.entryIds) {
      expect(entries.firstWhere((e) => e.id == id).settledState, SettledState.settling);
    }
  });

  testWidgets('發起結算失敗：顯示錯誤，settlement 沒建、entries 仍是 open', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(FailingRepository(
        seed: snapshotWith(settlements: const []),
        failInitiateSettlement: true,
      )),
    );
    await tester.tap(find.text('發起'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(settlementsProvider), isEmpty);
    expect(c.read(entriesProvider).firstWhere((e) => e.id == 'e-5').settledState, SettledState.open);
  });

  testWidgets('淨額全為零：顯示已平衡且沒有發起結算按鈕', (tester) async {
    await pumpApp(
      tester,
      containerFor(repoWith(entries: balancedEntries(), settlements: const [])),
    );
    expect(find.text('目前已平衡'), findsOneWidget);
    expect(find.text('發起'), findsNothing);
  });

  testWidgets('沒有人需要簽時發起即成立：settlement 與 entries 直接 settled', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(repoWith(entries: soloNetEntries(), settlements: const [])),
    );
    await tester.tap(find.text('發起'));
    await tester.pumpAndSettle();

    final s = c.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.settled);
    expect(s.settledAt, isNotNull);
    expect(s.requiredSigners, isEmpty);
    expect(c.read(entriesProvider).single.settledState, SettledState.settled);
  });

  testWidgets('結算卡片維持單行小卡：高度 ≤ 72', (tester) async {
    await pumpApp(tester);
    expect(tester.getSize(find.byKey(const Key('settlement-card'))).height, lessThanOrEqualTo(72));

    // 沒有 pending 的「代墊淨額」卡同樣要小
    await pumpApp(tester, containerFor(repoWith(settlements: const [])));
    expect(tester.getSize(find.byKey(const Key('settlement-card'))).height, lessThanOrEqualTo(72));
  });

  testWidgets('頂部列用共用 MonthAppBar：搜尋在左、齒輪在右、月份與視角切換都在裡面', (tester) async {
    await pumpApp(tester);
    final bar = find.descendant(of: find.byType(EntriesPage), matching: find.byType(MonthAppBar));
    expect(bar, findsOneWidget);
    for (final f in [
      find.byTooltip('搜尋'),
      find.byTooltip('設定'),
      find.byKey(const Key('month-title')),
      find.byKey(const Key('view-mode-toggle')),
    ]) {
      expect(find.descendant(of: bar, matching: f), findsOneWidget);
    }
    // 搜尋在左角、齒輪在右角
    expect(
      tester.getCenter(find.descendant(of: bar, matching: find.byTooltip('搜尋'))).dx,
      lessThan(tester.getCenter(find.descendant(of: bar, matching: find.byTooltip('設定'))).dx),
    );
    expect(viewMode('家庭'), findsOneWidget);
    expect(viewMode('個人'), findsOneWidget);
  });

  testWidgets('深色模式：帳目頁正常渲染', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    expect(find.text('菜市場'), findsOneWidget);
    expect(find.textContaining('待你簽核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('月份標題右滑：切到上個月', (tester) async {
    await pumpApp(tester);
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('全聯買菜'), findsNothing);
    expect(find.text('整月買菜'), findsOneWidget);
  });

  testWidgets('點月份標題開底部滾輪，選「本月」回到本月', (tester) async {
    await pumpApp(tester);
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('整月買菜'), findsOneWidget);

    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);
    // 篩選列的「本月」chip 與滾輪的「本月」鈕同字，改用 key 點滾輪那顆。
    await tester.tap(find.byKey(const Key('month-picker-today')));
    await tester.pumpAndSettle();
    expect(find.text('菜市場'), findsOneWidget);
  });

  // ── 鎖月（v1.4／ADR-0008）────────────────────────────────────────────

  testWidgets('已清帳月份的帳目：左滑沒有編輯／刪除；同一份資料裡未清月的照常', (tester) async {
    final cur = monthOf(DateTime.now());
    final prev = prevMonth(cur);
    // 共同錢包支出：家庭視角（列表預設）看得到，也不牽扯結算與分攤。
    Entry wallet(String id, String note, DateTime on) => Entry(
          id: id,
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 300,
          categoryId: 'c-food',
          occurredOn: on,
          createdBy: kMeId,
          note: note,
        );

    await pumpApp(
      tester,
      containerFor(repoWith(
        entries: [
          wallet('e-locked', '上月鎖住', DateTime(prev.year, prev.month, 10)),
          wallet('e-open', '本月照常', DateTime(cur.year, cur.month, 10)),
        ],
        settlements: const [],
        closes: [closeFixture(month: prev)],
      )),
    );

    // 本月（未清）：滑得開，編輯／刪除都在。
    expect(find.byKey(const ValueKey('slide-e-open')), findsOneWidget);
    await tester.drag(find.text('本月照常'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // 切到上個月（已清）：整排滑動動作拿掉。
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('上月鎖住'), findsOneWidget);
    expect(find.byKey(const ValueKey('slide-e-locked')), findsNothing);
    await tester.drag(find.text('上月鎖住'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
