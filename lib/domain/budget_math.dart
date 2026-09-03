/// 預算與餘額的純函式（ADR-0004）。統計與預算頁共用，工人只消費不改。
library;

import 'models.dart';

DateTime monthOf(DateTime d) => DateTime(d.year, d.month, 1);
DateTime prevMonth(DateTime m) => DateTime(m.year, m.month - 1, 1);
DateTime nextMonth(DateTime m) => DateTime(m.year, m.month + 1, 1);
bool sameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

/// 某分類某月的基礎上限：取 month ≤ 目標月的最近一筆 budget；沒有則 null。
int? baseLimit(List<Budget> budgets, String categoryId, DateTime month) {
  final m = monthOf(month);
  Budget? best;
  for (final b in budgets) {
    if (b.categoryId != categoryId) continue;
    if (b.month.isAfter(m)) continue;
    if (best == null || b.month.isAfter(best.month)) best = b;
  }
  return best?.limit;
}

/// 某分類某月的支出合計（僅 expense；scope 由呼叫端先過濾好）。
int spentIn(Iterable<Entry> entries, String categoryId, DateTime month) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense || e.categoryId != categoryId) continue;
    if (!sameMonth(e.occurredOn, month)) continue;
    sum += e.amount;
  }
  return sum;
}

/// 有效上限：基礎上限＋（上月有效上限−上月支出），rollover 開啟時從記帳起點遞推，正負都帶。
/// 起點＝該分類最早的 budget 月與最早的 entry 月兩者較早者；起點前視為無 rollover。
int? effectiveLimit({
  required List<Budget> budgets,
  required Iterable<Entry> entries,
  required Category category,
  required DateTime month,
}) {
  final target = monthOf(month);
  final base = baseLimit(budgets, category.id, target);
  if (base == null) return null;
  if (!category.rollover) return base;

  DateTime? start;
  for (final b in budgets) {
    if (b.categoryId == category.id && (start == null || b.month.isBefore(start))) start = b.month;
  }
  for (final e in entries) {
    if (e.categoryId == category.id) {
      final m = monthOf(e.occurredOn);
      if (start == null || m.isBefore(start)) start = m;
    }
  }
  if (start == null || !start.isBefore(target)) return base;

  int? carry;
  var m = start;
  while (m.isBefore(target)) {
    final b = baseLimit(budgets, category.id, m);
    if (b == null) {
      carry = null; // 該月沒預算，rollover 鏈中斷
    } else {
      final eff = b + (carry ?? 0);
      carry = eff - spentIn(entries, category.id, m);
    }
    m = nextMonth(m);
  }
  return base + (carry ?? 0);
}

/// 累計餘額：期初＋Σ收入−Σ支出，計到 [until] 當日（含）。
int runningBalance({required int opening, required Iterable<Entry> entries, required DateTime until}) {
  var bal = opening;
  for (final e in entries) {
    if (e.occurredOn.isAfter(until)) continue;
    bal += e.isExpense ? -e.amount : e.amount;
  }
  return bal;
}

/// 個人視角下一筆 entry 對「我」的金額：私人全額；共同支出取我的分攤（common 依 ratio）；共同收入依 ratio。
int myPortion(Entry e, String memberId, Map<String, int> defaultRatio) {
  if (e.scope == EntryScope.private) return e.createdBy == memberId ? e.amount : 0;
  final ratio = (defaultRatio[memberId] ?? 0) / 100.0;
  if (e.isExpense && e.splitMethod != SplitMethod.common && e.splits.isNotEmpty) {
    for (final s in e.splits) {
      if (s.memberId == memberId) return s.share.round();
    }
    return 0;
  }
  return (e.amount * ratio).round();
}
