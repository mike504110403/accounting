import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/entries/settlement_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 這組測試只算結算淨額，跟加入月無關：一律「很久以前就加入」。
  final epoch = DateTime(1970);
  final members = [
    Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: epoch),
    Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: epoch),
  ];

  Entry exp({
    required String id,
    required int amount,
    required String payer,
    required Map<String, double> shares,
    EntryScope scope = EntryScope.shared,
    SplitMethod method = SplitMethod.equal,
    SettledState settled = SettledState.open,
  }) {
    return Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: scope,
      amount: amount,
      categoryId: 'c-food',
      occurredOn: DateTime(2026, 9, 1),
      createdBy: payer,
      payerId: payer,
      splitMethod: method,
      settledState: settled,
      splits: [for (final e in shares.entries) EntrySplit(entryId: id, memberId: e.key, share: e.value)],
    );
  }

  test('isSettleable：只收 shared/expense/open/有 payer/非 common', () {
    final base = exp(id: 'a', amount: 100, payer: kMeId, shares: {kMeId: 50, kWifeId: 50});
    expect(isSettleable(base), isTrue);
    expect(isSettleable(exp(id: 'b', amount: 100, payer: kMeId, shares: {}, method: SplitMethod.common)), isFalse);
    expect(isSettleable(exp(id: 'c', amount: 100, payer: kMeId, shares: {kMeId: 50, kWifeId: 50}, scope: EntryScope.private)), isFalse);
    expect(
      isSettleable(exp(id: 'd', amount: 100, payer: kMeId, shares: {kMeId: 50, kWifeId: 50}, settled: SettledState.settling)),
      isFalse,
    );
    expect(
      isSettleable(Entry(
        id: 'e',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 100,
        categoryId: 'c-food',
        occurredOn: DateTime(2026, 9, 1),
        createdBy: kMeId,
        splitMethod: SplitMethod.equal,
      )),
      isFalse,
    );
    expect(
      isSettleable(Entry(
        id: 'f',
        ledgerId: kLedgerId,
        kind: EntryKind.income,
        scope: EntryScope.shared,
        amount: 100,
        categoryId: 'c-salary',
        occurredOn: DateTime(2026, 9, 1),
        createdBy: kMeId,
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
      )),
      isFalse,
    );
  });

  test('computeNets＝付出總額−分攤總額，四捨五入整數且合計為零', () {
    final entries = [
      exp(id: 'a', amount: 567, payer: kMeId, shares: {kMeId: 283.5, kWifeId: 283.5}),
      exp(id: 'b', amount: 1280, payer: kWifeId, shares: {kMeId: 640, kWifeId: 640}),
    ];
    final nets = computeNets(entries, members);
    // Mike 付 567、分攤 923.5 → −356.5 → −357；老婆 付 1280、分攤 923.5 → +356.5 → +357
    expect(nets[kMeId], -357);
    expect(nets[kWifeId], 357);
  });

  test('假資料的可結算支出：Mike +284／老婆 −284', () {
    // 假資料只有 e-5 是 open 的代墊共同支出（e-6/e-7/e-9/e-10 已在 pending settlement 內＝settling）。
    // e-5 567 由 Mike 付、均分 283.5：Mike 567−283.5=+283.5 → +284；老婆 0−283.5=−283.5 → −284。
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final all = container.read(entriesProvider);
    final nets = computeNets(all.where(isSettleable), members);
    expect(nets[kMeId], 284);
    expect(nets[kWifeId], -284);
  });

  test('沒有可結算支出時淨額全為零', () {
    final nets = computeNets(const <Entry>[], members);
    expect(nets, {kMeId: 0, kWifeId: 0});
  });
}
