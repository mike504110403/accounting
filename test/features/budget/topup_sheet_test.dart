/// `TopupSheet` 單獨 pump（不經 `TopupSection`／`BudgetPage`）：驗證欄位、驗證失敗、
/// 成功寫入與失敗路徑（`FailingRepository.failAddTopup`）。
library;

import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/features/budget/topup_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month, 1);
  final prevMonthStart = DateTime(now.year, now.month - 1, 1);

  Future<ProviderContainer> pumpSheet(
    WidgetTester tester, {
    required InMemoryLedgerRepository repository,
    DateTime? month,
  }) async {
    final container = ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  useSafeArea: true,
                  isScrollControlled: true,
                  builder: (_) => TopupSheet(month: month ?? thisMonth),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('金額欄、備註欄、「補入」鈕都在', (tester) async {
    await pumpSheet(tester, repository: repoWith(members: const [], topups: const []));

    expect(find.byKey(const Key('topup-amount-field')), findsOneWidget);
    expect(find.byKey(const Key('topup-note-field')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '補入'), findsOneWidget);
  });

  testWidgets('金額空白或 0：顯示「補入金額必須大於 0」且不送出', (tester) async {
    final container = await pumpSheet(tester, repository: repoWith(members: const [], topups: const []));
    final before = container.read(topupsProvider).length;

    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();
    expect(find.text('補入金額必須大於 0'), findsOneWidget);
    expect(find.byKey(const Key('topup-amount-field')), findsOneWidget, reason: 'sheet 不該關掉');

    await tester.enterText(find.byKey(const Key('topup-amount-field')), '0');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();
    expect(find.text('補入金額必須大於 0'), findsOneWidget);
    expect(container.read(topupsProvider).length, before, reason: 'state 不變');
  });

  testWidgets('設定成功（看本月）：topupsProvider 多一筆，memberId／createdBy＝目前成員，occurredOn＝今天', (tester) async {
    final container = await pumpSheet(
      tester,
      repository: repoWith(members: const [], topups: const [], currentMemberId: kMeId),
    );

    await tester.enterText(find.byKey(const Key('topup-amount-field')), '3000');
    await tester.enterText(find.byKey(const Key('topup-note-field')), '加碼補入');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topup-amount-field')), findsNothing, reason: 'sheet 該關閉');
    final added = container.read(topupsProvider).last;
    expect(added.amount, 3000);
    expect(added.memberId, kMeId);
    expect(added.createdBy, kMeId);
    expect(added.note, '加碼補入');
    expect(added.occurredOn, DateTime(now.year, now.month, now.day));
  });

  testWidgets('看過去月（未清）：occurredOn＝該月 1 號', (tester) async {
    final container = await pumpSheet(
      tester,
      repository: repoWith(members: const [], topups: const [], currentMemberId: kMeId),
      month: prevMonthStart,
    );

    await tester.enterText(find.byKey(const Key('topup-amount-field')), '1200');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    final added = container.read(topupsProvider).last;
    expect(added.occurredOn, DateTime(prevMonthStart.year, prevMonthStart.month, 1));
  });

  testWidgets('寫入失敗（FailingRepository.failAddTopup）：sheet 內顯示錯誤、不 pop、state 不變', (tester) async {
    final repo = FailingRepository(
      seed: snapshotWith(members: const [], topups: const []),
      failAddTopup: true,
    );
    final container = await pumpSheet(tester, repository: repo);
    final before = container.read(topupsProvider).length;

    await tester.enterText(find.byKey(const Key('topup-amount-field')), '500');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topup-amount-field')), findsOneWidget, reason: 'sheet 仍開著');
    expect(find.text('boom'), findsOneWidget, reason: 'FailingRepository 丟 LedgerException("boom")，直接顯示 e.message');
    expect(find.text('處理中…'), findsNothing, reason: '_saving 要解除');
    expect(container.read(topupsProvider).length, before, reason: '失敗不留半套狀態');
    final btn = tester.widget<FilledButton>(find.byKey(const Key('topup-submit-btn')));
    expect(btn.onPressed, isNotNull, reason: '失敗後應可重試');
  });

  testWidgets('已清帳月（資料異常防線）：sheet 內顯示含「已清帳」', (tester) async {
    // 正常路徑下 TopupSection 的鈕會先被停用擋掉；這裡直接對已清月開 sheet，
    // 驗證 repository 的鎖月 trigger 仍是最後防線。
    final repo = InMemoryLedgerRepository(
      seed: snapshotWith(members: const [], topups: const []).copyWith(closes: [closeFixture(month: thisMonth)]),
    );
    final container = await pumpSheet(tester, repository: repo);
    final before = container.read(topupsProvider).length;

    await tester.enterText(find.byKey(const Key('topup-amount-field')), '500');
    await tester.tap(find.byKey(const Key('topup-submit-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topup-amount-field')), findsOneWidget, reason: 'sheet 仍開著，不 pop');
    expect(find.textContaining('已清帳'), findsOneWidget);
    expect(container.read(topupsProvider).length, before);
  });
}
