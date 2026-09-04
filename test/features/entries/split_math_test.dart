import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/entries/split_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 這組測試只算分攤，跟加入月無關：一律「很久以前就加入」。
  final epoch = DateTime(1970);
  final members = [
    Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: epoch),
    Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: epoch),
  ];
  final third = Member(id: 'm-3', ledgerId: kLedgerId, userId: 'u3', displayName: '小孩', joinedAt: epoch);
  const ratio = {kMeId: 50, kWifeId: 50};

  test('equal：均分兩位小數，567 → 283.5／283.5', () {
    final s = buildSplits(amount: 567, method: SplitMethod.equal, members: members, ratio: ratio);
    expect(s, {kMeId: 283.5, kWifeId: 283.5});
  });

  test('equal：除不盡時餘數補在第一位，合計等於主筆', () {
    final s = buildSplits(amount: 100, method: SplitMethod.equal, members: [...members, third], ratio: ratio);
    expect(s[kMeId], 33.34);
    expect(s[kWifeId], 33.33);
    expect(s['m-3'], 33.33);
    expect(s.values.fold<double>(0, (a, b) => a + b), closeTo(100, 0.001));
  });

  test('ratio：依 defaultRatio 分配', () {
    final s = buildSplits(amount: 1000, method: SplitMethod.ratio, members: members, ratio: const {kMeId: 60, kWifeId: 40});
    expect(s, {kMeId: 600.0, kWifeId: 400.0});
  });

  test('amount：用手填金額', () {
    final s = buildSplits(
      amount: 500,
      method: SplitMethod.amount,
      members: members,
      ratio: ratio,
      manual: const {kMeId: 300, kWifeId: 200},
    );
    expect(s, {kMeId: 300.0, kWifeId: 200.0});
  });

  test('common：無分攤', () {
    expect(buildSplits(amount: 500, method: SplitMethod.common, members: members, ratio: ratio), isEmpty);
  });

  test('toEntrySplits 掛上 entryId', () {
    final splits = toEntrySplits('e-99', {kMeId: 283.5, kWifeId: 283.5});
    expect(splits.length, 2);
    expect(splits.first.entryId, 'e-99');
    expect(splits.map((s) => s.share).toList(), [283.5, 283.5]);
  });
}
