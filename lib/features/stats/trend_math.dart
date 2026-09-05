/// 趨勢圖分桶純函式：把資料切成日／週／月／年桶，每桶算出花費、共同餘額、每人補入
/// （v1.5／ADR-0009：無視角、無超支線——預算與超支是預算頁的事，統計不再畫）。
library;

import '../../domain/balance_math.dart';
import '../../domain/models.dart';

/// 一個時間桶（[start]、[end] 皆含端點）。
class Bucket {
  const Bucket({
    required this.label,
    required this.start,
    required this.end,
    required this.spend,
    required this.sharedBalance,
    required this.topupByMember,
  });

  /// x 軸標籤：日＝日數字、週＝M/d、月＝M月、年＝yyyy。
  final String label;
  final DateTime start;
  final DateTime end;

  /// 桶內全部支出合計，不分誰付（spec「統計」節「花費」）。
  final int spend;

  /// 桶末日（含）的共同餘額（`balance_math.sharedBalance`）。
  final int sharedBalance;

  /// 桶內每位成員的補入合計，key 是 memberId。
  ///
  /// **只在月／年顆粒度計算**，日／週顆粒度恆空 map（spec：「每人補入…只在月／年
  /// 顆粒度畫」）。月顆粒度若桶剛好落在一個已清帳月（`closes` 裡有那一列），改讀
  /// `MonthClose.details.members[*].topup` 快照，不吃即時 `topups`（清帳後補入
  /// 已回到設定狀態，但快照是清帳當下的事實，不會因為後續資料而變動）；年顆粒度
  /// 把該年 12 個月各自的值（已清月讀快照、未清月讀即時）加總。
  final Map<String, int> topupByMember;
}

/// [bucketize] 的輸入：全期間資料（不要先過濾月份，餘額與補入都要往前累計／對照月份）。
class TrendInput {
  const TrendInput({
    required this.entries,
    required this.topups,
    required this.closes,
  });

  /// 全部帳目（收入＋支出）：`spend` 只收支出，`sharedBalance` 兩者都要看。
  final List<Entry> entries;
  final List<PersonalTopup> topups;
  final List<MonthClose> closes;
}

// ── 日期工具（v1.5：balance_math 只有月層級；日／週層級唯一定義處，`pie_card.dart`
// 的週期間選擇也 import 這裡，不要各自重寫一份——之前兩邊各放一份重複過）───────

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 該日所屬週的週一（週一起算，spec「週一起」）。
DateTime startOfWeek(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

DateTime endOfWeek(DateTime weekStart) =>
    DateTime(weekStart.year, weekStart.month, weekStart.day + 6);

DateTime lastDayOfMonth(DateTime m) => DateTime(m.year, m.month + 1, 0);

int _daysInMonth(DateTime m) => lastDayOfMonth(m).day;

/// [d] 是否落在 [start]、[end] 之間（皆含端點，只比日期）。
bool inRange(DateTime d, DateTime start, DateTime end) {
  final x = dateOnly(d);
  return !x.isBefore(dateOnly(start)) && !x.isAfter(dateOnly(end));
}

/// [monthStart] 所在月每位成員的補入合計：該月有清帳列（`sameMonth`）就讀快照，
/// 否則即時加總 [topups]。
Map<String, int> _topupByMemberForMonth(
  Iterable<PersonalTopup> topups,
  Iterable<MonthClose> closes,
  DateTime monthStart,
) {
  for (final c in closes) {
    if (sameMonth(c.month, monthStart)) {
      return {for (final m in c.details.members) m.memberId: m.topup};
    }
  }
  final out = <String, int>{};
  for (final t in topups) {
    if (!sameMonth(t.occurredOn, monthStart)) continue;
    out[t.memberId] = (out[t.memberId] ?? 0) + t.amount;
  }
  return out;
}

/// [year] 12 個月的 [_topupByMemberForMonth] 加總（年顆粒度用）。
Map<String, int> _topupByMemberForYear(
  Iterable<PersonalTopup> topups,
  Iterable<MonthClose> closes,
  int year,
) {
  final out = <String, int>{};
  for (var month = 1; month <= 12; month++) {
    final m = _topupByMemberForMonth(topups, closes, DateTime(year, month, 1));
    m.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
  }
  return out;
}

/// 依顆粒度分桶。範圍固定：
/// 日＝[anchorMonth] 當月每日、週＝到當月最後一天所屬週為止的最近 12 週、
/// 月＝到 [anchorMonth] 為止的最近 12 個月、年＝到 anchorMonth.year 為止的最近 5 年。
List<Bucket> bucketize(TrendInput input, Granularity granularity, DateTime anchorMonth) {
  final ranges = _ranges(granularity, monthOf(anchorMonth));

  final out = <Bucket>[];
  for (final r in ranges) {
    var spend = 0;
    for (final e in input.entries) {
      if (!e.isExpense) continue;
      if (!inRange(e.occurredOn, r.start, r.end)) continue;
      spend += e.amount;
    }

    final Map<String, int> topupByMember = switch (granularity) {
      Granularity.month => _topupByMemberForMonth(input.topups, input.closes, r.start),
      Granularity.year => _topupByMemberForYear(input.topups, input.closes, r.start.year),
      Granularity.day || Granularity.week => const {},
    };

    out.add(Bucket(
      label: r.label,
      start: r.start,
      end: r.end,
      spend: spend,
      sharedBalance: sharedBalance(entries: input.entries, until: r.end),
      topupByMember: topupByMember,
    ));
  }
  return out;
}

typedef _Range = ({DateTime start, DateTime end, String label});

List<_Range> _ranges(Granularity g, DateTime m) {
  final out = <_Range>[];
  switch (g) {
    case Granularity.day:
      final n = _daysInMonth(m);
      for (var d = 1; d <= n; d++) {
        final day = DateTime(m.year, m.month, d);
        out.add((start: day, end: day, label: '$d'));
      }
    case Granularity.week:
      final lastStart = startOfWeek(lastDayOfMonth(m));
      for (var i = 11; i >= 0; i--) {
        final s = DateTime(lastStart.year, lastStart.month, lastStart.day - i * 7);
        out.add((start: s, end: endOfWeek(s), label: '${s.month}/${s.day}'));
      }
    case Granularity.month:
      for (var i = 11; i >= 0; i--) {
        final s = DateTime(m.year, m.month - i, 1);
        out.add((start: s, end: lastDayOfMonth(s), label: '${s.month}月'));
      }
    case Granularity.year:
      for (var i = 4; i >= 0; i--) {
        final y = m.year - i;
        out.add((start: DateTime(y, 1, 1), end: DateTime(y, 12, 31), label: '$y'));
      }
  }
  return out;
}
