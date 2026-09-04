/// 餘額與預算的純函式（spec v1.4「餘額與預算」「清帳」節、ADR-0008）。
///
/// 這裡是前端這一側的「錢公式」；DB 那一側的唯一實作是
/// `supabase/migrations/20260904000200_rules_v14.sql` 的 `entry_member_effects`
/// ＋ `topup_for` ＋ `month_summary`。兩邊必須逐條對得起來——
/// `InMemoryLedgerRepository.monthSummary` 用這裡的函式組出與 DB 同形狀的結果，
/// 契約測試再拿同一組斷言跑兩個實作。
///
/// 共通約定：
/// - 所有「計到 [until] 當日含」的比較都先把日期截成 date-only 再比。DB 的
///   `occurred_on` 是 `date`，但前端可能拿到帶時間分量的 [DateTime]（例如
///   `DateTime.now()`）；不截就會漏算當日。
/// - 預算只看某個月：不跨月、不帶入上月剩餘、不帶入上月超支。
/// - v1.4 沒有「資金來源」與「信封預扣」：共同可用餘額＝共同餘額，預算純屬影子紀錄。
library;

import 'models.dart';

DateTime monthOf(DateTime d) => DateTime(d.year, d.month, 1);
DateTime prevMonth(DateTime m) => DateTime(m.year, m.month - 1, 1);
DateTime nextMonth(DateTime m) => DateTime(m.year, m.month + 1, 1);
bool sameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

/// 截成 date-only。`view_math` 也有同名工具，這裡刻意保持私有避免匯入衝突。
DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// [on] 是否在 [until] 當日（含）之前，只比日期。
bool _upTo(DateTime on, DateTime until) => !_day(on).isAfter(_day(until));

int _clamp0(int v) => v < 0 ? 0 : v;

// ── 共同餘額 ────────────────────────────────────────────────────────────

/// 共同餘額＝實體共同帳戶：期初 ＋ Σ共同收入 − Σ共同錢包支出（`payerId == null`）。
///
/// **只有手動記的共同收入與共同錢包支出會動它**：預算、代墊、結算、清帳一律不動
/// （spec v1.4「餘額與預算」）。所以它不吃 `allocations`，也不吃 `closes`。
int sharedBalance({
  required Ledger ledger,
  required Iterable<Entry> entries,
  required DateTime until,
}) {
  var bal = ledger.openingBalanceShared;
  for (final e in entries) {
    if (e.scope != EntryScope.shared) continue;
    if (!_upTo(e.occurredOn, until)) continue;
    if (e.isExpense) {
      if (e.payerId == null) bal -= e.amount;
    } else {
      bal += e.amount;
    }
  }
  return bal;
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

/// 該分類在 [until] 所在月、`occurredOn ≤ until` 的**所有**共同支出合計。
///
/// 不分 payer：共同錢包付的與代墊的都算（spec v1.4「已花」）；私人筆不算。
int spentIn({
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense || e.scope != EntryScope.shared) continue;
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

/// [until] 所在月「有預算或有共同支出」的分類。
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
    if (!e.isExpense || e.scope != EntryScope.shared) continue;
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

/// [until] 所在月、`occurredOn ≤ until` 的共同支出合計（預算頁頂部「本月共同支出」）。
int totalSpent({
  required Iterable<Entry> entries,
  required DateTime until,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense || e.scope != EntryScope.shared) continue;
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

// ── 個人餘額（v1.4 額度制）──────────────────────────────────────────────

/// 一筆帳目的各成員**整數份額**（最大餘數法）。
///
/// 全員先 `floor`，差額（[Entry.amount] − Σfloor）依小數由大到小各補 1，
/// 同小數以 `memberId` 字串序決定先後——與 DB `entry_member_effects`／
/// `initiate_settlement` 同法。所以同一筆的各成員整數份額合計恰等於主筆金額；
/// 逐筆 `round()` 會漏／溢一元（567 均分兩人 → 284＋284 ＝ 568）。
///
/// 沖銷筆（負 amount、負 share）沿同一條公式：`floor(-283.5) == -284`，
/// 差額 1 補回去就是 −283／−284，合計 −567。
Map<String, int> integerShares(Entry e) {
  if (e.splits.isEmpty) return const {};
  final floors = <String, int>{};
  final fracs = <String, double>{};
  var sumFloor = 0;
  for (final s in e.splits) {
    final f = s.share.floor();
    floors[s.memberId] = f;
    fracs[s.memberId] = s.share - f;
    sumFloor += f;
  }
  final diff = e.amount - sumFloor;
  final order = floors.keys.toList()
    ..sort((a, b) {
      final byFrac = fracs[b]!.compareTo(fracs[a]!);
      return byFrac != 0 ? byFrac : a.compareTo(b);
    });
  final result = <String, int>{for (final id in order) id: floors[id]!};
  // 差額為負（分攤合計 > 金額，資料異常）時一個都不補——與 DB 的 `row_number <= diff` 同。
  for (var i = 0; i < diff && i < order.length; i++) {
    result[order[i]] = result[order[i]]! + 1;
  }
  return result;
}

/// 一筆帳目對 [memberId] 個人餘額的影響。
///
/// 三段的條件**逐字照抄** DB view `entry_member_effects` 的三個 `where`，順序也一樣：
/// 1. `scope == private` → 只影響 `createdBy` 本人（收入 ＋amount、支出 −amount）；
/// 2. `scope == shared && kind == expense && payerId != null && settledState != settled`
///    → 付款人先扛全額；
/// 3. `scope == shared && kind == expense && payerId != null && settledState == settled`
///    → 每位有分攤列的成員各扛自己的整數份額（付款人也只扛自己那份）。
///
/// 三段**互斥**（private 那段直接 return）：本專案的私人筆 `payerId == createdBy`
/// （DB check `entries_private_payer`），少了這道互斥就會被第 2 段再扣一次全額。
/// 共同收入與共同錢包支出（`payerId == null`）三段都不落，所以不動個人餘額。
int _memberDelta(Entry e, String memberId) {
  // 段 1：私人筆。
  if (e.scope == EntryScope.private) {
    if (e.createdBy != memberId) return 0;
    return e.isExpense ? -e.amount : e.amount;
  }
  if (e.scope != EntryScope.shared || !e.isExpense || e.payerId == null) return 0;
  // 段 2：未結算代墊。
  if (e.settledState != SettledState.settled) {
    return e.payerId == memberId ? -e.amount : 0;
  }
  // 段 3：已結算共同支出。
  return -(integerShares(e)[memberId] ?? 0);
}

/// 成員在 [month] 所在月的淨變動（spec v1.4「該月淨變動」）。
///
/// ＝ Σ本人私人（收入＋／支出−） − Σ本人**未結算**代墊的全額
///   − Σ**已結算**共同支出中本人的整數份額。
/// 共同收入與共同錢包支出不進個人。[until] 給了就再篩 `occurredOn ≤ until`。
int monthNet({
  required Member member,
  required Iterable<Entry> entries,
  required DateTime month,
  DateTime? until,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!sameMonth(e.occurredOn, month)) continue;
    if (until != null && !_upTo(e.occurredOn, until)) continue;
    sum += _memberDelta(e, member.id);
  }
  return sum;
}

/// [date] 所在月是否已清帳。
///
/// 判準是「月份 ≤ closes 中最大的月」，**不是「有沒有那一列」**（db-contract：全庫同一個定義）：
/// 清帳只能按序往後推進，補記到清帳月之前的月份永遠不會再是「下一個可清月」，
/// 所以連同更早的月份一起鎖，那些帳目的影響才不會永久留在個人餘額裡。
bool isMonthClosed(Iterable<MonthClose> closes, DateTime date) {
  DateTime? last;
  for (final c in closes) {
    final m = monthOf(c.month);
    if (last == null || m.isAfter(last)) last = m;
  }
  if (last == null) return false;
  return !monthOf(date).isAfter(last);
}

/// 個人餘額（spec v1.4／ADR-0008）＝ 每月補入額 × N ＋ Σ（未清帳月份的淨變動）。
///
/// - N ＝ [[joinedMonth], min([until] 所在月, [today] 所在月)] 之間**未清帳**的月份數；
///   [joinedMonth] 晚於那個上界時 N ＝ 0。上界夾在本月是因為補入額是「每個月實際補進來的錢」，
///   還沒到的月份不該先算給你（與 DB 的 `v_n_upper` 同）。
///   [today] 預設 `DateTime.now()`，只有測試會傳固定值（把「今天」從斷言裡拿掉）。
/// - 淨變動只算 `occurredOn ≤ until` 且所在月未清帳的帳目；[until] 本身**不夾上界**
///   （問下個月要拿得到下個月的數字）。
/// - 期初個人餘額（`Member.openingBalancePersonal`）v1.4 起完全不入公式。
///
/// [joinedMonth] 由呼叫端以本地時區從 `member.joinedAt` 取月初（DB 那側是台北時區）。
int personalBalance({
  required Member member,
  required Iterable<Entry> entries,
  required Iterable<MonthClose> closes,
  required DateTime until,
  required DateTime joinedMonth,
  DateTime? today,
}) {
  final upper = _minMonth(monthOf(until), monthOf(today ?? DateTime.now()));
  var months = 0;
  var m = monthOf(joinedMonth);
  while (!m.isAfter(upper)) {
    if (!isMonthClosed(closes, m)) months++;
    m = nextMonth(m);
  }
  var bal = member.monthlyTopup * months;
  for (final e in entries) {
    if (!_upTo(e.occurredOn, until)) continue;
    if (isMonthClosed(closes, e.occurredOn)) continue;
    bal += _memberDelta(e, member.id);
  }
  return bal;
}

DateTime _minMonth(DateTime a, DateTime b) => a.isAfter(b) ? b : a;

// ── 視角換算 ────────────────────────────────────────────────────────────

/// 個人視角下一筆 entry 對「我」的金額：私人全額；共同支出取我的分攤（common 依 ratio）；
/// 共同收入＝0——spec：共同收入進共同餘額，不進任何人的個人視角（與 [personalBalance] 一致）。
int myPortion(Entry e, String memberId, Map<String, int> defaultRatio) {
  if (e.scope == EntryScope.private) return e.createdBy == memberId ? e.amount : 0;
  if (!e.isExpense) return 0;
  final ratio = (defaultRatio[memberId] ?? 0) / 100.0;
  if (e.splitMethod != SplitMethod.common && e.splits.isNotEmpty) {
    for (final s in e.splits) {
      if (s.memberId == memberId) return s.share.round();
    }
    return 0;
  }
  return (e.amount * ratio).round();
}
