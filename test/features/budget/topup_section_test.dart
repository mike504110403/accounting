/// `TopupSection`（v1.5／ADR-0009 個人補入區塊）單獨 pump：成員列數字、只有自己有
/// 「補入」鈕、展開明細與刪除、已清月／未來月鈕停用、複製上月。
///
/// 真組裝：只 override `ledgerRepositoryProvider`，其餘 provider 走真的
/// `snapshotProvider` 重算路徑；`TopupSheet` 的欄位／驗證/失敗路徑在
/// `topup_sheet_test.dart` 單獨測，這裡只驗證「開得起來、送出後區塊數字更新」。
library;

import 'dart:async';

import 'package:accounting/app/format.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/budget/topup_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month, 1);
  final prevMonthStart = DateTime(now.year, now.month - 1, 1);
  final nextMonthStart = DateTime(now.year, now.month + 1, 1);
  DateTime day(int d) => DateTime(now.year, now.month, d);

  Future<ProviderContainer> pumpSection(
    WidgetTester tester, {
    required InMemoryLedgerRepository repository,
    DateTime? month,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TopupSection(month: month ?? thisMonth))),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Finder inRow(String memberId, Finder f) =>
      find.descendant(of: find.byKey(ValueKey('topup-row-$memberId')), matching: f);

  // ── 驗收 2：兩列數字＋只有自己有補入鈕 ───────────────────────────────────

  testWidgets('個人補入區塊兩列：Mike 10,000／6,000／4,000，老婆 10,000／2,000／8,000；只有自己那列有補入鈕', (tester) async {
    await pumpSection(tester, repository: InMemoryLedgerRepository());

    expect(find.text('個人補入'), findsOneWidget);
    expect(inRow(kMeId, find.text('Mike')), findsOneWidget);
    expect(inRow(kMeId, find.text(fmtAmount(10000))), findsOneWidget, reason: 'Mike 本月補入合計');
    expect(inRow(kMeId, find.text(fmtAmount(6000))), findsOneWidget, reason: 'Mike 本月先付');
    expect(inRow(kMeId, find.text(fmtAmount(4000))), findsOneWidget, reason: 'Mike 剩餘');

    expect(inRow(kWifeId, find.text('老婆')), findsOneWidget);
    expect(inRow(kWifeId, find.text(fmtAmount(10000))), findsOneWidget, reason: '老婆本月補入合計');
    expect(inRow(kWifeId, find.text(fmtAmount(2000))), findsOneWidget, reason: '老婆本月先付');
    expect(inRow(kWifeId, find.text(fmtAmount(8000))), findsOneWidget, reason: '老婆剩餘');

    expect(find.byKey(const Key('topup-add-btn')), findsOneWidget, reason: '只有一顆補入鈕（自己那列）');
    expect(inRow(kMeId, find.byKey(const Key('topup-add-btn'))), findsOneWidget);
    expect(inRow(kWifeId, find.byKey(const Key('topup-add-btn'))), findsNothing);
  });

  // ── 驗收 3：補入成功／驗證失敗／寫入失敗 ─────────────────────────────────

  testWidgets('補入 3,000：區塊 Mike 列變 13,000／6,000／7,000、topupsProvider 多一筆', (tester) async {
    final container = await pumpSection(tester, repository: InMemoryLedgerRepository());

    await tester.tap(find.byKey(const Key('topup-add-btn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('topup-amount-field')), '3000');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topup-amount-field')), findsNothing, reason: 'sheet 該關閉');
    expect(inRow(kMeId, find.text(fmtAmount(13000))), findsOneWidget);
    expect(inRow(kMeId, find.text(fmtAmount(7000))), findsOneWidget, reason: '剩餘 13,000 − 6,000');
    expect(container.read(topupsProvider).where((t) => t.memberId == kMeId && sameMonth(t.occurredOn, thisMonth)).length, 2);
  });

  testWidgets('金額 0：sheet 內「補入金額必須大於 0」，sheet 不關、區塊數字不變', (tester) async {
    final container = await pumpSection(tester, repository: InMemoryLedgerRepository());
    final before = container.read(topupsProvider).length;

    await tester.tap(find.byKey(const Key('topup-add-btn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('topup-amount-field')), '0');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    expect(find.text('補入金額必須大於 0'), findsOneWidget);
    expect(find.byKey(const Key('topup-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');
    expect(container.read(topupsProvider).length, before);
  });

  testWidgets('補入失敗（failAddTopup）：sheet 內錯誤、state 不變', (tester) async {
    final repo = FailingRepository(seed: InMemoryLedgerRepository().snapshot, failAddTopup: true);
    final container = await pumpSection(tester, repository: repo);
    final before = container.read(topupsProvider).length;

    await tester.tap(find.byKey(const Key('topup-add-btn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('topup-amount-field')), '500');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topup-amount-field')), findsOneWidget, reason: 'sheet 仍開著');
    expect(find.text('boom'), findsOneWidget);
    expect(container.read(topupsProvider).length, before);
  });

  // ── 驗收 4：展開明細／刪除／已清月無刪除入口 ─────────────────────────────

  testWidgets('展開 Mike 列：列出本月每筆補入；刪除一筆（二次確認）→ 合計更新', (tester) async {
    final container = await pumpSection(tester, repository: InMemoryLedgerRepository());

    await tester.tap(inRow(kMeId, find.text('Mike')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topup-item-pt-1')), findsOneWidget, reason: '本月補入那一筆（seed pt-1）');
    expect(find.text('本月補入'), findsOneWidget, reason: '備註');

    await tester.tap(find.byKey(const Key('topup-delete-pt-1')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: '二次確認');
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();

    expect(container.read(topupsProvider).any((t) => t.id == 'pt-1'), isFalse);
    expect(inRow(kMeId, find.text(fmtAmount(0))), findsOneWidget, reason: '補入合計歸零');
    expect(inRow(kMeId, find.text(fmtAmount(-6000))), findsOneWidget, reason: '剩餘 0 − 6,000');
  });

  testWidgets('二次確認取消：不刪除，資料不變', (tester) async {
    final container = await pumpSection(tester, repository: InMemoryLedgerRepository());
    final before = container.read(topupsProvider).length;

    await tester.tap(inRow(kMeId, find.text('Mike')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('topup-delete-pt-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(container.read(topupsProvider).length, before);
    expect(find.byKey(const Key('topup-item-pt-1')), findsOneWidget);
  });

  testWidgets('刪除補入進行中鈕停用防連按；失敗後 SnackBar 顯示錯誤、解除停用可重試、state 不變', (tester) async {
    final repo = _ControlledFailingRemoveRepository(seed: InMemoryLedgerRepository().snapshot);
    final container = await pumpSection(tester, repository: repo);
    final before = container.read(topupsProvider).length;

    await tester.tap(inRow(kMeId, find.text('Mike')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('topup-delete-pt-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    // 不用 pumpAndSettle：`removeTopup` 卡在 `_gate`，要先驗證「進行中」那個瞬間的鈕狀態。
    await tester.pumpAndSettle();

    final duringBtn = tester.widget<IconButton>(find.byKey(const Key('topup-delete-pt-1')));
    expect(duringBtn.onPressed, isNull, reason: '刪除進行中鈕應停用，避免連按送出兩次刪除');

    repo.release();
    await tester.pumpAndSettle();

    expect(find.text('boom'), findsOneWidget, reason: 'FailingRepository 丟 LedgerException("boom")，SnackBar 顯示 e.message');
    expect(container.read(topupsProvider).length, before, reason: 'state 不變，沒有半套資料');
    expect(find.byKey(const Key('topup-item-pt-1')), findsOneWidget, reason: '刪除失敗，明細那筆還在');
    final afterBtn = tester.widget<IconButton>(find.byKey(const Key('topup-delete-pt-1')));
    expect(afterBtn.onPressed, isNotNull, reason: '失敗後解除停用，應可重試');
  });

  testWidgets('複製上月寫入失敗（failAddTopup）：SnackBar 顯示錯誤、_copying 解除、state 不變', (tester) async {
    final topups = [topupFixture(memberId: kMeId, amount: 5000, occurredOn: prevMonthStart, note: '上月補入')];
    final members = [
      Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: prevMonthStart),
    ];
    final repo = FailingRepository(
      seed: snapshotWith(members: members, topups: topups, entries: const []),
      failAddTopup: true,
    );
    final container = await pumpSection(tester, repository: repo);
    final before = container.read(topupsProvider).length;

    final copyBtn = find.byKey(ValueKey('topup-copy-last-month-btn-$kMeId'));
    expect(copyBtn, findsOneWidget);
    await tester.tap(copyBtn);
    await tester.pumpAndSettle();

    expect(find.text('boom'), findsOneWidget, reason: 'FailingRepository 丟 LedgerException("boom")，SnackBar 顯示 e.message');
    expect(container.read(topupsProvider).length, before, reason: 'state 不變，沒有半套資料');
    expect(inRow(kMeId, find.text('複製上月 ${fmtAmount(5000)} 元')), findsOneWidget, reason: '複製失敗，提示還在');
    final btn = tester.widget<FilledButton>(copyBtn);
    expect(btn.onPressed, isNotNull, reason: '_copying 已解除，鈕可以再按一次重試');
  });

  testWidgets('剩餘為負：文字用 error 色', (tester) async {
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 9000, categoryId: 'c-food', occurredOn: day(4), createdBy: kMeId, payerId: kMeId),
    ];
    final topups = [topupFixture(memberId: kMeId, amount: 4000, occurredOn: thisMonth)];
    final members = [Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: thisMonth)];
    await pumpSection(tester, repository: repoWith(members: members, entries: entries, topups: topups, currentMemberId: kMeId));

    final remainingFinder = inRow(kMeId, find.text(fmtAmount(-5000)));
    expect(remainingFinder, findsOneWidget, reason: '剩餘 4,000－9,000＝－5,000');
    final scheme = Theme.of(tester.element(find.byType(TopupSection))).colorScheme;
    expect(tester.widget<Text>(remainingFinder).style?.color, scheme.error);
  });

  // ── 變異證明（b）：補入鈕對已清月沒停用 ──────────────────────────────────
  //
  // 若有人漏掉 `isMonthClosed` 判斷，下面這條測試會抓到：鈕仍是 enabled、
  // 「該月已清帳」文字不會出現、明細仍給得出刪除鈕——三個斷言只要有一個變了就是紅的。

  testWidgets('已清月：補入鈕停用並顯示「該月已清帳」，展開明細無刪除入口', (tester) async {
    final closes = [closeFixture(month: thisMonth)];
    final repo = InMemoryLedgerRepository(seed: InMemoryLedgerRepository().snapshot.copyWith(closes: closes));
    await pumpSection(tester, repository: repo);

    final btn = tester.widget<FilledButton>(find.byKey(const Key('topup-add-btn')));
    expect(btn.onPressed, isNull);
    expect(inRow(kMeId, find.text('該月已清帳')), findsOneWidget);

    await tester.tap(inRow(kMeId, find.text('Mike')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('topup-item-pt-1')), findsOneWidget, reason: '明細仍列出，只是不給刪除入口');
    expect(find.byKey(const Key('topup-delete-pt-1')), findsNothing);
  });

  // ── 驗收 5：未來月鈕停用／過去未清月可補 ─────────────────────────────────

  testWidgets('切到下月：補入鈕停用「尚未到該月」', (tester) async {
    await pumpSection(tester, repository: InMemoryLedgerRepository(), month: nextMonthStart);

    final btn = tester.widget<FilledButton>(find.byKey(const Key('topup-add-btn')));
    expect(btn.onPressed, isNull);
    expect(inRow(kMeId, find.text('尚未到該月')), findsOneWidget);
  });

  testWidgets('切到上月（未清）：可補（鈕 enabled）', (tester) async {
    await pumpSection(tester, repository: InMemoryLedgerRepository(), month: prevMonthStart);

    final btn = tester.widget<FilledButton>(find.byKey(const Key('topup-add-btn')));
    expect(btn.onPressed, isNotNull);
  });

  // ── 驗收 6／變異證明（c）：複製上月 ──────────────────────────────────────

  testWidgets('複製上月：本月無補入、上月有 5,000 → 提示出現；按下 → 本月多一筆 5,000', (tester) async {
    final topups = [topupFixture(memberId: kMeId, amount: 5000, occurredOn: prevMonthStart, note: '上月補入')];
    final members = [
      Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: prevMonthStart),
    ];
    final container = await pumpSection(
      tester,
      repository: repoWith(members: members, topups: topups, entries: const [], currentMemberId: kMeId),
    );

    expect(inRow(kMeId, find.text('複製上月 ${fmtAmount(5000)} 元')), findsOneWidget);
    final copyBtn = find.byKey(ValueKey('topup-copy-last-month-btn-$kMeId'));
    expect(copyBtn, findsOneWidget);

    await tester.tap(copyBtn);
    await tester.pumpAndSettle();

    final thisMonthTopups = container.read(topupsProvider).where((t) => sameMonth(t.occurredOn, thisMonth) && t.memberId == kMeId);
    expect(thisMonthTopups.length, 1);
    expect(thisMonthTopups.single.amount, 5000);
    expect(thisMonthTopups.single.note, '複製上月');
    expect(inRow(kMeId, find.text('複製上月 ${fmtAmount(5000)} 元')), findsNothing, reason: '複製完提示消失');
  });

  testWidgets('本月已有補入時複製上月提示不出現（變異證明 c）', (tester) async {
    // 若有人漏掉「本月已有補入」的判斷，這條會抓到：即使上月有 5,000，提示仍不該畫出來。
    final topups = [
      topupFixture(memberId: kMeId, amount: 2000, occurredOn: thisMonth, note: '本月已補'),
      topupFixture(memberId: kMeId, amount: 5000, occurredOn: prevMonthStart, note: '上月補入'),
    ];
    final members = [
      Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: prevMonthStart),
    ];
    await pumpSection(tester, repository: repoWith(members: members, topups: topups, entries: const [], currentMemberId: kMeId));

    expect(find.textContaining('複製上月'), findsNothing);
    expect(find.byKey(ValueKey('topup-copy-last-month-btn-$kMeId')), findsNothing);
  });

  // ── 變異證明（a）：「先付」誤用共同錢包支出 ──────────────────────────────

  testWidgets('先付只計成員自己付的支出，不含共同錢包付（變異證明 a）', (tester) async {
    // 若有人把 `paidIn` 誤寫成連 `payerId == null`（共同錢包）也一起加，
    // Mike 那列「先付」會變成 9,999 + 1,234，這條測試會抓到（斷言的是精確 1,234）。
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 9999, categoryId: 'c-util', occurredOn: day(3), createdBy: kMeId),
      Entry(id: 'e-2', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1234, categoryId: 'c-food', occurredOn: day(5), createdBy: kMeId, payerId: kMeId),
    ];
    final topups = [topupFixture(memberId: kMeId, amount: 5000, occurredOn: thisMonth)];
    final members = [Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: thisMonth)];
    await pumpSection(tester, repository: repoWith(members: members, entries: entries, topups: topups, currentMemberId: kMeId));

    expect(inRow(kMeId, find.text(fmtAmount(1234))), findsOneWidget, reason: '先付只有成員自己那筆 1,234');
    expect(inRow(kMeId, find.text(fmtAmount(9999))), findsNothing, reason: '共同錢包付的 9,999 不該算進先付');
  });

  testWidgets('monthSummary 尚未回應：member 列吃 balance_math 本地公式 fallback', (tester) async {
    final topups = [topupFixture(memberId: kMeId, amount: 4000, occurredOn: thisMonth)];
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1500, categoryId: 'c-food', occurredOn: day(4), createdBy: kMeId, payerId: kMeId),
    ];
    final members = [Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: thisMonth)];
    final repo = NeverRespondingMonthSummaryRepository(
      seed: snapshotWith(members: members, entries: entries, topups: topups),
    );
    await pumpSection(tester, repository: repo);

    expect(inRow(kMeId, find.text(fmtAmount(4000))), findsOneWidget, reason: '補入合計本地手算');
    expect(inRow(kMeId, find.text(fmtAmount(1500))), findsOneWidget, reason: '先付本地手算');
    expect(inRow(kMeId, find.text(fmtAmount(2500))), findsOneWidget, reason: '剩餘 4,000－1,500＝2,500 本地手算');
  });

  // ── server 值與 balance_math 現算一致（seam 兩擇一時的一致性驗證）───────

  testWidgets('server（monthSummary）與 balance_math 現算的補入／先付／剩餘一致', (tester) async {
    final topups = [
      topupFixture(memberId: kMeId, amount: 4000, occurredOn: thisMonth),
      topupFixture(memberId: kMeId, amount: 1000, occurredOn: thisMonth),
    ];
    final entries = [
      Entry(id: 'e-1', ledgerId: kLedgerId, kind: EntryKind.expense, amount: 800, categoryId: 'c-food', occurredOn: day(4), createdBy: kMeId, payerId: kMeId),
    ];
    final members = [Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: thisMonth)];
    await pumpSection(tester, repository: repoWith(members: members, entries: entries, topups: topups, currentMemberId: kMeId));

    final expectedTopup = topupIn(topups: topups, memberId: kMeId, month: thisMonth);
    final expectedPaid = paidIn(entries: entries, memberId: kMeId, month: thisMonth);
    final expectedRemaining = topupRemaining(topups: topups, entries: entries, memberId: kMeId, month: thisMonth);
    expect(expectedTopup, 5000);
    expect(expectedPaid, 800);
    expect(expectedRemaining, 4200);

    expect(inRow(kMeId, find.text(fmtAmount(expectedTopup))), findsOneWidget);
    expect(inRow(kMeId, find.text(fmtAmount(expectedPaid))), findsOneWidget);
    expect(inRow(kMeId, find.text(fmtAmount(expectedRemaining))), findsOneWidget);
  });

  // ── 版面 ──────────────────────────────────────────────────────────────

  testWidgets('390×667：展開明細＋複製上月提示同時出現不爆版', (tester) async {
    final topups = [topupFixture(memberId: kMeId, amount: 5000, occurredOn: prevMonthStart, note: '上月補入補入補入補入補入')];
    final members = [Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: prevMonthStart)];
    await pumpSection(
      tester,
      repository: repoWith(members: members, topups: topups, entries: const [], currentMemberId: kMeId),
      size: const Size(390, 667),
    );
    await tester.tap(inRow(kMeId, find.text('Mike')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

/// `removeTopup` 卡在 [_gate] 直到 [release]，之後才丟 `LedgerException('boom')`。
/// 給「刪除進行中鈕停用、失敗後解除可重試」那條測試控制時機用——沒有這個中繼點，
/// `onPressed isNotNull` 只能驗到「操作結束後」，驗不到「操作進行中」那個真正要守的狀態。
class _ControlledFailingRemoveRepository extends InMemoryLedgerRepository {
  _ControlledFailingRemoveRepository({super.seed});
  final Completer<void> _gate = Completer<void>();

  @override
  Future<void> removeTopup(String id) async {
    await _gate.future;
    throw const LedgerException('boom');
  }

  void release() => _gate.complete();
}
