import 'package:accounting/domain/models.dart';
import 'package:accounting/features/entries/reversal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final paidByMe = Entry(
    id: 'e-paid-full-id-123',
    ledgerId: 'L',
    kind: EntryKind.expense,
    amount: 1000,
    categoryId: 'c-food',
    occurredOn: DateTime(2026, 9, 2),
    createdBy: 'm-1',
    note: '晚餐',
    payerId: 'm-1',
    lineItems: const [LineItem(id: 'li', entryId: 'e', name: '牛排', amount: 1000, sort: 0)],
  );

  test('buildReversal：金額取負、誰先付照抄、細項不帶、標記沖銷', () {
    final r = buildReversal(paidByMe, me: 'm-2');
    expect(r.amount, -1000);
    expect(r.isAdjustment, isTrue);
    expect(r.kind, EntryKind.expense);
    expect(r.payerId, 'm-1',
        reason: '誰先付照抄原筆：原筆扣誰的補入剩餘，反向筆就要補回誰的');
    expect(r.occurredOn, DateTime(2026, 9, 2), reason: '同日反向才會落在同一個月的補入剩餘桶');
    expect(r.createdBy, 'm-2', reason: '沖銷的人是操作者，不是原筆記帳人');
    expect(r.ledgerId, 'L');
    expect(r.categoryId, 'c-food');
    expect(r.lineItems, isEmpty);
    expect(r.note, contains('#e-paid-f'));
    expect(r.id, isEmpty, reason: '新筆，id 交給 DB');
  });

  test('共同錢包付的支出沖銷：payerId 維持 null（共同餘額沿原路加回去）', () {
    final wallet = Entry(
      id: 'e-wallet-full-id',
      ledgerId: 'L',
      kind: EntryKind.expense,
      amount: 3000,
      categoryId: 'c-util',
      occurredOn: DateTime(2026, 9, 1),
      createdBy: 'm-1',
      note: '水電',
    );
    final r = buildReversal(wallet, me: 'm-2');
    expect(r.payerId, isNull, reason: 'null＝共同錢包；換成操作者會把錢記到人頭上');
    expect(r.amount, -3000);
  });

  test('收入沖銷：負收入，且沒有付款人', () {
    final income = Entry(
      id: 'e-income-full-id',
      ledgerId: 'L',
      kind: EntryKind.income,
      amount: 52000,
      categoryId: 'c-salary',
      occurredOn: DateTime(2026, 9, 5),
      createdBy: 'm-1',
    );
    final r = buildReversal(income, me: 'm-1');
    expect(r.kind, EntryKind.income);
    expect(r.amount, -52000);
    expect(r.payerId, isNull);
  });

  test('hasReversal：以備註短代碼判定，只認 isAdjustment 筆', () {
    final r = buildReversal(paidByMe, me: 'm-1');
    expect(hasReversal([paidByMe], paidByMe), isFalse);
    expect(hasReversal([paidByMe, r], paidByMe), isTrue);
  });

  test('hasReversal：備註提到短代碼但不是沖銷筆 → 不算已沖銷', () {
    final lookalike = Entry(
      id: 'e-other',
      ledgerId: 'L',
      kind: EntryKind.expense,
      amount: 50,
      categoryId: 'c-food',
      occurredOn: DateTime(2026, 9, 3),
      createdBy: 'm-1',
      note: '參考 #${reversalTag(paidByMe)}',
    );
    expect(hasReversal([paidByMe, lookalike], paidByMe), isFalse);
  });
}
