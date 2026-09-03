/// 結算淨額純函式（spec「結算」、ADR-0002）。
library;

import '../../domain/models.dart';

/// 可結算支出：共同、支出、open、有付款人（非共同錢包）、分攤方式非 common。
bool isSettleable(Entry e) =>
    e.isExpense &&
    e.scope == EntryScope.shared &&
    e.settledState == SettledState.open &&
    e.payerId != null &&
    e.splitMethod != SplitMethod.common;

/// 每成員淨額：付出總額 − 分攤總額，四捨五入整數（正＝應收、負＝應付）。
Map<String, int> computeNets(Iterable<Entry> entries, List<Member> members) {
  final paid = {for (final m in members) m.id: 0.0};
  final owed = {for (final m in members) m.id: 0.0};
  for (final e in entries) {
    final p = e.payerId;
    if (p != null && paid.containsKey(p)) paid[p] = paid[p]! + e.amount;
    for (final s in e.splits) {
      if (owed.containsKey(s.memberId)) owed[s.memberId] = owed[s.memberId]! + s.share;
    }
  }
  return {for (final m in members) m.id: (paid[m.id]! - owed[m.id]!).round()};
}
