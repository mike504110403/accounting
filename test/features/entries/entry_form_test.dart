import 'package:accounting/app/router.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// add 一律丟例外，用來驗儲存失敗路徑。
class ThrowingEntries extends EntriesNotifier {
  @override
  void add(Entry e) => throw Exception('boom');
}

/// 只有一筆已結帳的支出。
class SettledOnlyEntries extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-locked',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 1000,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: '已結帳的買菜',
          payerId: kMeId,
          splitMethod: SplitMethod.equal,
          settledState: SettledState.settled,
          splits: const [
            EntrySplit(entryId: 'e-locked', memberId: kMeId, share: 500),
            EntrySplit(entryId: 'e-locked', memberId: kWifeId, share: 500),
          ],
        ),
      ];
}

/// 只有一筆可刪的支出。
class OneOpenEntry extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-open',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 300,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: '可刪的買菜',
        ),
      ];
}

/// 更新一律丟例外（配一筆可編輯的支出）。
class ThrowingUpdateEntries extends OneOpenEntry {
  @override
  void update(Entry e) => throw Exception('boom');
}

/// 刪除一律丟例外（配一筆可刪的支出）。
class ThrowingRemoveEntries extends OneOpenEntry {
  @override
  void remove(String id) => throw Exception('boom');
}

/// 一筆已結帳、用「金額」分攤且份額帶小數的支出：
/// 手填欄位只能顯示整數（284），沒有防禦層就會把 283.5 覆寫掉或被合計檢查擋存。
class SettledAmountSplitEntries extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-amt',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 567,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: '已結帳的金額分攤',
          payerId: kMeId,
          splitMethod: SplitMethod.amount,
          settledState: SettledState.settled,
          splits: const [
            EntrySplit(entryId: 'e-amt', memberId: kMeId, share: 283.5),
            EntrySplit(entryId: 'e-amt', memberId: kWifeId, share: 283.5),
          ],
        ),
      ];
}

/// 一筆 70/30 比例分攤的支出，用來驗編輯時反推百分比。
class RatioEntry extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-ratio',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 1000,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: '比例筆',
          payerId: kMeId,
          splitMethod: SplitMethod.ratio,
          splits: const [
            EntrySplit(entryId: 'e-ratio', memberId: kMeId, share: 700),
            EntrySplit(entryId: 'e-ratio', memberId: kWifeId, share: 300),
          ],
        ),
      ];
}

/// 一筆結算中的支出（settling 期間金額同樣鎖定）。
class SettlingEntries extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-settling',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 800,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: '結算中的買菜',
          payerId: kMeId,
          splitMethod: SplitMethod.equal,
          settledState: SettledState.settling,
          splits: const [
            EntrySplit(entryId: 'e-settling', memberId: kMeId, share: 400),
            EntrySplit(entryId: 'e-settling', memberId: kWifeId, share: 400),
          ],
        ),
      ];
}

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

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> fillKey(WidgetTester tester, String key, String text) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.enterText(f, text);
  await tester.pumpAndSettle();
}

Future<void> openNewForm(WidgetTester tester) async {
  await tester.tap(find.text('新增'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => router.go('/entries'));

  testWidgets('新增支出：均分 567 → 283.5／283.5，entriesProvider 多一筆', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '567');
    await tapKey(tester, 'category-c-food');
    await fillKey(tester, 'note-field', '測試買菜');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-equal');
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, before + 1);
    final e = entries.last;
    expect(e.amount, 567);
    expect(e.note, '測試買菜');
    expect(e.categoryId, 'c-food');
    expect(e.kind, EntryKind.expense);
    expect(e.payerId, kMeId);
    expect(e.splitMethod, SplitMethod.equal);
    expect(e.splits.length, 2);
    expect(e.splits.map((s) => s.share).toList(), [283.5, 283.5]);
  });

  testWidgets('細項可加，差額只提示不擋存', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await tapKey(tester, 'category-c-food');
    await tapKey(tester, 'lineitem-add');
    await fillKey(tester, 'li-name-0', '雞蛋');
    await fillKey(tester, 'li-amount-0', '89');
    expect(find.textContaining('合計'), findsOneWidget);
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, before + 1);
    expect(entries.last.lineItems.single.name, '雞蛋');
    expect(entries.last.lineItems.single.amount, 89);
  });

  testWidgets('比例逐筆可調：改成 70/30 存檔 → splits 396.9／170.1', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '567');
    await tapKey(tester, 'category-c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-ratio');

    // 預設帶入帳本 default_ratio 50/50
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kMeId'))).controller!.text, '50');
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kWifeId'))).controller!.text, '50');

    await fillKey(tester, 'ratio-$kMeId', '70');
    await fillKey(tester, 'ratio-$kWifeId', '30');
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, before + 1);
    final e = entries.last;
    expect(e.splitMethod, SplitMethod.ratio);
    expect(e.splits.map((s) => s.share).toList(), [396.9, 170.1]);
  });

  testWidgets('比例合計不是 100 → 擋存並提示', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await tapKey(tester, 'category-c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-ratio');
    await fillKey(tester, 'ratio-$kMeId', '70');
    await fillKey(tester, 'ratio-$kWifeId', '20');
    await tapKey(tester, 'save-button');

    expect(find.textContaining('比例合計需為 100%'), findsOneWidget);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('編輯既有比例筆：從 splits 反推百分比帶入', (tester) async {
    await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(RatioEntry.new)]));
    await tester.tap(find.text('比例筆'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'advanced-tile');

    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kMeId'))).controller!.text, '70');
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kWifeId'))).controller!.text, '30');
  });

  testWidgets('390×844：新增表單不展開進階時一頁看完、不爆版', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);

    // 進階列與儲存鈕都在視窗內，且沒有 overflow 例外
    expect(tester.getBottomRight(find.byKey(const Key('advanced-tile'))).dy, lessThanOrEqualTo(844));
    expect(tester.getBottomRight(find.byKey(const Key('save-button'))).dy, lessThanOrEqualTo(844));
    expect(find.byKey(const Key('lineitem-add')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('金額分攤合計不等於主筆 → 擋存並提示', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await tapKey(tester, 'category-c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-amount');
    await fillKey(tester, 'manual-$kMeId', '300');
    await fillKey(tester, 'manual-$kWifeId', '100');
    await tapKey(tester, 'save-button');

    expect(find.textContaining('分攤金額合計'), findsOneWidget);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('已結帳：金額欄 disabled 並顯示鎖定說明', (tester) async {
    await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(SettledOnlyEntries.new)]));
    await tester.tap(find.text('已結帳的買菜'));
    await tester.pumpAndSettle();

    final amount = tester.widget<TextField>(find.byKey(const Key('amount-field')));
    expect(amount.enabled, isFalse);
    expect(find.textContaining('已結帳，金額鎖定'), findsOneWidget);
    expect(find.byKey(const Key('entry-menu')), findsNothing);
  });

  testWidgets('已結帳：付款來源／分攤／範圍全部 disabled，存檔不動這些欄位', (tester) async {
    final c = await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(SettledOnlyEntries.new)]));
    await tester.tap(find.text('已結帳的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'advanced-tile');

    expect(tester.widget<ChoiceChip>(find.byKey(const Key('payer-common'))).onSelected, isNull);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('payer-$kMeId'))).onSelected, isNull);
    for (final k in const ['split-equal', 'split-ratio', 'split-amount', 'split-common']) {
      expect(tester.widget<ChoiceChip>(find.byKey(Key(k))).onSelected, isNull, reason: k);
    }
    for (final k in const ['scope-shared', 'scope-private']) {
      expect(tester.widget<ChoiceChip>(find.byKey(Key(k))).onSelected, isNull, reason: k);
    }

    await fillKey(tester, 'note-field', '只改備註');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '只改備註');
    expect(e.amount, 1000);
    expect(e.scope, EntryScope.shared);
    expect(e.payerId, kMeId);
    expect(e.splitMethod, SplitMethod.equal);
    expect(e.splits.map((s) => s.share).toList(), [500.0, 500.0]);
    expect(e.settledState, SettledState.settled);
  });

  testWidgets('已結帳＋金額分攤：改備註可存，splits 不被重算覆寫也不被合計檢查擋住', (tester) async {
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [entriesProvider.overrideWith(SettledAmountSplitEntries.new)]),
    );
    await tester.tap(find.text('已結帳的金額分攤'));
    await tester.pumpAndSettle();

    await fillKey(tester, 'note-field', '只改備註');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '只改備註');
    expect(e.amount, 567);
    expect(e.splitMethod, SplitMethod.amount);
    expect(e.splits.map((s) => s.share).toList(), [283.5, 283.5]);
  });

  testWidgets('結算中：金額鎖定但分類、備註、細項可改', (tester) async {
    final c = await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(SettlingEntries.new)]));
    await tester.tap(find.text('結算中的買菜'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byKey(const Key('amount-field'))).enabled, isFalse);
    expect(find.textContaining('結算中，簽核完成或作廢後才能改金額'), findsOneWidget);
    expect(find.byKey(const Key('entry-menu')), findsNothing);

    await tapKey(tester, 'category-c-dining');
    await fillKey(tester, 'note-field', '結算中也能改備註');
    await tapKey(tester, 'lineitem-add');
    await fillKey(tester, 'li-name-0', '豆腐');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '結算中也能改備註');
    expect(e.categoryId, 'c-dining');
    expect(e.lineItems.single.name, '豆腐');
    expect(e.amount, 800);
    expect(e.payerId, kMeId);
    expect(e.splitMethod, SplitMethod.equal);
    expect(e.settledState, SettledState.settling);
  });

  testWidgets('編輯：改備註後 entriesProvider 內容更新', (tester) async {
    final c = await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(OneOpenEntry.new)]));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();

    await fillKey(tester, 'note-field', '改過的備註');
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, 1);
    expect(entries.single.id, 'e-open');
    expect(entries.single.note, '改過的備註');
  });

  testWidgets('刪除：確認後 entriesProvider 少一筆', (tester) async {
    final c = await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(OneOpenEntry.new)]));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();

    await tapKey(tester, 'entry-menu');
    await tapKey(tester, 'delete-entry');
    await tapKey(tester, 'confirm-delete');

    expect(c.read(entriesProvider), isEmpty);
  });

  testWidgets('儲存失敗顯示 SnackBar', (tester) async {
    await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(ThrowingEntries.new)]));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '120');
    await tapKey(tester, 'category-c-food');
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('儲存失敗'), findsOneWidget);
  });

  testWidgets('編輯儲存失敗顯示 SnackBar', (tester) async {
    final c = await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(ThrowingUpdateEntries.new)]));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();
    await fillKey(tester, 'note-field', '改不動');
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('儲存失敗'), findsOneWidget);
    expect(c.read(entriesProvider).single.note, '可刪的買菜');
  });

  testWidgets('刪除失敗顯示 SnackBar', (tester) async {
    final c = await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(ThrowingRemoveEntries.new)]));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'entry-menu');
    await tapKey(tester, 'delete-entry');
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('刪除失敗'), findsOneWidget);
    expect(c.read(entriesProvider).length, 1);
  });

  testWidgets('金額欄擋掉 1-2／--5，修正筆開啟後才收負號', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);

    String amountText() => tester.widget<TextField>(find.byKey(const Key('amount-field'))).controller!.text;

    await fillKey(tester, 'amount-field', '1-2');
    expect(amountText(), '');
    await fillKey(tester, 'amount-field', '--5');
    expect(amountText(), '');
    await fillKey(tester, 'amount-field', '-5');
    expect(amountText(), '', reason: '未開修正筆不收負號');

    await fillKey(tester, 'amount-field', '120');
    expect(amountText(), '120');

    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'adjustment-switch');
    await fillKey(tester, 'amount-field', '-5');
    expect(amountText(), '-5');
    await fillKey(tester, 'amount-field', '-5-3');
    expect(amountText(), '-5', reason: '只收開頭一個負號');
  });

  testWidgets('金額只有負號 → 提示金額格式不正確', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;
    await openNewForm(tester);
    await tapKey(tester, 'category-c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'adjustment-switch');
    await fillKey(tester, 'amount-field', '-');
    await tapKey(tester, 'save-button');

    expect(find.textContaining('金額格式不正確'), findsOneWidget);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('成員多於帳本預設比例時：每人都有比例欄，存檔比例正確', (tester) async {
    const kid = Member(id: 'm-kid', ledgerId: kLedgerId, userId: 'u3', displayName: '小孩');
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [
        membersProvider.overrideWithValue(const [
          Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike'),
          Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆'),
          kid,
        ]),
      ]),
    );

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '900');
    await tapKey(tester, 'category-c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-ratio');

    // 帳本 default_ratio 沒有小孩 → 延遲建立的 controller 帶 0，不會是 null
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-m-kid'))).controller!.text, '0');

    await fillKey(tester, 'ratio-$kMeId', '40');
    await fillKey(tester, 'ratio-$kWifeId', '40');
    await fillKey(tester, 'ratio-m-kid', '20');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).last;
    expect(e.splits.map((s) => s.share).toList(), [360.0, 360.0, 180.0]);
  });

  testWidgets('點擊目標 ≥44：選項 chip 與細項按鈕的命中區', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'lineitem-add');

    for (final k in const ['scope-shared', 'payer-common', 'split-equal', 'split-common']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(44), reason: k);
    }
    for (final k in const ['lineitem-add', 'li-del-0']) {
      final size = tester.getSize(find.byKey(Key(k)));
      expect(size.height, greaterThanOrEqualTo(44), reason: k);
      expect(size.width, greaterThanOrEqualTo(44), reason: k);
    }
  });

  testWidgets('未選分類擋存', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '120');
    await tapKey(tester, 'save-button');
    expect(find.textContaining('請選擇分類'), findsOneWidget);
    expect(c.read(entriesProvider).length, before);
  });
}
