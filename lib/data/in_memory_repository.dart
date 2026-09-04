/// 記憶體版 repository：波 1 的假資料與行為搬過來的地方。
///
/// 用途有二：`flutter test`（所有 widget 測試的預設資料來源）與
/// `--dart-define=USE_MOCK=true`（不連網跑整個 App）。結算在這裡是本地模擬——
/// 真正的原子性與多簽守衛在 Postgres，這份只是讓畫面跑得動。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/balance_math.dart';
import '../domain/models.dart';
import '../domain/month_summary.dart';
import '../features/entries/settlement_math.dart';
import 'errors.dart';
import 'ledger_repository.dart';

const kLedgerId = 'ledger-1';
const kMeId = 'm-mike';
const kWifeId = 'm-wife';

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

class InMemoryLedgerRepository implements LedgerRepository {
  /// [seed] 給測試指定初始內容（不給就是波 1 的那組假資料）。
  InMemoryLedgerRepository({LedgerSnapshot? seed}) {
    if (seed == null) {
      _reseed();
    } else {
      _load(seed);
    }
  }

  void _load(LedgerSnapshot s) {
    _cleared = false;
    _ledger = s.ledger;
    _members = [...s.members];
    _categories = [...s.categories];
    _entries = [...s.entries];
    _allocations = [...s.allocations];
    _listItems = [...s.listItems];
    _settlements = [...s.settlements];
    _closes = [...s.closes];
    _currentMemberId = s.currentMemberId;
  }

  late Ledger _ledger;
  late List<Member> _members;
  late List<Category> _categories;
  late List<Entry> _entries;
  late List<BudgetAllocation> _allocations;
  late List<ListItem> _listItems;
  late List<Settlement> _settlements;
  late List<MonthClose> _closes;
  String _currentMemberId = kMeId;
  bool _cleared = false;
  int _seq = 0;

  /// 測試用：切換「目前登入者」。這份實作本身就是測試替身，換人是它該提供的能力
  /// （Supabase 版對應的是換一個登入 session）。
  @visibleForTesting
  set currentMemberId(String id) => _currentMemberId = id;

  /// 本機端唯一 id（Supabase 版由 DB 產生）。
  String _newId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}-${++_seq}';

  // ── 快照 ────────────────────────────────────────────────────────────

  @override
  LedgerSnapshot get snapshot => _cleared
      ? LedgerSnapshot.empty()
      : LedgerSnapshot(
          ledger: _ledger,
          members: List.unmodifiable(_members),
          categories: List.unmodifiable(_categories),
          entries: List.unmodifiable(_entries),
          allocations: List.unmodifiable(_allocations),
          listItems: List.unmodifiable(_listItems),
          settlements: List.unmodifiable(_settlements),
          closes: List.unmodifiable(_closes),
          currentMemberId: _currentMemberId,
        );

  @override
  Future<LedgerSnapshot> loadSnapshot(String ledgerId) async {
    _cleared = false;
    return snapshot;
  }

  @override
  void clearSnapshot() => _cleared = true;

  // ── 帳本層 ──────────────────────────────────────────────────────────

  @override
  Future<List<Ledger>> myLedgers() async => [_ledger];

  @override
  Future<Ledger> createLedger(String name) async {
    _reseedEmpty(name);
    return _ledger;
  }

  @override
  Future<Ledger> joinLedger(String code) async {
    if (code.trim().toUpperCase() != _ledger.inviteCode) {
      throw const LedgerException('邀請碼不正確');
    }
    _cleared = false;
    return _ledger;
  }

  @override
  Future<Ledger> rotateInviteCode(String ledgerId) async {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final micros = DateTime.now().microsecondsSinceEpoch;
    final code = [for (var i = 0; i < 10; i++) alphabet[(micros >> (i * 3)) % alphabet.length]].join();
    _ledger = Ledger(
      id: _ledger.id,
      name: _ledger.name,
      inviteCode: code,
      defaultRatio: _ledger.defaultRatio,
      openingBalanceShared: _ledger.openingBalanceShared,
    );
    return _ledger;
  }

  @override
  Future<void> updateLedger(Ledger ledger) async => _ledger = ledger;

  @override
  Future<void> updateMember(Member member) async {
    // DB check `members_monthly_topup_range`（0 ≤ monthly_topup ≤ 1 億）在這裡也要擋：
    // 少了它，UI 送出超界值在替身上會「存成功」，線上卻被 Postgres 打回——
    // 兩個實作對同一個輸入必須給同一個答案（訊息也走 errors.dart 的同一張表）。
    if (member.monthlyTopup < 0 || member.monthlyTopup > 100000000) {
      _raiseDb('violates check constraint "members_monthly_topup_range"');
    }
    _members = [for (final m in _members) m.id == member.id ? member : m];
  }

  @override
  Future<Ledger> fetchLedger(String ledgerId) async => _ledger;

  @override
  Future<List<Member>> fetchMembers(String ledgerId) async => List.unmodifiable(_members);

  // ── 分類 ────────────────────────────────────────────────────────────

  @override
  Future<List<Category>> fetchCategories(String ledgerId) async => List.unmodifiable(_categories);

  @override
  Future<Category> addCategory(Category category) async {
    final saved = category.id.isEmpty ? _withCategoryId(category, _newId('c')) : category;
    _categories = [..._categories, saved];
    return saved;
  }

  @override
  Future<void> updateCategory(Category category) async =>
      _categories = [for (final c in _categories) c.id == category.id ? category : c];

  @override
  Future<void> removeCategory(String id) async =>
      _categories = _categories.where((c) => c.id != id).toList();

  @override
  Future<void> saveCategoryOrder(List<Category> ordered) async {
    final byId = {for (final c in ordered) c.id: c};
    _categories = [for (final c in _categories) byId[c.id] ?? c];
  }

  // ── 帳目 ────────────────────────────────────────────────────────────

  @override
  Future<List<Entry>> fetchEntries(String ledgerId) async => List.unmodifiable(_entries);

  @override
  Future<Entry> upsertEntry(Entry entry, {bool writeSplits = true, bool writeLineItems = true}) async {
    final existing = entry.id.isEmpty ? null : _findEntry(entry.id);
    final settled = existing != null && existing.settledState == SettledState.settled;

    // 三道守衛的先後**逐段對齊真 DB**（同一筆同時踩兩道時，兩個實作要吐同一句）：
    //   1. `upsert_entry` RPC 自己的 settled 子表守衛——在 UPDATE 之前就 raise，
    //      所以排在鎖月之前（`rules_v14.sql` 的 `entry settled: child tables locked`）；
    //   2. UPDATE 觸發 trigger，依名稱字母序 `a_entries_month_closed_trg` 先跑（鎖月）；
    //   3. 最後才是 `entries_lock_settled_trg` 的欄位級鎖定。
    if (settled && (writeSplits || writeLineItems)) {
      throw const LedgerException('這筆已結帳，只能改分類與備註');
    }

    // 鎖月（v1.4）：新值與舊值兩個月都要看——「把日期搬進鎖定範圍」與「動鎖定範圍裡的帳目」
    // 都要擋（對應 `a_entries_month_closed_trg` 的 update 兩側檢查）。
    _requireMonthOpen(entry.occurredOn);
    if (existing != null) _requireMonthOpen(existing.occurredOn);

    if (settled) {
      // 已結帳只能改分類與備註，其餘欄位一律 raise（不是靜靜忽略——
      // 靜靜忽略會讓記憶體版比真 DB 寬鬆，正式環境才炸）。
      if (entry.amount != existing.amount) {
        throw const LedgerException('這筆已結帳，金額鎖住，請改用修正筆');
      }
      if (entry.payerId != existing.payerId) {
        throw const LedgerException('這筆已結帳，付款人鎖住，請改用修正筆');
      }
      if (entry.splitMethod != existing.splitMethod) {
        throw const LedgerException('這筆已結帳，分攤方式鎖住，請改用修正筆');
      }
      if (entry.scope != existing.scope) {
        throw const LedgerException('這筆已結帳，共同／私人鎖住，請改用修正筆');
      }
      if (entry.kind != existing.kind) {
        throw const LedgerException('這筆已結帳，收入／支出鎖住，請改用修正筆');
      }
      if (_d(entry.occurredOn.year, entry.occurredOn.month, entry.occurredOn.day) !=
          _d(existing.occurredOn.year, existing.occurredOn.month, existing.occurredOn.day)) {
        throw const LedgerException('這筆已結帳，日期鎖住，請改用修正筆');
      }
      final merged = existing.copyWith(categoryId: entry.categoryId, note: entry.note);
      _entries = [for (final e in _entries) e.id == merged.id ? merged : e];
      return merged;
    }

    final id = entry.id.isEmpty ? _newId('e') : entry.id;
    final splits = writeSplits
        ? [for (final s in entry.splits) EntrySplit(entryId: id, memberId: s.memberId, share: s.share)]
        : (existing?.splits ?? const <EntrySplit>[]);
    final lineItems = writeLineItems
        ? [
            for (var i = 0; i < entry.lineItems.length; i++)
              LineItem(
                id: entry.lineItems[i].id.isEmpty ? _newId('li') : entry.lineItems[i].id,
                entryId: id,
                name: entry.lineItems[i].name,
                amount: entry.lineItems[i].amount,
                sort: entry.lineItems[i].sort,
              ),
          ]
        : (existing?.lineItems ?? const <LineItem>[]);

    final saved = Entry(
      id: id,
      ledgerId: existing?.ledgerId ?? entry.ledgerId,
      kind: entry.kind,
      scope: entry.scope,
      amount: entry.amount,
      categoryId: entry.categoryId,
      occurredOn: entry.occurredOn,
      createdBy: existing?.createdBy ?? _currentMemberId,
      note: entry.note,
      payerId: entry.payerId,
      splitMethod: entry.splitMethod,
      // settled_state 前端完全不可寫：沿用既有值，新筆一律 open。
      settledState: existing?.settledState ?? SettledState.open,
      isAdjustment: entry.isAdjustment,
      lineItems: lineItems,
      splits: splits,
    );

    _entries = existing == null
        ? [..._entries, saved]
        : [for (final e in _entries) e.id == saved.id ? saved : e];
    if (existing != null) _voidPendingSettlementFor(existing, saved);
    return saved;
  }

  @override
  Future<List<LineItem>> replaceLineItems(String entryId, List<LineItem> items) async {
    final existing = _findEntry(entryId);
    if (existing == null) throw const LedgerException('找不到這筆帳目，請重新整理');
    // 已結帳仍可改細項（ADR-0002），但已清帳的月份連細項都不能動
    // （DB 的 `a_line_items_month_closed_trg` 看的是父 entry 的 occurred_on）。
    _requireMonthOpen(existing.occurredOn);
    final rebuilt = [
      for (var i = 0; i < items.length; i++)
        LineItem(
          id: items[i].id.isEmpty ? _newId('li') : items[i].id,
          entryId: entryId,
          name: items[i].name,
          amount: items[i].amount,
          sort: items[i].sort,
        ),
    ];
    _entries = [
      for (final e in _entries) e.id == entryId ? e.copyWith(lineItems: rebuilt) : e,
    ];
    return rebuilt;
  }

  @override
  Future<void> removeEntry(String id) async {
    final e = _findEntry(id);
    if (e == null) return;
    _requireMonthOpen(e.occurredOn);
    if (e.settledState == SettledState.settled) {
      throw const LedgerException('已結帳的帳目不能刪除，請改用修正筆');
    }
    _entries = _entries.where((x) => x.id != id).toList();
    if (e.settledState == SettledState.settling) _voidSettlementCovering(id);
  }

  // ── 預算撥款 ────────────────────────────────────────────────────────

  @override
  Future<List<BudgetAllocation>> fetchAllocations(String ledgerId) async =>
      List.unmodifiable(_allocations);

  @override
  Future<BudgetAllocation> addAllocation(BudgetAllocation allocation) async {
    // DB 的三道守衛，順序照真 DB：BEFORE trigger（鎖月）→ CHECK（amount > 0）→ unique 索引。
    _requireMonthOpen(allocation.occurredOn);
    if (allocation.amount <= 0) {
      throw LedgerException(dbMessage('violates check constraint "budget_allocation_amount_positive"'));
    }
    final clash = _allocations.any((a) =>
        a.categoryId == allocation.categoryId && sameMonth(a.occurredOn, allocation.occurredOn));
    if (clash) {
      throw LedgerException(dbMessage(
        'duplicate key value violates unique constraint "budget_allocation_one_per_category_month"',
        code: '23505',
      ));
    }
    final saved = allocation.id.isEmpty
        ? BudgetAllocation(
            id: _newId('alloc'),
            ledgerId: allocation.ledgerId,
            categoryId: allocation.categoryId,
            amount: allocation.amount,
            occurredOn: allocation.occurredOn,
            note: allocation.note,
            createdBy: _currentMemberId,
          )
        : allocation;
    _allocations = [..._allocations, saved];
    return saved;
  }

  /// 與 DB `month_summary` 同形狀（v1.4）：同一組 balance_math 純函式組出來的。
  @override
  Future<MonthSummary> monthSummary(String ledgerId, DateTime until) async {
    final snap = snapshot;
    final ids = budgetCategoryIds(
        allocations: snap.allocations, entries: snap.entries, until: until);
    // 依 category_id 排序：DB 那側是 `order by category_id`，兩邊順序一致才好對照。
    final sortedIds = ids.toList()..sort();
    final categories = [
      for (final id in sortedIds)
        EnvelopeSummary(
          categoryId: id,
          allocated: allocatedIn(allocations: snap.allocations, categoryId: id, month: until),
          spent: spentIn(entries: snap.entries, categoryId: id, until: until),
          remaining: remainingIn(
              allocations: snap.allocations, entries: snap.entries, categoryId: id, until: until),
          over: overspend(
              allocations: snap.allocations, entries: snap.entries, categoryId: id, until: until),
        ),
    ];
    Member? meMember;
    for (final m in snap.members) {
      if (m.id == snap.currentMemberId) meMember = m;
    }
    return MonthSummary(
      sharedBalance: sharedBalance(ledger: snap.ledger, entries: snap.entries, until: until),
      budgetTotal: totalAllocated(allocations: snap.allocations, month: until),
      spentTotal: totalSpent(entries: snap.entries, until: until),
      overspendTotal:
          totalOverspend(entries: snap.entries, allocations: snap.allocations, until: until),
      categories: categories,
      memberId: meMember?.id,
      personalBalance: meMember == null
          ? null
          : personalBalance(
              member: meMember,
              entries: snap.entries,
              closes: snap.closes,
              until: until,
              joinedMonth: _joinedMonthOf(meMember),
            ),
      monthlyTopup: meMember?.monthlyTopup,
      monthNet: meMember == null
          ? null
          : monthNet(member: meMember, entries: snap.entries, month: until, until: until),
    );
  }

  // ── 清單／待辦 ──────────────────────────────────────────────────────

  @override
  Future<List<ListItem>> fetchListItems(String ledgerId) async => List.unmodifiable(_listItems);

  @override
  Future<ListItem> addListItem(ListItem item) async {
    final saved = item.id.isEmpty ? _withListItemId(item, _newId('l')) : item;
    _listItems = [..._listItems, saved];
    return saved;
  }

  @override
  Future<void> updateListItem(ListItem item) async =>
      _listItems = [for (final i in _listItems) i.id == item.id ? item : i];

  @override
  Future<void> removeListItem(String id) async =>
      _listItems = _listItems.where((i) => i.id != id).toList();

  // ── 結算（本地模擬） ────────────────────────────────────────────────

  @override
  Future<List<Settlement>> fetchSettlements(String ledgerId) async => List.unmodifiable(_settlements);

  @override
  Future<Settlement> initiateSettlement(String ledgerId) async {
    if (_settlements.any((s) => s.status == SettlementStatus.pending)) {
      throw const LedgerException('已經有一筆結算正在等待簽核');
    }
    final targets = _entries.where(isSettleable).toList();
    if (targets.isEmpty) throw const LedgerException('目前沒有可結算的帳目');
    final nets = computeNets(targets, _members);
    if (nets.values.every((v) => v == 0)) throw const LedgerException('目前淨額為零，不需要結算');

    final draft = Settlement(
      id: _newId('st'),
      ledgerId: ledgerId,
      status: SettlementStatus.pending,
      initiatedBy: _currentMemberId,
      createdAt: DateTime.now(),
      nets: nets,
      entryIds: [for (final e in targets) e.id],
      approvedBy: const {},
    );
    // 沒有人需要簽（需簽者＝淨額非零成員−發起人）時直接成立，否則會卡成永遠 pending。
    final settleNow = draft.fullyApproved;
    final settlement = settleNow ? _finalize(draft, const {}) : draft;
    _applySettledState(settlement.entryIds, settleNow ? SettledState.settled : SettledState.settling);
    _settlements = [..._settlements, settlement];
    return settlement;
  }

  @override
  Future<Settlement> approveSettlement(String settlementId) async {
    final s = _findSettlement(settlementId);
    if (s == null) throw const LedgerException('找不到這筆結算，請重新整理');
    if (s.status != SettlementStatus.pending) throw const LedgerException('這筆結算已經處理過了');
    if (!s.requiredSigners.contains(_currentMemberId)) {
      throw const LedgerException('你不是這筆結算的簽核人');
    }
    final next = _finalize(s, {...s.approvedBy, _currentMemberId});
    if (next.status == SettlementStatus.settled) {
      _applySettledState(next.entryIds, SettledState.settled);
    }
    _settlements = [for (final x in _settlements) x.id == next.id ? next : x];
    return next;
  }

  @override
  Future<Settlement> cancelSettlement(String settlementId) async {
    final s = _findSettlement(settlementId);
    if (s == null) throw const LedgerException('找不到這筆結算，請重新整理');
    if (s.status != SettlementStatus.pending) throw const LedgerException('這筆結算已經處理過了');
    if (s.initiatedBy != _currentMemberId && !s.requiredSigners.contains(_currentMemberId)) {
      throw const LedgerException('只有發起人或簽核人可以取消結算');
    }
    final next = _replaceStatus(s, SettlementStatus.void_);
    _applySettledState(next.entryIds, SettledState.open);
    _settlements = [for (final x in _settlements) x.id == next.id ? next : x];
    return next;
  }

  // ── 月清帳（本地模擬；可清條件與 DB `month_close_guard` 逐條對應）──────

  @override
  Future<List<MonthClose>> fetchMonthCloses(String ledgerId) async => List.unmodifiable(_closes);

  @override
  Future<MonthCloseDetails> monthClosePreview(String ledgerId, DateTime month) async {
    _guardClose(month);
    return _closeDetails(monthOf(month), withWarnings: true);
  }

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month) async {
    _guardClose(month);
    final m = monthOf(month);
    final saved = MonthClose(
      id: _newId('mc'),
      ledgerId: _ledger.id,
      month: m,
      closedBy: _currentMemberId,
      closedAt: DateTime.now(),
      // 落地的快照不帶 warnings（提醒會隨資料變，事實快照不該跟著變）。
      details: _closeDetails(m, withWarnings: false),
    );
    _closes = [..._closes, saved];
    return saved;
  }

  /// 可清條件。順序與訊息逐字比照 `month_close_guard`：
  /// 必須是月初 → 月份已結束 → 已清過 → 有可清的月份 → 必須是下一個可清月 → 拆帳全簽完。
  void _guardClose(DateTime raw) {
    if (raw.day != 1) _raiseDb('close_month: month must be first day');
    final month = monthOf(raw);
    final current = monthOf(DateTime.now());
    if (!month.isBefore(current)) _raiseDb('close_month: month not ended');
    if (_closes.any((c) => sameMonth(c.month, month))) _raiseDb('close_month: already closed');

    final next = _nextClosableMonth();
    if (next == null || !next.isBefore(current)) _raiseDb('close_month: nothing to close');
    if (next != month) {
      _raiseDb('close_month: must close '
          '${next.year.toString().padLeft(4, '0')}-${next.month.toString().padLeft(2, '0')} first');
    }
    // 判準逐字比照 `initiate_settlement`／`month_close_guard`——**含「有分攤列」**：
    // 沒有分攤列的拆帳筆結算根本撿不到，擋了那個月永遠清不掉。
    final unsettled = _entries.any((e) =>
        e.scope == EntryScope.shared &&
        e.isExpense &&
        e.payerId != null &&
        e.splitMethod != SplitMethod.common &&
        e.settledState != SettledState.settled &&
        e.splits.isNotEmpty &&
        sameMonth(e.occurredOn, month));
    if (unsettled) _raiseDb('close_month: unsettled entries in month');
  }

  /// 下一個可清月：清過就是「最後清帳月 ＋ 1 月」，沒清過就是「最早有成員或有帳目的那個月」。
  DateTime? _nextClosableMonth() {
    DateTime? last;
    for (final c in _closes) {
      final m = monthOf(c.month);
      if (last == null || m.isAfter(last)) last = m;
    }
    if (last != null) return nextMonth(last);

    DateTime? earliest;
    for (final m in _members) {
      final j = _joinedMonthOf(m);
      if (earliest == null || j.isBefore(earliest)) earliest = j;
    }
    for (final e in _entries) {
      final m = monthOf(e.occurredOn);
      if (earliest == null || m.isBefore(earliest)) earliest = m;
    }
    return earliest;
  }

  /// 清帳明細（`month_close_details` 的形狀）：每位成員一列，依 `joined_at, id` 排序。
  MonthCloseDetails _closeDetails(DateTime month, {required bool withWarnings}) {
    // 與 DB `month_close_details` 的 `order by c.joined_at, c.id` 同：比完整時間戳，不是月份。
    final members = [..._members]..sort((a, b) {
        final byJoined = a.joinedAt.compareTo(b.joinedAt);
        return byJoined != 0 ? byJoined : a.id.compareTo(b.id);
      });
    final lines = [
      for (final m in members)
        () {
          final topup = _joinedMonthOf(m).isAfter(month) ? 0 : m.monthlyTopup;
          final net = monthNet(member: m, entries: _entries, month: month);
          return MonthCloseMemberLine(
            memberId: m.id,
            displayName: m.displayName,
            topup: topup,
            net: net,
            ending: topup + net,
          );
        }(),
    ];
    var sharedDelta = 0;
    for (final e in _entries) {
      if (e.scope != EntryScope.shared || !sameMonth(e.occurredOn, month)) continue;
      if (!e.isExpense) {
        sharedDelta += e.amount;
      } else if (e.payerId == null) {
        sharedDelta -= e.amount;
      }
    }
    // 可清條件刻意放行「沒有分攤列的拆帳筆」，但它會由付款人全額承擔——預覽先講一聲。
    final loose = _entries
        .where((e) =>
            e.scope == EntryScope.shared &&
            e.isExpense &&
            e.payerId != null &&
            e.splitMethod != SplitMethod.common &&
            e.splits.isEmpty &&
            sameMonth(e.occurredOn, month))
        .length;
    return MonthCloseDetails(
      month: month,
      members: lines,
      sharedDelta: sharedDelta,
      warnings: withWarnings && loose > 0
          ? [CloseWarning(code: 'unsplit_advances', count: loose)]
          : const [],
    );
  }

  /// 加入月（本地時區取月初）：補入額從這個月開始算。
  DateTime _joinedMonthOf(Member m) => monthOf(m.joinedAt);

  /// 鎖月守衛（`a_*_month_closed_trg`）：最後清帳月（含）以前一律不可寫。
  void _requireMonthOpen(DateTime occurredOn) {
    if (!isMonthClosed(_closes, occurredOn)) return;
    final m = monthOf(occurredOn);
    _raiseDb('month closed: '
        '${m.year.toString().padLeft(4, '0')}-${m.month.toString().padLeft(2, '0')}');
  }

  /// DB 的英文 raise → 和 Supabase 版**同一句**中文（走 `errors.dart` 的同一張表）。
  static Never _raiseDb(String raw) => throw LedgerException(dbMessage(raw));

  // ── 內部工具 ────────────────────────────────────────────────────────

  Entry? _findEntry(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  Settlement? _findSettlement(String id) {
    for (final s in _settlements) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _applySettledState(List<String> entryIds, SettledState next) {
    _entries = [
      for (final e in _entries) entryIds.contains(e.id) ? e.copyWith(settledState: next) : e,
    ];
  }

  /// 簽核集合湊齊就落 settled（對應 DB 的 `settlement_finalize_on_approval` trigger）。
  Settlement _finalize(Settlement s, Set<String> approvedBy) {
    final done = s.requiredSigners.difference(approvedBy).isEmpty;
    return Settlement(
      id: s.id,
      ledgerId: s.ledgerId,
      status: done ? SettlementStatus.settled : s.status,
      initiatedBy: s.initiatedBy,
      createdAt: s.createdAt,
      settledAt: done ? DateTime.now() : s.settledAt,
      nets: s.nets,
      entryIds: s.entryIds,
      approvedBy: approvedBy,
    );
  }

  Settlement _replaceStatus(Settlement s, SettlementStatus status) => Settlement(
        id: s.id,
        ledgerId: s.ledgerId,
        status: status,
        initiatedBy: s.initiatedBy,
        createdAt: s.createdAt,
        settledAt: s.settledAt,
        nets: s.nets,
        entryIds: s.entryIds,
        approvedBy: s.approvedBy,
      );

  /// 對應 `entries_void_pending_settlement_trg`：settling 期間金額／付款人／分攤方式／
  /// 範圍／種類／日期**的值真的變了**就 void 掉那筆 pending 結算。改備註、分類不會 void。
  void _voidPendingSettlementFor(Entry before, Entry after) {
    if (before.settledState != SettledState.settling) return;
    final changed = before.amount != after.amount ||
        before.payerId != after.payerId ||
        before.splitMethod != after.splitMethod ||
        before.scope != after.scope ||
        before.kind != after.kind ||
        before.occurredOn != after.occurredOn;
    if (changed) _voidSettlementCovering(before.id);
  }

  void _voidSettlementCovering(String entryId) {
    for (final s in _settlements) {
      if (s.status == SettlementStatus.pending && s.entryIds.contains(entryId)) {
        final voided = _replaceStatus(s, SettlementStatus.void_);
        _applySettledState(s.entryIds, SettledState.open);
        _settlements = [for (final x in _settlements) x.id == voided.id ? voided : x];
        return;
      }
    }
  }

  Category _withCategoryId(Category c, String id) => Category(
        id: id,
        ledgerId: c.ledgerId,
        kind: c.kind,
        name: c.name,
        icon: c.icon,
        sort: c.sort,
      );

  ListItem _withListItemId(ListItem i, String id) => ListItem(
        id: id,
        ledgerId: i.ledgerId,
        title: i.title,
        store: i.store,
        estimated: i.estimated,
        categoryId: i.categoryId,
        assigneeId: i.assigneeId,
        dueOn: i.dueOn,
        doneAt: i.doneAt,
        entryId: i.entryId,
        sort: i.sort,
      );

  // ── 種子 ────────────────────────────────────────────────────────────

  /// 剛建好的空帳本：只有自己一個成員與九個預設分類（比照 `create_ledger` RPC）。
  void _reseedEmpty(String name) {
    _cleared = false;
    _ledger = Ledger(
      id: _newId('ledger'),
      name: name,
      inviteCode: 'NEWLEDGER1',
      defaultRatio: const {kMeId: 100},
    );
    _members = [
      Member(
        id: kMeId,
        ledgerId: _ledger.id,
        userId: 'u1',
        displayName: 'Mike',
        joinedAt: DateTime.now(),
      ),
    ];
    _currentMemberId = kMeId;
    _categories = _seedCategories(_ledger.id);
    _entries = [];
    _allocations = [];
    _listItems = [];
    _settlements = [];
    _closes = [];
  }

  void _reseed() {
    _cleared = false;
    _ledger = const Ledger(
      id: kLedgerId,
      name: '我們的家',
      inviteCode: 'A7K3QZM4XB',
      defaultRatio: {kMeId: 50, kWifeId: 50},
      openingBalanceShared: 120000,
    );
    // v1.4：兩位成員各設每月補入額 10,000（與 `supabase/seed.sql` 同一組意義）；
    // 加入月＝上個月，所以本月與上月各補一次。期初個人餘額欄位還在但已不入公式。
    final joined = DateTime(DateTime.now().year, DateTime.now().month - 1, 1);
    _members = [
      Member(
        id: kMeId,
        ledgerId: kLedgerId,
        userId: 'u1',
        displayName: 'Mike',
        monthlyTopup: 10000,
        joinedAt: joined,
      ),
      Member(
        id: kWifeId,
        ledgerId: kLedgerId,
        userId: 'u2',
        displayName: '老婆',
        monthlyTopup: 10000,
        joinedAt: joined,
      ),
    ];
    _currentMemberId = kMeId;
    _categories = _seedCategories(kLedgerId);
    _entries = _seedEntries();
    _allocations = _seedAllocations();
    _listItems = _seedListItems();
    _settlements = _seedSettlements();
    // 假資料不預設任何清帳紀錄：有紀錄就等於把整段歷史鎖住，波 1 的畫面都寫不了。
    _closes = [];
  }

  static List<Category> _seedCategories(String ledgerId) => [
        Category(id: 'c-food', ledgerId: ledgerId, kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0),
        Category(id: 'c-dining', ledgerId: ledgerId, kind: EntryKind.expense, name: '餐飲', icon: 'local_dining', sort: 1),
        Category(id: 'c-daily', ledgerId: ledgerId, kind: EntryKind.expense, name: '日常用品', icon: 'inventory_2', sort: 2),
        Category(id: 'c-house', ledgerId: ledgerId, kind: EntryKind.expense, name: '住房', icon: 'home', sort: 3),
        Category(id: 'c-util', ledgerId: ledgerId, kind: EntryKind.expense, name: '水電', icon: 'bolt', sort: 4),
        Category(id: 'c-transport', ledgerId: ledgerId, kind: EntryKind.expense, name: '交通', icon: 'directions_car', sort: 5),
        Category(id: 'c-fun', ledgerId: ledgerId, kind: EntryKind.expense, name: '娛樂', icon: 'sports_esports', sort: 6),
        Category(id: 'c-salary', ledgerId: ledgerId, kind: EntryKind.income, name: '薪水', icon: 'payments', sort: 0),
        Category(id: 'c-bonus', ledgerId: ledgerId, kind: EntryKind.income, name: '獎金', icon: 'card_giftcard', sort: 1),
      ];

  static List<Entry> _seedEntries() {
    final now = DateTime.now();
    final y = now.year;
    final m = now.month;
    int n = 0;
    String id() => 'e-${++n}';
    final list = <Entry>[
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.income, scope: EntryScope.shared, amount: 52000, categoryId: 'c-salary', occurredOn: _d(y, m, 5), createdBy: kMeId, note: '薪水'),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.income, scope: EntryScope.private, amount: 8000, categoryId: 'c-bonus', occurredOn: _d(y, m, 6), createdBy: kMeId, note: '接案'),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 26000, categoryId: 'c-house', occurredOn: _d(y, m, 1), createdBy: kMeId, note: '房租', splitMethod: SplitMethod.common),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 2300, categoryId: 'c-util', occurredOn: _d(y, m, 3), createdBy: kWifeId, note: '電費', splitMethod: SplitMethod.common),
      Entry(
        id: id(),
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 567,
        categoryId: 'c-food',
        occurredOn: _d(y, m, 8),
        createdBy: kMeId,
        note: '全聯買菜',
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
        splits: const [EntrySplit(entryId: 'e-5', memberId: kMeId, share: 283.5), EntrySplit(entryId: 'e-5', memberId: kWifeId, share: 283.5)],
        lineItems: const [
          LineItem(id: 'li-1', entryId: 'e-5', name: '雞蛋', amount: 89),
          LineItem(id: 'li-2', entryId: 'e-5', name: '牛奶', amount: 95),
          LineItem(id: 'li-3', entryId: 'e-5', name: '高麗菜', amount: 45),
        ],
      ),
      Entry(
        id: id(),
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1280,
        categoryId: 'c-dining',
        occurredOn: _d(y, m, 9),
        createdBy: kWifeId,
        note: '週五晚餐', settledState: SettledState.settling,
        payerId: kWifeId,
        splitMethod: SplitMethod.equal,
        splits: const [EntrySplit(entryId: 'e-6', memberId: kMeId, share: 640), EntrySplit(entryId: 'e-6', memberId: kWifeId, share: 640)],
      ),
      Entry(
        id: id(),
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1520,
        categoryId: 'c-daily',
        occurredOn: _d(y, m, 12),
        createdBy: kMeId,
        note: 'Costco', settledState: SettledState.settling,
        payerId: kMeId,
        splitMethod: SplitMethod.ratio,
        splits: const [EntrySplit(entryId: 'e-7', memberId: kMeId, share: 760), EntrySplit(entryId: 'e-7', memberId: kWifeId, share: 760)],
        lineItems: const [
          LineItem(id: 'li-4', entryId: 'e-7', name: '衛生紙', amount: 499),
          LineItem(id: 'li-5', entryId: 'e-7', name: '洗衣精', amount: 359),
          LineItem(id: 'li-6', entryId: 'e-7', name: '雞蛋', amount: 189),
        ],
      ),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.private, amount: 350, categoryId: 'c-fun', occurredOn: _d(y, m, 13), createdBy: kMeId, note: 'Steam', payerId: kMeId),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 420, categoryId: 'c-transport', occurredOn: _d(y, m, 14), createdBy: kWifeId, note: '加油', settledState: SettledState.settling, payerId: kWifeId, splitMethod: SplitMethod.equal, splits: const [EntrySplit(entryId: 'e-9', memberId: kMeId, share: 210), EntrySplit(entryId: 'e-9', memberId: kWifeId, share: 210)]),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 680, categoryId: 'c-food', occurredOn: _d(y, m, 15), createdBy: kWifeId, note: '菜市場', settledState: SettledState.settling, payerId: kWifeId, splitMethod: SplitMethod.equal, splits: const [EntrySplit(entryId: 'e-10', memberId: kMeId, share: 340), EntrySplit(entryId: 'e-10', memberId: kWifeId, share: 340)], lineItems: const [LineItem(id: 'li-7', entryId: 'e-10', name: '豬肉', amount: 280), LineItem(id: 'li-8', entryId: 'e-10', name: '雞蛋', amount: 80)]),
    ];
    // 上個月一些資料，讓趨勢與上月信封有東西可算。
    final pm = DateTime(y, m - 1, 1);
    list.addAll([
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.income, scope: EntryScope.shared, amount: 52000, categoryId: 'c-salary', occurredOn: DateTime(pm.year, pm.month, 5), createdBy: kMeId, note: '薪水'),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 26000, categoryId: 'c-house', occurredOn: DateTime(pm.year, pm.month, 1), createdBy: kMeId, note: '房租', splitMethod: SplitMethod.common),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 6200, categoryId: 'c-food', occurredOn: DateTime(pm.year, pm.month, 10), createdBy: kMeId, note: '整月買菜', splitMethod: SplitMethod.common),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 3900, categoryId: 'c-dining', occurredOn: DateTime(pm.year, pm.month, 18), createdBy: kWifeId, note: '外食', splitMethod: SplitMethod.common),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1100, categoryId: 'c-daily', occurredOn: DateTime(pm.year, pm.month, 20), createdBy: kMeId, note: '日用品', splitMethod: SplitMethod.common),
    ]);
    // 本月共同錢包的預算支出（尾端加，不動既有筆序與 e-N 計數）：讓本月信封看得到被吃。
    list.addAll([
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 2400, categoryId: 'c-food', occurredOn: _d(y, m, 16), createdBy: kMeId, note: '大採購', splitMethod: SplitMethod.common),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1300, categoryId: 'c-dining', occurredOn: _d(y, m, 17), createdBy: kWifeId, note: '週末外食', splitMethod: SplitMethod.common),
    ]);
    return list;
  }

  static List<BudgetAllocation> _seedAllocations() {
    final now = DateTime.now();
    final m = DateTime(now.year, now.month, 1);
    final pm = DateTime(now.year, now.month - 1, 1);
    return [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 6000, occurredOn: m, createdBy: kMeId, note: '本月食品'),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 4000, occurredOn: m, createdBy: kMeId, note: '本月餐飲'),
      BudgetAllocation(id: 'a-3', ledgerId: kLedgerId, categoryId: 'c-daily', amount: 1500, occurredOn: m, createdBy: kMeId, note: '本月日常用品'),
      BudgetAllocation(id: 'a-4', ledgerId: kLedgerId, categoryId: 'c-util', amount: 3000, occurredOn: m, createdBy: kMeId, note: '本月水電'),
      BudgetAllocation(id: 'a-5', ledgerId: kLedgerId, categoryId: 'c-transport', amount: 2000, occurredOn: m, createdBy: kMeId, note: '本月交通'),
      BudgetAllocation(id: 'a-6', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5500, occurredOn: pm, createdBy: kMeId, note: '上月食品'),
      BudgetAllocation(id: 'a-7', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 4000, occurredOn: pm, createdBy: kMeId, note: '上月餐飲'),
    ];
  }

  static List<ListItem> _seedListItems() => [
        const ListItem(id: 'l-1', ledgerId: kLedgerId, title: '衛生紙', store: '藥局', estimated: 199, categoryId: 'c-daily'),
        const ListItem(id: 'l-2', ledgerId: kLedgerId, title: '酸奶', store: '超市', estimated: 120, categoryId: 'c-food', assigneeId: kWifeId),
        const ListItem(id: 'l-3', ledgerId: kLedgerId, title: '麵包', store: '超市', estimated: 80, categoryId: 'c-food'),
        const ListItem(id: 'l-4', ledgerId: kLedgerId, title: '牛奶', store: '超市', estimated: 95, categoryId: 'c-food'),
        const ListItem(id: 'l-5', ledgerId: kLedgerId, title: '運動鞋', store: '購物中心', estimated: 2500, categoryId: 'c-daily', assigneeId: kMeId),
        ListItem(id: 'l-6', ledgerId: kLedgerId, title: '繳管理費', dueOn: DateTime.now().add(const Duration(days: 3)), assigneeId: kMeId),
        ListItem(id: 'l-7', ledgerId: kLedgerId, title: '預約牙醫', dueOn: DateTime.now().add(const Duration(days: 10)), assigneeId: kWifeId),
      ];

  static List<Settlement> _seedSettlements() => [
        Settlement(
          id: 's-1',
          ledgerId: kLedgerId,
          status: SettlementStatus.pending,
          initiatedBy: kWifeId,
          createdAt: DateTime.now().subtract(const Duration(hours: 5)),
          nets: const {kMeId: -430, kWifeId: 430},
          entryIds: const ['e-6', 'e-7', 'e-9', 'e-10'],
          approvedBy: const {},
        ),
      ];
}
