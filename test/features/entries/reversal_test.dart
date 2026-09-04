import 'package:accounting/domain/models.dart';
import 'package:accounting/features/entries/reversal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final settled = Entry(
    id: 'e-settled-full-id-123',
    ledgerId: 'L',
    kind: EntryKind.expense,
    scope: EntryScope.shared,
    amount: 1000,
    categoryId: 'c-food',
    occurredOn: DateTime(2026, 9, 2),
    createdBy: 'm-1',
    note: '晚餐',
    payerId: 'm-1',
    splitMethod: SplitMethod.equal,
    settledState: SettledState.settled,
    splits: const [
      EntrySplit(entryId: 'e', memberId: 'm-1', share: 500),
      EntrySplit(entryId: 'e', memberId: 'm-2', share: 500),
    ],
    lineItems: const [LineItem(id: 'li', entryId: 'e', name: '牛排', amount: 1000, sort: 0)],
  );

  test('buildReversal：金額與份額全取負、來源照抄、細項不帶、標記沖銷', () {
    final r = buildReversal(settled, me: 'm-2');
    expect(r.amount, -1000);
    expect(r.isAdjustment, isTrue);
    expect(r.kind, EntryKind.expense);
    expect(r.payerId, 'm-1', reason: '付款來源照抄原筆，餘額才會沿原路回退');
    expect(r.splitMethod, SplitMethod.equal);
    expect(r.occurredOn, DateTime(2026, 9, 2));
    expect(r.createdBy, 'm-2');
    expect(r.splits.map((s) => s.share), [-500, -500]);
    expect(r.splits.map((s) => s.share).reduce((a, b) => a + b), r.amount, reason: '分攤守恆');
    expect(r.lineItems, isEmpty);
    expect(r.note, contains('#e-settle'));
  });

  test('私人筆沖銷：payer 換成操作者本人（DB 不變式）', () {
    final priv = Entry(
      id: 'e-priv-full-id',
      ledgerId: 'L',
      kind: EntryKind.expense,
      scope: EntryScope.private,
      amount: 300,
      categoryId: 'c-fun',
      occurredOn: DateTime(2026, 9, 1),
      createdBy: 'm-1',
      payerId: 'm-1',
    );
    final r = buildReversal(priv, me: 'm-1');
    expect(r.payerId, 'm-1');
    expect(r.amount, -300);
  });

  test('收入沖銷：負收入', () {
    final income = Entry(
      id: 'e-income-full-id',
      ledgerId: 'L',
      kind: EntryKind.income,
      scope: EntryScope.shared,
      amount: 52000,
      categoryId: 'c-salary',
      occurredOn: DateTime(2026, 9, 5),
      createdBy: 'm-1',
    );
    final r = buildReversal(income, me: 'm-1');
    expect(r.kind, EntryKind.income);
    expect(r.amount, -52000);
  });

  test('hasReversal：以備註短代碼判定，只認 isAdjustment 筆', () {
    final r = buildReversal(settled, me: 'm-1');
    expect(hasReversal([settled], settled), isFalse);
    expect(hasReversal([settled, r], settled), isTrue);
  });

}
