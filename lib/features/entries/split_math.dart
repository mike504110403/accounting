/// 分攤計算純函式（spec「分攤方式」、ADR-0005 兩位小數）。
library;

import '../../domain/models.dart';

/// 四捨五入到兩位小數。
double round2(double v) => (v * 100).roundToDouble() / 100;

/// 依分攤方式算出每成員份額（memberId → share，兩位小數）。
///
/// - [SplitMethod.equal]：均分；除不盡的餘數補在第一位成員，確保合計等於主筆金額。
/// - [SplitMethod.ratio]：依帳本 `defaultRatio`（百分比）分配。
/// - [SplitMethod.amount]：直接用 [manual] 手填金額。
/// - [SplitMethod.common]：共同錢包出，不產生分攤。
Map<String, double> buildSplits({
  required int amount,
  required SplitMethod method,
  required List<Member> members,
  required Map<String, int> ratio,
  Map<String, int> manual = const {},
}) {
  if (method == SplitMethod.common || members.isEmpty) return const {};
  switch (method) {
    case SplitMethod.equal:
      final each = round2(amount / members.length);
      final out = {for (final m in members) m.id: each};
      final residual = round2(amount - each * members.length);
      if (residual != 0) out[members.first.id] = round2(each + residual);
      return out;
    case SplitMethod.ratio:
      final out = <String, double>{};
      var acc = 0.0;
      for (final m in members) {
        final share = round2(amount * (ratio[m.id] ?? 0) / 100);
        out[m.id] = share;
        acc += share;
      }
      final residual = round2(amount - acc);
      if (residual != 0 && out.isNotEmpty) {
        out[members.first.id] = round2(out[members.first.id]! + residual);
      }
      return out;
    case SplitMethod.amount:
      return {for (final m in members) m.id: (manual[m.id] ?? 0).toDouble()};
    case SplitMethod.common:
      return const {};
  }
}

/// 把份額掛上主筆 id。
List<EntrySplit> toEntrySplits(String entryId, Map<String, double> shares) =>
    [for (final e in shares.entries) EntrySplit(entryId: entryId, memberId: e.key, share: e.value)];

/// 手填金額分攤的合計（擋存用）。
int manualTotal(Map<String, int> manual) => manual.values.fold(0, (a, b) => a + b);
