/// 統計頁的視角換算與圓餅分桶純函式。
///
/// 「視角過濾 ＋ 金額換算」集中在 [viewEntries]，統計（月摘要、圓餅、趨勢）
/// 一律吃它的輸出，不再各自判斷 scope／分攤。
library;

import '../../domain/balance_math.dart';
import '../../domain/models.dart';

/// 套上視角後的一筆：原始 entry ＋ 該視角下計入統計的金額。
typedef ViewEntry = ({Entry entry, int amount});

/// 視角過濾＋金額換算（ADR-0003）。
///
/// - 家庭：只取 `scope == shared`，金額全額。
/// - 個人：`private && createdBy == me` 取全額；共同支出取 [myPortion]
///   （splits 取我的分攤、common 依 `defaultRatio`）。他人的私人筆不可見；
///   共同收入進共同餘額、不進個人視角（spec 帳務規則 v1.3）。
List<ViewEntry> viewEntries(
  Iterable<Entry> entries,
  ViewMode mode,
  String me,
  Map<String, int> ratio,
) {
  final out = <ViewEntry>[];
  for (final e in entries) {
    switch (mode) {
      case ViewMode.family:
        if (e.scope == EntryScope.shared) out.add((entry: e, amount: e.amount));
      case ViewMode.personal:
        if (e.scope == EntryScope.private) {
          if (e.createdBy == me) out.add((entry: e, amount: e.amount));
        } else if (e.isExpense) {
          out.add((entry: e, amount: myPortion(e, me, ratio)));
        }
    }
  }
  return out;
}

// ── 日期工具（balance_math 只有月層級，日／週層級放這裡）─────────────────

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 該日所屬週的週一（週一起算，ADR 對齊 spec「週一起」）。
DateTime startOfWeek(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// 週一往後第 6 天（週日）。
DateTime endOfWeek(DateTime weekStart) =>
    DateTime(weekStart.year, weekStart.month, weekStart.day + 6);

DateTime lastDayOfMonth(DateTime m) => DateTime(m.year, m.month + 1, 0);

int daysInMonth(DateTime m) => lastDayOfMonth(m).day;

/// 圓餅「週」模式的一段區間（皆含端點），已與該月取交集裁切。
typedef WeekRange = ({DateTime start, DateTime end});

/// 與 [month] 有交集的所有週（週一起算），**裁切到該月之內**依時間升冪。
///
/// 跨月的頭尾週只保留落在本月的那幾天：2026-02-23 那週在 3 月頁只剩 3/1 一天。
/// 不裁切的話，選「本月第一週」會把上個月的帳算進本月圓餅。
List<WeekRange> weekRangesOfMonth(DateTime month) {
  final m = monthOf(month);
  final last = lastDayOfMonth(m);
  final out = <WeekRange>[];
  var w = startOfWeek(m);
  while (!w.isAfter(last)) {
    final e = endOfWeek(w);
    out.add((start: w.isBefore(m) ? m : w, end: e.isAfter(last) ? last : e));
    w = DateTime(w.year, w.month, w.day + 7);
  }
  return out;
}

/// [d] 是否落在 [start]、[end] 之間（皆含端點，只比日期）。
bool inRange(DateTime d, DateTime start, DateTime end) {
  final x = dateOnly(d);
  return !x.isBefore(dateOnly(start)) && !x.isAfter(dateOnly(end));
}

// ── 月摘要 ────────────────────────────────────────────────────────────

class MonthSummary {
  const MonthSummary({required this.income, required this.expense, required this.balance});

  /// 該月收入合計（視角金額）。
  final int income;

  /// 該月支出合計（視角金額）。
  final int expense;

  /// 該月最後一天（含）的餘額（ADR-0008，v1.4）：
  /// 家庭＝`sharedBalance`（共同餘額）、個人＝`personalBalance`（個人餘額）。
  /// 由呼叫端把視角與已清帳月語意都決定好，這裡只管收（單一固定 until，不是
  /// 逐桶算式，不需要 callback）。
  ///
  /// `null`＝已清帳月份有清帳列、但快照裡找不到本人（資料異常）——月摘要卡顯示
  /// 「—」，不是一個算得出來的數字；跟「這個月根本沒清過帳」（顯示 0）是兩回事。
  final int? balance;

  int get net => income - expense;
}

MonthSummary monthSummary({
  required List<ViewEntry> items,
  required DateTime month,
  required int? balance,
}) {
  var income = 0;
  var expense = 0;
  for (final i in items) {
    if (!sameMonth(i.entry.occurredOn, month)) continue;
    if (i.entry.isExpense) {
      expense += i.amount;
    } else {
      income += i.amount;
    }
  }
  return MonthSummary(income: income, expense: expense, balance: balance);
}

// ── 圓餅 ──────────────────────────────────────────────────────────────

enum PieBy { category, member }

/// 「依成員」圓餅裡「共同錢包」那一項的 key（payer 為 null 或 split common）。
const kCommonWalletKey = '__common_wallet__';

/// 圓餅一塊：[key] 是 categoryId 或 memberId／[kCommonWalletKey]，標籤由 UI 解析。
typedef PieSlice = ({String key, int amount});

/// 只算支出，依金額降冪；合計 ≤ 0 的 key 不出現（修正筆可能讓某塊變負）。
List<PieSlice> pieSlices(Iterable<ViewEntry> items, PieBy by) {
  final sums = <String, int>{};
  for (final i in items) {
    if (!i.entry.isExpense) continue;
    final key = switch (by) {
      PieBy.category => i.entry.categoryId,
      PieBy.member => i.entry.fromCommonWallet ? kCommonWalletKey : i.entry.payerId!,
    };
    sums[key] = (sums[key] ?? 0) + i.amount;
  }
  final out = <PieSlice>[
    for (final e in sums.entries)
      if (e.value > 0) (key: e.key, amount: e.value),
  ];
  out.sort((a, b) => b.amount.compareTo(a.amount));
  return out;
}
