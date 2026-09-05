/// 記憶體版 repository：波 1 的假資料與行為搬過來的地方。
///
/// 用途有二：`flutter test`（所有 widget 測試的預設資料來源）與
/// `--dart-define=USE_MOCK=true`（不連網跑整個 App）。清帳在這裡是本地模擬——
/// 真正的原子性與守衛在 Postgres，這份只是讓畫面跑得動、讓契約測試跑得到同一組斷言。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/balance_math.dart';
import '../domain/models.dart';
import '../domain/month_summary.dart';
import 'errors.dart';
import 'ledger_repository.dart';

const kLedgerId = 'ledger-1';
const kMeId = 'm-mike';
const kWifeId = 'm-wife';

/// 清帳「一鍵記共同收入」用的分類名稱（帳本沒有時自動建，spec v1.5「清帳」）。
const kCloseIncomeCategoryName = '清帳轉入';

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

/// 某個月的最後一天（清帳記的那筆共同收入落在這一天）。
DateTime _lastDayOf(DateTime month) => DateTime(month.year, month.month + 1, 0);

String _ym(DateTime m) =>
    '${m.year.toString().padLeft(4, '0')}-${m.month.toString().padLeft(2, '0')}';

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
    _topups = [...s.topups];
    _closes = [...s.closes];
    _currentMemberId = s.currentMemberId;
  }

  late Ledger _ledger;
  late List<Member> _members;
  late List<Category> _categories;
  late List<Entry> _entries;
  late List<BudgetAllocation> _allocations;
  late List<ListItem> _listItems;
  late List<PersonalTopup> _topups;
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
          topups: List.unmodifiable(_topups),
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
    _ledger = Ledger(id: _ledger.id, name: _ledger.name, inviteCode: code);
    return _ledger;
  }

  /// 只有 `name` 有 update 授權（v1.5）：其餘欄位就算呼叫端改了也不落地，
  /// 記憶體版比照 DB 只覆寫那一欄，不然替身會比真 DB 寬鬆。
  @override
  Future<void> updateLedger(Ledger ledger) async {
    _ledger = Ledger(id: _ledger.id, name: ledger.name, inviteCode: _ledger.inviteCode);
  }

  /// 只有 `display_name` 有 update 授權（v1.5）：其餘欄位一律沿用既有值。
  @override
  Future<void> updateMember(Member member) async {
    _members = [
      for (final m in _members) m.id == member.id ? m.copyWith(displayName: member.displayName) : m,
    ];
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
  Future<Entry> upsertEntry(Entry entry, {bool writeLineItems = true}) async {
    final existing = entry.id.isEmpty ? null : _findEntry(entry.id);

    // DB check `entries_income_no_payer`：收入只有共同收入，沒有付款人。
    if (entry.kind == EntryKind.income && entry.payerId != null) {
      _raiseDb('violates check constraint "entries_income_no_payer"');
    }

    // 鎖月：新值與舊值兩個月都要看——「把日期搬進鎖定範圍」與「動鎖定範圍裡的帳目」
    // 都要擋（對應 `a_entries_month_closed_trg` 的 update 兩側檢查）。
    _requireMonthOpen(entry.occurredOn);
    if (existing != null) _requireMonthOpen(existing.occurredOn);

    final id = entry.id.isEmpty ? _newId('e') : entry.id;
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
      amount: entry.amount,
      categoryId: entry.categoryId,
      occurredOn: entry.occurredOn,
      createdBy: existing?.createdBy ?? _currentMemberId,
      note: entry.note,
      payerId: entry.payerId,
      isAdjustment: entry.isAdjustment,
      createdAt: existing?.createdAt,
      lineItems: lineItems,
    );

    _entries = existing == null
        ? [..._entries, saved]
        : [for (final e in _entries) e.id == saved.id ? saved : e];
    return saved;
  }

  @override
  Future<List<LineItem>> replaceLineItems(String entryId, List<LineItem> items) async {
    final existing = _findEntry(entryId);
    if (existing == null) throw const LedgerException('找不到這筆帳目，請重新整理');
    // 已清帳的月份連細項都不能動
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
    _entries = _entries.where((x) => x.id != id).toList();
  }

  // ── 個人補入（v1.5）─────────────────────────────────────────────────

  @override
  Future<List<PersonalTopup>> fetchTopups(String ledgerId) async => List.unmodifiable(_topups);

  /// 三道守衛，順序照真 DB 的層次：RLS（只能寫自己那列）→ BEFORE trigger（鎖月）
  /// → CHECK（金額 > 0）。單獨違反任何一條時兩個實作吐的都是同一句中文。
  @override
  Future<PersonalTopup> addTopup(PersonalTopup topup) async {
    if (topup.memberId != _currentMemberId) {
      _raiseDb('new row violates row-level security policy for table "personal_topups"',
          code: '42501');
    }
    _requireMonthOpen(topup.occurredOn);
    if (topup.amount <= 0) {
      _raiseDb('violates check constraint "personal_topups_amount_positive"');
    }
    final saved = PersonalTopup(
      id: topup.id.isEmpty ? _newId('pt') : topup.id,
      ledgerId: topup.ledgerId,
      memberId: topup.memberId,
      amount: topup.amount,
      occurredOn: topup.occurredOn,
      note: topup.note,
      // DB 的 insert policy 逼 `created_by = 本人`，不接受以別人的名義補入。
      createdBy: _currentMemberId,
      createdAt: DateTime.now(),
    );
    _topups = [..._topups, saved];
    return saved;
  }

  @override
  Future<void> removeTopup(String id) async {
    final t = _findTopup(id);
    if (t == null) return;
    if (t.memberId != _currentMemberId) {
      _raiseDb('permission denied for table "personal_topups"', code: '42501');
    }
    _requireMonthOpen(t.occurredOn);
    _topups = _topups.where((x) => x.id != id).toList();
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
      _raiseDb('violates check constraint "budget_allocation_amount_positive"');
    }
    final clash = _allocations.any((a) =>
        a.categoryId == allocation.categoryId && sameMonth(a.occurredOn, allocation.occurredOn));
    if (clash) {
      _raiseDb(
        'duplicate key value violates unique constraint "budget_allocation_one_per_category_month"',
        code: '23505',
      );
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

  /// 與 DB `month_summary` 同形狀（v1.5）：同一組 balance_math 純函式組出來的。
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
    // 成員清單走 `snap`，不是 `_members`：`clearSnapshot()` 之後快照是空的，
    // 直接讀欄位會產出「成員還在、數字全 0」的半套（登出瞬間畫面會閃出上一個帳號的人）。
    final members = [
      for (final m in _byJoinOrder(snap.members))
        MemberMonthLine(
          memberId: m.id,
          displayName: m.displayName,
          topup: topupIn(topups: snap.topups, memberId: m.id, month: until),
          paid: paidIn(entries: snap.entries, memberId: m.id, month: until),
          remaining: topupRemaining(
              topups: snap.topups, entries: snap.entries, memberId: m.id, month: until),
        ),
    ];
    return MonthSummary(
      sharedBalance: sharedBalance(entries: snap.entries, until: until),
      budgetTotal: totalAllocated(allocations: snap.allocations, month: until),
      spentTotal: totalSpent(entries: snap.entries, until: until),
      overspendTotal:
          totalOverspend(entries: snap.entries, allocations: snap.allocations, until: until),
      categories: categories,
      members: members,
      sharedPaid: sharedPaidIn(entries: snap.entries, month: until),
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

  // ── 月清帳（本地模擬；可清條件與 DB `month_close_guard` 逐條對應）──────

  @override
  Future<List<MonthClose>> fetchMonthCloses(String ledgerId) async => List.unmodifiable(_closes);

  @override
  Future<MonthCloseDetails> monthClosePreview(String ledgerId, DateTime month) async {
    _guardClose(month);
    return _closeDetails(monthOf(month), withIncomeAmount: true);
  }

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month,
      {bool recordIncome = true}) async {
    _guardClose(month);
    final m = monthOf(month);
    // 落地的快照不帶 income_amount（那是預覽用的提示，事實快照只留三個數）。
    final details = _closeDetails(m, withIncomeAmount: false);
    final incomeAmount = _incomeAmountOf(details);

    // 「一鍵記共同收入」：記在清帳月最後一天，所以要趕在寫 month_closes（＝鎖月）之前。
    String? incomeEntryId;
    if (recordIncome && incomeAmount > 0) {
      final category = _closeIncomeCategory();
      final entry = Entry(
        id: _newId('e'),
        ledgerId: _ledger.id,
        kind: EntryKind.income,
        amount: incomeAmount,
        categoryId: category.id,
        occurredOn: _lastDayOf(m),
        createdBy: _currentMemberId,
        note: '${m.year}／${m.month.toString().padLeft(2, '0')} 清帳',
      );
      _entries = [..._entries, entry];
      incomeEntryId = entry.id;
    }

    final saved = MonthClose(
      id: _newId('mc'),
      ledgerId: _ledger.id,
      month: m,
      closedBy: _currentMemberId,
      closedAt: DateTime.now(),
      incomeEntryId: incomeEntryId,
      details: details,
    );
    _closes = [..._closes, saved];
    return saved;
  }

  /// 可清條件。順序與訊息逐字比照 `month_close_guard`：
  /// 必須是月初 → 月份已結束 → 已清過 → 有可清的月份 → 必須是下一個可清月。
  /// （v1.5 沒有第六條「拆帳全簽完」——結算整組廢掉了。）
  void _guardClose(DateTime raw) {
    if (raw.day != 1) _raiseDb('close_month: month must be first day');
    final month = monthOf(raw);
    final current = monthOf(DateTime.now());
    if (!month.isBefore(current)) _raiseDb('close_month: month not ended');
    if (_closes.any((c) => sameMonth(c.month, month))) _raiseDb('close_month: already closed');

    final next = _nextClosableMonth();
    if (next == null || !next.isBefore(current)) _raiseDb('close_month: nothing to close');
    if (next != month) _raiseDb('close_month: must close ${_ym(next)} first');
  }

  /// 下一個可清月：清過就是「最後清帳月 ＋ 1 月」，沒清過就是
  /// 「最早有帳目、補入或成員加入的那個月」（spec v1.5「可清條件」第 2 條）。
  DateTime? _nextClosableMonth() {
    DateTime? last;
    for (final c in _closes) {
      final m = monthOf(c.month);
      if (last == null || m.isAfter(last)) last = m;
    }
    if (last != null) return nextMonth(last);

    DateTime? earliest;
    void consider(DateTime m) {
      if (earliest == null || m.isBefore(earliest!)) earliest = m;
    }

    for (final m in _members) {
      consider(_joinedMonthOf(m));
    }
    for (final e in _entries) {
      consider(monthOf(e.occurredOn));
    }
    for (final t in _topups) {
      consider(monthOf(t.occurredOn));
    }
    return earliest;
  }

  /// 清帳明細（`month_close_details` 的形狀）：每位成員一列，依 `joined_at, id` 排序。
  MonthCloseDetails _closeDetails(DateTime month, {required bool withIncomeAmount}) {
    final lines = [
      for (final m in _byJoinOrder(_members))
        () {
          final topup = topupIn(topups: _topups, memberId: m.id, month: month);
          final paid = paidIn(entries: _entries, memberId: m.id, month: month);
          return MonthCloseMemberLine(
            memberId: m.id,
            displayName: m.displayName,
            topup: topup,
            paid: paid,
            ending: topup - paid,
          );
        }(),
    ];
    final details = MonthCloseDetails(
      month: month,
      members: lines,
      sharedPaid: sharedPaidIn(entries: _entries, month: month),
    );
    if (!withIncomeAmount) return details;
    return MonthCloseDetails(
      month: details.month,
      members: details.members,
      sharedPaid: details.sharedPaid,
      incomeAmount: _incomeAmountOf(details),
    );
  }

  /// 應記的共同收入＝Σ應轉入 − Σ應補出 ＝ Σ 各成員月末（spec v1.5「一鍵記共同收入」）。
  int _incomeAmountOf(MonthCloseDetails details) {
    var sum = 0;
    for (final l in details.members) {
      sum += l.ending;
    }
    return sum;
  }

  /// 「清帳轉入」income 分類；帳本沒有時自動建（DB 那側 `close_month` 同樣現建）。
  Category _closeIncomeCategory() {
    for (final c in _categories) {
      if (c.kind == EntryKind.income && c.name == kCloseIncomeCategoryName) return c;
    }
    var maxSort = -1;
    for (final c in _categories) {
      if (c.kind == EntryKind.income && c.sort > maxSort) maxSort = c.sort;
    }
    final created = Category(
      id: _newId('c'),
      ledgerId: _ledger.id,
      kind: EntryKind.income,
      name: kCloseIncomeCategoryName,
      icon: 'sync_alt',
      sort: maxSort + 1,
    );
    _categories = [..._categories, created];
    return created;
  }

  /// 與 DB `month_close_details` 的 `order by c.joined_at, c.id` 同：比完整時間戳，不是月份。
  List<Member> _byJoinOrder(List<Member> members) => [...members]..sort((a, b) {
        final byJoined = a.joinedAt.compareTo(b.joinedAt);
        return byJoined != 0 ? byJoined : a.id.compareTo(b.id);
      });

  /// 加入月（本地時區取月初）。
  DateTime _joinedMonthOf(Member m) => monthOf(m.joinedAt);

  /// 鎖月守衛（`a_*_month_closed_trg`）：最後清帳月（含）以前一律不可寫。
  void _requireMonthOpen(DateTime occurredOn) {
    if (!isMonthClosed(_closes, occurredOn)) return;
    _raiseDb('month closed: ${_ym(monthOf(occurredOn))}');
  }

  /// DB 的英文 raise → 和 Supabase 版**同一句**中文（走 `errors.dart` 的同一張表）。
  static Never _raiseDb(String raw, {String? code}) =>
      throw LedgerException(dbMessage(raw, code: code), code: code);

  // ── 內部工具 ────────────────────────────────────────────────────────

  Entry? _findEntry(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  PersonalTopup? _findTopup(String id) {
    for (final t in _topups) {
      if (t.id == id) return t;
    }
    return null;
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
    _ledger = Ledger(id: _newId('ledger'), name: name, inviteCode: 'NEWLEDGER1');
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
    _topups = [];
    _closes = [];
  }

  /// spec v1.5「驗收總表／三個數」那組已知資料集：
  /// 本月 Mike 補入 10,000／先付 6,000、老婆補入 10,000／先付 2,000、
  /// 共同錢包付 3,000、共同收入 20,000 → 補入剩餘 4,000／8,000、共同餘額 17,000。
  /// Mike 那 6,000 是「先付 7,000 ＋ 沖銷 −1,000」淨算出來的（種子裡真的有一筆沖銷）。
  ///
  /// **上月只放成員先付與補入**，一筆共同收入與共同錢包支出都不放：`sharedBalance`
  /// 是累計水位、不分月，上月只要淨額不是 0，本月底就不會是那 17,000。
  /// 上月的補入與先付則是清帳測試的素材。
  void _reseed() {
    _cleared = false;
    _ledger = const Ledger(id: kLedgerId, name: '我們的家', inviteCode: 'A7K3QZM4XB');
    // 加入月＝上個月：上月是「最早可清的月份」，本月才是還在跑的那個月。
    final joined = DateTime(DateTime.now().year, DateTime.now().month - 1, 1);
    _members = [
      Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', joinedAt: joined),
      Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', joinedAt: joined),
    ];
    _currentMemberId = kMeId;
    _categories = _seedCategories(kLedgerId);
    _entries = _seedEntries();
    _topups = _seedTopups();
    _allocations = _seedAllocations();
    _listItems = _seedListItems();
    // 假資料不預設任何清帳紀錄：有紀錄就等於把整段歷史鎖住，畫面都寫不了。
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
    final pm = DateTime(y, m - 1, 1);
    var n = 0;
    String id() => 'e-${++n}';
    return [
      // 本月：三個數的已知資料集（共同收入 20,000、共同錢包 3,000、
      // Mike 先付 6,000＋1,000 再沖掉 1,000、老婆先付 2,000）。
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.income, amount: 20000, categoryId: 'c-salary', occurredOn: _d(y, m, 5), createdBy: kMeId, note: '薪水'),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, amount: 3000, categoryId: 'c-util', occurredOn: _d(y, m, 3), createdBy: kMeId, note: '水電（共同錢包）'),
      Entry(
        id: id(),
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        amount: 6000,
        categoryId: 'c-food',
        occurredOn: _d(y, m, 8),
        createdBy: kMeId,
        note: '本月買菜',
        payerId: kMeId,
        lineItems: const [
          LineItem(id: 'li-1', entryId: 'e-3', name: '雞蛋', amount: 89),
          LineItem(id: 'li-2', entryId: 'e-3', name: '牛奶', amount: 95),
          LineItem(id: 'li-3', entryId: 'e-3', name: '高麗菜', amount: 45),
        ],
      ),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, amount: 2000, categoryId: 'c-dining', occurredOn: _d(y, m, 9), createdBy: kWifeId, note: '週五晚餐', payerId: kWifeId),
      // 沖銷重記（編輯的唯一實作）：原筆 ＋ 反向筆，付款人與日期照抄。
      // 兩筆都留在資料裡，補入剩餘與已花都靠「負數照樣相加」淨算回來。
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1000, categoryId: 'c-dining', occurredOn: _d(y, m, 10), createdBy: kMeId, note: '訂錯的外送', payerId: kMeId),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, amount: -1000, categoryId: 'c-dining', occurredOn: _d(y, m, 10), createdBy: kMeId, note: '沖銷：訂錯的外送', payerId: kMeId, isAdjustment: true),
      // 上月：只有成員先付（共同收入與共同錢包支出一筆都不放，見上面的註解）。
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, amount: 1200, categoryId: 'c-food', occurredOn: DateTime(pm.year, pm.month, 10), createdBy: kMeId, note: '上月買菜', payerId: kMeId),
      Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, amount: 800, categoryId: 'c-dining', occurredOn: DateTime(pm.year, pm.month, 18), createdBy: kWifeId, note: '上月外食', payerId: kWifeId),
    ];
  }

  static List<PersonalTopup> _seedTopups() {
    final now = DateTime.now();
    final m = DateTime(now.year, now.month, 1);
    final pm = DateTime(now.year, now.month - 1, 1);
    return [
      PersonalTopup(id: 'pt-1', ledgerId: kLedgerId, memberId: kMeId, amount: 10000, occurredOn: m, createdBy: kMeId, note: '本月補入'),
      PersonalTopup(id: 'pt-2', ledgerId: kLedgerId, memberId: kWifeId, amount: 10000, occurredOn: m, createdBy: kWifeId, note: '本月補入'),
      PersonalTopup(id: 'pt-3', ledgerId: kLedgerId, memberId: kMeId, amount: 5000, occurredOn: pm, createdBy: kMeId, note: '上月補入'),
      PersonalTopup(id: 'pt-4', ledgerId: kLedgerId, memberId: kWifeId, amount: 5000, occurredOn: pm, createdBy: kWifeId, note: '上月補入'),
    ];
  }

  static List<BudgetAllocation> _seedAllocations() {
    final now = DateTime.now();
    final m = DateTime(now.year, now.month, 1);
    final pm = DateTime(now.year, now.month - 1, 1);
    return [
      BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 6000, occurredOn: m, createdBy: kMeId, note: '本月食品'),
      BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 4000, occurredOn: m, createdBy: kMeId, note: '本月餐飲'),
      BudgetAllocation(id: 'a-3', ledgerId: kLedgerId, categoryId: 'c-util', amount: 3000, occurredOn: m, createdBy: kMeId, note: '本月水電'),
      BudgetAllocation(id: 'a-4', ledgerId: kLedgerId, categoryId: 'c-food', amount: 5000, occurredOn: pm, createdBy: kMeId, note: '上月食品'),
      BudgetAllocation(id: 'a-5', ledgerId: kLedgerId, categoryId: 'c-dining', amount: 3000, occurredOn: pm, createdBy: kMeId, note: '上月餐飲'),
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
}
