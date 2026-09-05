/// 三個數與預算的純函式（spec v1.5「餘額、補入與預算」節、ADR-0009）。
///
/// 這裡是前端這一側的「錢公式」；DB 那一側的唯一實作是 v1.5 migration 的
/// `month_summary`／`month_close_details`。兩邊必須逐條對得起來——
/// `InMemoryLedgerRepository.monthSummary` 用這裡的函式組出與 DB 同形狀的結果，
/// 契約測試再拿同一組斷言跑兩個實作。
///
/// 三個數（每個只有一個來源）：
/// - 共同餘額＝Σ共同收入 − Σ共同錢包支出（`payerId == null`）。補入與清帳明細一律不動它。
/// - 個人補入剩餘（每人每月）＝Σ該月補入 − Σ該月本人先付的支出，可為負。
/// - 分類預算剩餘（每月影子）＝預算 − 該分類該月**全部**支出（不分誰付）。
///
/// 共通約定：
/// - 所有「計到 [until] 當日含」的比較都先把日期截成 date-only 再比。DB 的
///   `occurred_on` 是 `date`，但前端可能拿到帶時間分量的 [DateTime]（例如
///   `DateTime.now()`）；不截就會漏算當日。
/// - 預算與補入只看某個月：不跨月、不帶入上月剩餘、不帶入上月超支。
library;

import 'models.dart';

DateTime monthOf(DateTime d) => DateTime(d.year, d.month, 1);
DateTime prevMonth(DateTime m) => DateTime(m.year, m.month - 1, 1);
DateTime nextMonth(DateTime m) => DateTime(m.year, m.month + 1, 1);
bool sameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

/// 截成 date-only。
DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// [on] 是否在 [until] 當日（含）之前，只比日期。
bool _upTo(DateTime on, DateTime until) => !_day(on).isAfter(_day(until));

int _clamp0(int v) => v < 0 ? 0 : v;

// ── 共同餘額 ────────────────────────────────────────────────────────────

/// 共同餘額＝實體共同帳戶：Σ共同收入 − Σ共同錢包支出（`payerId == null`）。
///
/// **只有手動記的收入與共同錢包支出會動它**：補入、成員先付、預算、清帳明細一律不動
/// （spec v1.5「三個數」）。所以它不吃 `topups`，也不吃 `closes`；v1.5 起也沒有期初餘額。
/// 清帳的「一鍵記共同收入」記的是一筆真的 income entry，所以走的仍是這條同一條路。
int sharedBalance({
  required Iterable<Entry> entries,
  required DateTime until,
}) {
  var bal = 0;
  for (final e in entries) {
    if (!_upTo(e.occurredOn, until)) continue;
    if (e.isExpense) {
      if (e.payerId == null) bal -= e.amount;
    } else {
      bal += e.amount;
    }
  }
  return bal;
}

// ── 個人補入剩餘（每人每月）────────────────────────────────────────────

/// [memberId] 在 [month] 所在月的補入合計。
///
/// 只看月份不夾 until：補入是「這個月自己預留出來的錢」，清帳也是整月結算，
/// 沒有「算到月中」的語意（與 DB `month_summary` 的 `topup` CTE 同）。
int topupIn({
  required Iterable<PersonalTopup> topups,
  required String memberId,
  required DateTime month,
}) {
  var sum = 0;
  for (final t in topups) {
    if (t.memberId != memberId) continue;
    if (!sameMonth(t.occurredOn, month)) continue;
    sum += t.amount;
  }
  return sum;
}

/// [memberId] 在 [month] 所在月**先付**的支出合計（`payerId == memberId`）。
///
/// 沖銷筆是負金額，照樣相加——漏掉它們的話補入剩餘會永遠停在沖銷前的水位。
int paidIn({
  required Iterable<Entry> entries,
  required String memberId,
  required DateTime month,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense || e.payerId != memberId) continue;
    if (!sameMonth(e.occurredOn, month)) continue;
    sum += e.amount;
  }
  return sum;
}

/// 補入剩餘＝[topupIn] − [paidIn]。**可為負**（先付超過補入），不夾 0。
int topupRemaining({
  required Iterable<PersonalTopup> topups,
  required Iterable<Entry> entries,
  required String memberId,
  required DateTime month,
}) =>
    topupIn(topups: topups, memberId: memberId, month: month) -
    paidIn(entries: entries, memberId: memberId, month: month);

/// [month] 所在月由共同錢包（`payerId == null`）付掉的支出合計。
///
/// 清帳明細的對照欄；不進任何人的月末。
int sharedPaidIn({
  required Iterable<Entry> entries,
  required DateTime month,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense || e.payerId != null) continue;
    if (!sameMonth(e.occurredOn, month)) continue;
    sum += e.amount;
  }
  return sum;
}

// ── 預算（影子紀錄）────────────────────────────────────────────────────

/// 該分類在 [month] 所在月的預算：0 或那一筆的金額。
///
/// **刻意不篩 `occurredOn <= until`**（與 DB `month_summary` 的 `alloc` CTE 同）：
/// 預算是「當月的影子紀錄」，設定當下就對整個月生效，不該因為問的日子早於設定日而消失。
/// DB 有 `unique (ledger_id, category_id, month)`，同月多筆是資料異常——這裡取合計，
/// 讓異常看得見（顯示成一個偏大的預算），而不是靜靜取第一筆。
int allocatedIn({
  required Iterable<BudgetAllocation> allocations,
  required String categoryId,
  required DateTime month,
}) {
  var sum = 0;
  for (final a in allocations) {
    if (a.categoryId != categoryId) continue;
    if (!sameMonth(a.occurredOn, month)) continue;
    sum += a.amount;
  }
  return sum;
}

/// 該分類在 [until] 所在月、`occurredOn ≤ until` 的**全部**支出合計。
///
/// 不分誰付：共同錢包付的與成員先付的都算（spec v1.5「分類預算剩餘」）。
int spentIn({
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense) continue;
    if (e.categoryId != categoryId) continue;
    if (!sameMonth(e.occurredOn, until) || !_upTo(e.occurredOn, until)) continue;
    sum += e.amount;
  }
  return sum;
}

/// 剩餘＝max(0, 預算 − 已花)。
int remainingIn({
  required Iterable<BudgetAllocation> allocations,
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) =>
    _clamp0(allocatedIn(allocations: allocations, categoryId: categoryId, month: until) -
        spentIn(entries: entries, categoryId: categoryId, until: until));

/// 超支＝max(0, 已花 − 預算)，隨時重算。
int overspend({
  required Iterable<BudgetAllocation> allocations,
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) =>
    _clamp0(spentIn(entries: entries, categoryId: categoryId, until: until) -
        allocatedIn(allocations: allocations, categoryId: categoryId, month: until));

/// [until] 所在月「有預算或有支出」的分類。
///
/// 兩側的篩選條件與 [allocatedIn]／[spentIn] 逐字一致（預算不看日、已花看日），
/// 對應 DB `month_summary` 裡 `alloc full outer join spent` 的那一組 key。
Set<String> budgetCategoryIds({
  required Iterable<BudgetAllocation> allocations,
  required Iterable<Entry> entries,
  required DateTime until,
}) {
  final ids = <String>{};
  for (final a in allocations) {
    if (sameMonth(a.occurredOn, until)) ids.add(a.categoryId);
  }
  for (final e in entries) {
    if (!e.isExpense) continue;
    if (sameMonth(e.occurredOn, until) && _upTo(e.occurredOn, until)) ids.add(e.categoryId);
  }
  return ids;
}

/// 該月所有分類的預算合計（預算頁頂部「本月預算」）。
int totalAllocated({
  required Iterable<BudgetAllocation> allocations,
  required DateTime month,
}) {
  var sum = 0;
  for (final a in allocations) {
    if (sameMonth(a.occurredOn, month)) sum += a.amount;
  }
  return sum;
}

/// [until] 所在月、`occurredOn ≤ until` 的**全部**支出合計（預算頁頂部「本月支出」）。
int totalSpent({
  required Iterable<Entry> entries,
  required DateTime until,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense) continue;
    if (!sameMonth(e.occurredOn, until) || !_upTo(e.occurredOn, until)) continue;
    sum += e.amount;
  }
  return sum;
}

/// 該月所有分類的超支合計。
int totalOverspend({
  required Iterable<Entry> entries,
  required Iterable<BudgetAllocation> allocations,
  required DateTime until,
}) {
  var sum = 0;
  for (final id in budgetCategoryIds(allocations: allocations, entries: entries, until: until)) {
    sum += overspend(allocations: allocations, entries: entries, categoryId: id, until: until);
  }
  return sum;
}

// ── 清帳 ────────────────────────────────────────────────────────────────

/// [date] 所在月是否已清帳。
///
/// 判準是「月份 ≤ closes 中最大的月」，**不是「有沒有那一列」**（db-contract：全庫同一個定義）：
/// 清帳只能按序往後推進，補記到清帳月之前的月份永遠不會再是「下一個可清月」，
/// 所以連同更早的月份一起鎖。
bool isMonthClosed(Iterable<MonthClose> closes, DateTime date) {
  DateTime? last;
  for (final c in closes) {
    final m = monthOf(c.month);
    if (last == null || m.isAfter(last)) last = m;
  }
  if (last == null) return false;
  return !monthOf(date).isAfter(last);
}
