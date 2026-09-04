/// 餘額與預算的純函式（spec v1.3「餘額與預算」節、ADR-0007）。取代 budget_math。
///
/// 共通約定：
/// - 所有「計到 [until] 當日含」的比較都先把日期截成 date-only 再比。DB 的
///   `occurred_on` 是 `date`，但前端可能拿到帶時間分量的 [DateTime]（例如
///   `DateTime.now()`）；不截就會漏算當日（舊 `runningBalance` 的既有雷）。
/// - 信封（預算）只看 [until] 所在的那個月：上月剩餘不帶入、上月超支不帶入。
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

/// 共同餘額＝實體共同帳戶：期初 ＋ Σ共同收入 − Σ共同錢包支出。
///
/// **代墊（`payerId` 非 null）不動共同餘額**（走個人對個人，見 [personalBalance]），
/// 共同錢包支出不分 funding（信封的錢本來就是共同帳戶裡的錢）。
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

// ── 信封（預算）────────────────────────────────────────────────────────

/// 該分類在 [until] 所在月的撥款合計（含退回的負數），只算 `occurredOn ≤ until`。
int allocatedIn({
  required Iterable<BudgetAllocation> allocations,
  required String categoryId,
  required DateTime until,
}) {
  var sum = 0;
  for (final a in allocations) {
    if (a.categoryId != categoryId) continue;
    if (!sameMonth(a.occurredOn, until) || !_upTo(a.occurredOn, until)) continue;
    sum += a.amount;
  }
  return sum;
}

/// 該分類在 [until] 所在月的「預算支出」：`funding == budget` 的共同錢包支出。
int budgetSpentIn({
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) {
  var sum = 0;
  for (final e in entries) {
    if (!e.isExpense || e.scope != EntryScope.shared) continue;
    if (e.payerId != null || e.funding != Funding.budget) continue;
    if (e.categoryId != categoryId) continue;
    if (!sameMonth(e.occurredOn, until) || !_upTo(e.occurredOn, until)) continue;
    sum += e.amount;
  }
  return sum;
}

/// 信封剩餘＝max(0, 當月撥款 − 當月預算支出)。
int envelopeRemaining({
  required Iterable<BudgetAllocation> allocations,
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) =>
    _clamp0(allocatedIn(allocations: allocations, categoryId: categoryId, until: until) -
        budgetSpentIn(entries: entries, categoryId: categoryId, until: until));

/// 超支＝max(0, 當月預算支出 − 當月撥款)，隨時重算（補撥即回補）。
int overspend({
  required Iterable<BudgetAllocation> allocations,
  required Iterable<Entry> entries,
  required String categoryId,
  required DateTime until,
}) =>
    _clamp0(budgetSpentIn(entries: entries, categoryId: categoryId, until: until) -
        allocatedIn(allocations: allocations, categoryId: categoryId, until: until));

/// 表單／結帳的資金來源預設（spec v1.3「資金來源」條）：該分類在 [month] 所在月的撥款
/// 合計（含退回抵消）> 0 → [Funding.budget]，否則 [Funding.balance]。只看月份，不看
/// [month] 在當月的日序（不同於 [allocatedIn] 的 `until` 語意）——同月稍後才撥的款，
/// 當月較早的支出一樣算「這個月有撥款」。
Funding defaultFunding({
  required Iterable<BudgetAllocation> allocations,
  required String categoryId,
  required DateTime month,
}) {
  var sum = 0;
  for (final a in allocations) {
    if (a.categoryId != categoryId || !sameMonth(a.occurredOn, month)) continue;
    sum += a.amount;
  }
  return sum > 0 ? Funding.budget : Funding.balance;
}

/// 有信封活動的分類（當月有撥款或有預算支出的），供跨分類加總用。
///
/// 不吃 `categories` 是刻意的：沒撥款也沒預算支出的分類，[envelopeRemaining] 與
/// [overspend] 恆為 0，加不加都一樣，少一個參數就少一個呼叫端傳錯的機會。
Set<String> envelopeCategoryIds({
  required Iterable<BudgetAllocation> allocations,
  required Iterable<Entry> entries,
  required DateTime until,
}) {
  final ids = <String>{};
  for (final a in allocations) {
    if (sameMonth(a.occurredOn, until) && _upTo(a.occurredOn, until)) ids.add(a.categoryId);
  }
  for (final e in entries) {
    if (!e.isExpense || e.scope != EntryScope.shared) continue;
    if (e.payerId != null || e.funding != Funding.budget) continue;
    if (sameMonth(e.occurredOn, until) && _upTo(e.occurredOn, until)) ids.add(e.categoryId);
  }
  return ids;
}

/// 共同可用餘額＝共同餘額 − 當月信封剩餘合計（撥款當下即從可用餘額預扣）。
int sharedAvailable({
  required Ledger ledger,
  required Iterable<Entry> entries,
  required Iterable<BudgetAllocation> allocations,
  required DateTime until,
}) {
  var available = sharedBalance(ledger: ledger, entries: entries, until: until);
  for (final id in envelopeCategoryIds(allocations: allocations, entries: entries, until: until)) {
    available -= envelopeRemaining(
      allocations: allocations,
      entries: entries,
      categoryId: id,
      until: until,
    );
  }
  return available;
}

/// 當月所有分類的超支合計。
int totalOverspend({
  required Iterable<Entry> entries,
  required Iterable<BudgetAllocation> allocations,
  required DateTime until,
}) {
  var sum = 0;
  for (final id in envelopeCategoryIds(allocations: allocations, entries: entries, until: until)) {
    sum += overspend(allocations: allocations, entries: entries, categoryId: id, until: until);
  }
  return sum;
}

/// 當月所有分類的信封剩餘合計（預算頁頂部的「信封總額」）。
int totalEnvelopeRemaining({
  required Iterable<Entry> entries,
  required Iterable<BudgetAllocation> allocations,
  required DateTime until,
}) {
  var sum = 0;
  for (final id in envelopeCategoryIds(allocations: allocations, entries: entries, until: until)) {
    sum += envelopeRemaining(
      allocations: allocations,
      entries: entries,
      categoryId: id,
      until: until,
    );
  }
  return sum;
}

// ── 個人餘額 ────────────────────────────────────────────────────────────

/// 個人餘額（ADR-0007）：
/// 期初 ＋ Σ本人私人收入 − Σ本人私人支出 − Σ本人代墊的共同支出**全額**
/// ＋ Σ已 settled 且 `settledAt ≤ until` 的結算 `nets[member.id]`。
///
/// 代墊在記帳當下就把全額扣在付款人身上（**不論 settled 與否**），結算全簽完
/// 那一刻用 nets 把多付的部分還回來；共同收入不進個人餘額。
int personalBalance({
  required Member member,
  required Iterable<Entry> entries,
  required Iterable<Settlement> settlements,
  required DateTime until,
}) {
  var bal = member.openingBalancePersonal;
  for (final e in entries) {
    if (!_upTo(e.occurredOn, until)) continue;
    // 私人筆只動本人（spec：私人筆的 payer 固定是 created_by）。
    if (e.scope == EntryScope.private && e.createdBy == member.id) {
      bal += e.isExpense ? -e.amount : e.amount;
    }
    // 代墊：共同支出的付款人在記帳當下扣全額。條件必須寫足 `scope == shared`——
    // 私人支出的 payerId 也是本人，少這個判斷會被扣兩次（不靠 else 的順序保護）。
    if (e.scope == EntryScope.shared && e.isExpense && e.payerId == member.id) {
      bal -= e.amount;
    }
  }
  for (final s in settlements) {
    if (s.status != SettlementStatus.settled) continue;
    final at = s.settledAt;
    if (at == null || !_upTo(at, until)) continue;
    bal += s.nets[member.id] ?? 0;
  }
  return bal;
}

/// 個人沒有信封，可用餘額＝餘額。
int personalAvailable({
  required Member member,
  required Iterable<Entry> entries,
  required Iterable<Settlement> settlements,
  required DateTime until,
}) =>
    personalBalance(member: member, entries: entries, settlements: settlements, until: until);

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
