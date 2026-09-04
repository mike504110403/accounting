/// Supabase 實作。寫入入口一律照 `docs/specs/db-contract.md`「寫入入口一覽」：
/// 帳目走 `upsert_entry` RPC、結算走三支 RPC、其餘直接寫表（只送有欄位級授權的欄位）。
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';
import '../domain/month_summary.dart';
import 'errors.dart';
import 'ledger_repository.dart';

class SupabaseLedgerRepository implements LedgerRepository {
  SupabaseLedgerRepository(this._client);

  final SupabaseClient _client;
  LedgerSnapshot _snapshot = LedgerSnapshot.empty();

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const LedgerException('尚未登入');
    return id;
  }

  String get _myMemberId {
    final id = _snapshot.currentMemberId;
    if (id.isEmpty) throw const LedgerException('尚未載入帳本');
    return id;
  }

  // ── 快照 ────────────────────────────────────────────────────────────

  @override
  LedgerSnapshot get snapshot => _snapshot;

  @override
  void clearSnapshot() => _snapshot = LedgerSnapshot.empty();

  @override
  Future<LedgerSnapshot> loadSnapshot(String ledgerId) => guard(() async {
        final uid = _uid;
        final results = await Future.wait<Object>([
          _client.from('ledgers').select().eq('id', ledgerId).single(),
          _client.from('members').select().eq('ledger_id', ledgerId),
          _client.from('categories').select().eq('ledger_id', ledgerId),
          _client.from('entries').select(_entrySelect).eq('ledger_id', ledgerId),
          _client.from('budget_allocation').select().eq('ledger_id', ledgerId),
          _client.from('list_items').select().eq('ledger_id', ledgerId),
          _client.from('settlements').select(_settlementSelect).eq('ledger_id', ledgerId),
        ]);

        final ledger = parseRow('ledgers', Map<String, dynamic>.from(results[0] as Map), Ledger.fromJson);
        final members = parseRows('members', results[1] as List, Member.fromJson);
        final me = members.where((m) => m.userId == uid).toList();
        if (me.isEmpty) throw const LedgerException('你不是這本帳本的成員');

        _snapshot = LedgerSnapshot(
          ledger: ledger,
          members: members,
          categories: parseRows('categories', results[2] as List, Category.fromJson),
          entries: parseRows('entries', results[3] as List, Entry.fromJson),
          allocations: parseRows('budget_allocation', results[4] as List, BudgetAllocation.fromJson),
          listItems: parseRows('list_items', results[5] as List, ListItem.fromJson),
          settlements: parseRows('settlements', results[6] as List, Settlement.fromJson),
          currentMemberId: me.first.id,
        );
        return _snapshot;
      });

  /// 巢狀 select：一次把子表帶回來，不做 N+1。
  static const _entrySelect = '*, line_items(*), entry_splits(*)';
  static const _settlementSelect =
      '*, settlement_entries(entry_id), settlement_approvals(member_id, approved_at)';

  // ── 帳本層 ──────────────────────────────────────────────────────────

  @override
  Future<MonthSummary> monthSummary(String ledgerId, DateTime until) => guard(() async {
        final json = await _client.rpc('month_summary', params: {
          'p_ledger': ledgerId,
          'p_until':
              '${until.year.toString().padLeft(4, '0')}-${until.month.toString().padLeft(2, '0')}-${until.day.toString().padLeft(2, '0')}',
        });
        return MonthSummary.fromJson((json as Map).cast<String, dynamic>());
      });

  @override
  Future<List<Ledger>> myLedgers() => guard(() async {
        // `ledgers` 的 select policy 就是 `is_member(id)`，不必自己再 join members。
        // 依建立時間排序：登入後「沒有存過選擇」時取第一本，順序不定的話每次開機
        // 可能落在不同帳本上。
        final rows = await _client.from('ledgers').select().order('created_at');
        return parseRows('ledgers', rows, Ledger.fromJson);
      });

  @override
  Future<Ledger> createLedger(String name) => guard(() async {
        final row = await _client.rpc<dynamic>('create_ledger', params: {'name': name});
        return parseRow('ledgers', asRowMap(row), Ledger.fromJson);
      });

  @override
  Future<Ledger> joinLedger(String code) => guard(() async {
        final row = await _client.rpc<dynamic>('join_ledger', params: {'code': code});
        return parseRow('ledgers', asRowMap(row), Ledger.fromJson);
      });

  @override
  Future<Ledger> rotateInviteCode(String ledgerId) => guard(() async {
        final row = await _client.rpc<dynamic>('rotate_invite_code', params: {'ledger': ledgerId});
        final ledger = parseRow('ledgers', asRowMap(row), Ledger.fromJson);
        _snapshot = _snapshot.copyWith(ledger: ledger);
        return ledger;
      });

  @override
  Future<void> updateLedger(Ledger ledger) => guard(() async {
        // 只有這三欄有 UPDATE 授權；多送一欄（例如 invite_code）就是 permission denied。
        await _client.from('ledgers').update({
          'name': ledger.name,
          'default_ratio': ledger.defaultRatio,
          'opening_balance_shared': ledger.openingBalanceShared,
        }).eq('id', ledger.id);
        _snapshot = _snapshot.copyWith(ledger: ledger);
      });

  @override
  Future<void> updateMember(Member member) => guard(() async {
        await _client.from('members').update({
          'display_name': member.displayName,
          'opening_balance_personal': member.openingBalancePersonal,
        }).eq('id', member.id);
      });

  @override
  Future<Ledger> fetchLedger(String ledgerId) => guard(() async {
        final row = await _client.from('ledgers').select().eq('id', ledgerId).single();
        return parseRow('ledgers', row, Ledger.fromJson);
      });

  @override
  Future<List<Member>> fetchMembers(String ledgerId) => guard(() async {
        final rows = await _client.from('members').select().eq('ledger_id', ledgerId);
        return parseRows('members', rows, Member.fromJson);
      });

  // ── 分類 ────────────────────────────────────────────────────────────

  @override
  Future<List<Category>> fetchCategories(String ledgerId) => guard(() async {
        final rows = await _client.from('categories').select().eq('ledger_id', ledgerId);
        return parseRows('categories', rows, Category.fromJson);
      });

  @override
  Future<Category> addCategory(Category category) => guard(() async {
        final row = await _client
            .from('categories')
            .insert(category.toJson()..remove('id'))
            .select()
            .single();
        return parseRow('categories', row, Category.fromJson);
      });

  @override
  Future<void> updateCategory(Category category) => guard(() async {
        await _client.from('categories').update({
          'kind': category.toJson()['kind'],
          'name': category.name,
          'icon': category.icon,
          'sort': category.sort,
        }).eq('id', category.id);
      });

  @override
  Future<void> removeCategory(String id) => guard(() async {
        await _client.from('categories').delete().eq('id', id);
      });

  @override
  Future<void> saveCategoryOrder(List<Category> ordered) => guard(() async {
        if (ordered.isEmpty) return;
        // 一個 request 寫完整組，避免中途失敗留下半套排序。
        await _client.from('categories').upsert([for (final c in ordered) c.toJson()]);
      });

  // ── 帳目 ────────────────────────────────────────────────────────────

  @override
  Future<List<Entry>> fetchEntries(String ledgerId) => guard(() async {
        final rows = await _client.from('entries').select(_entrySelect).eq('ledger_id', ledgerId);
        return parseRows('entries', rows, Entry.fromJson);
      });

  @override
  Future<Entry> upsertEntry(Entry entry, {bool writeSplits = true, bool writeLineItems = true}) =>
      guard(() async {
        final row = await _client.rpc<dynamic>('upsert_entry', params: {
          'p_entry': entry.toUpsertJson(),
          // null＝不動那張子表；[]＝清空；有內容＝全刪重建（db-contract 三種語意）。
          'p_splits': writeSplits
              ? [for (final s in entry.splits) {'member_id': s.memberId, 'share': s.share}]
              : null,
          'p_line_items': writeLineItems
              ? [
                  for (final li in entry.lineItems)
                    {'name': li.name, 'amount': li.amount, 'sort': li.sort},
                ]
              : null,
        });
        final id = requireId(row);
        // RPC 只回主筆；子表要再撈一次才拿得到 DB 產生的 id。
        final full = await _client.from('entries').select(_entrySelect).eq('id', id).single();
        return parseRow('entries', full, Entry.fromJson);
      });

  @override
  Future<List<LineItem>> replaceLineItems(String entryId, List<LineItem> items) => guard(() async {
        // 先刪後插。`line_items` 對成員是全權，跟隨父 entry 的 RLS——
        // 已結帳的帳目走這條就不會踩到 `upsert_entry` 的 settled 子表守衛。
        await _client.from('line_items').delete().eq('entry_id', entryId);
        if (items.isEmpty) return const <LineItem>[];
        final rows = await _client
            .from('line_items')
            .insert([
              for (final li in items)
                {'entry_id': entryId, 'name': li.name, 'amount': li.amount, 'sort': li.sort},
            ])
            .select();
        return parseRows('line_items', rows, LineItem.fromJson);
      });

  @override
  Future<void> removeEntry(String id) => guard(() async {
        // 已結帳的帳目被 delete policy 過濾掉＝影響 0 列且不 raise，要自己看回傳列數。
        final rows = await _client.from('entries').delete().eq('id', id).select('id');
        if (rows.isEmpty) throw const LedgerException('這筆帳目無法刪除（可能已結帳）');
      });

  // ── 預算撥款 ────────────────────────────────────────────────────────

  @override
  Future<List<BudgetAllocation>> fetchAllocations(String ledgerId) => guard(() async {
        final rows = await _client.from('budget_allocation').select().eq('ledger_id', ledgerId);
        return parseRows('budget_allocation', rows, BudgetAllocation.fromJson);
      });

  @override
  Future<BudgetAllocation> addAllocation(BudgetAllocation allocation) => guard(() async {
        final payload = allocation.toJson()
          ..remove('id')
          // 不能以別人的名義撥款：created_by 一律強制成自己。
          ..['created_by'] = _myMemberId;
        final row = await _client.from('budget_allocation').insert(payload).select().single();
        return parseRow('budget_allocation', row, BudgetAllocation.fromJson);
      });

  @override
  Future<void> removeAllocation(String id) => guard(() async {
        await _client.from('budget_allocation').delete().eq('id', id);
      });

  // ── 清單／待辦 ──────────────────────────────────────────────────────

  @override
  Future<List<ListItem>> fetchListItems(String ledgerId) => guard(() async {
        final rows = await _client.from('list_items').select().eq('ledger_id', ledgerId);
        return parseRows('list_items', rows, ListItem.fromJson);
      });

  @override
  Future<ListItem> addListItem(ListItem item) => guard(() async {
        final row = await _client
            .from('list_items')
            .insert(item.toJson()..remove('id'))
            .select()
            .single();
        return parseRow('list_items', row, ListItem.fromJson);
      });

  @override
  Future<void> updateListItem(ListItem item) => guard(() async {
        await _client.from('list_items').update(item.toJson()..remove('id')).eq('id', item.id);
      });

  @override
  Future<void> removeListItem(String id) => guard(() async {
        await _client.from('list_items').delete().eq('id', id);
      });

  // ── 結算 ────────────────────────────────────────────────────────────

  @override
  Future<List<Settlement>> fetchSettlements(String ledgerId) => guard(() async {
        final rows =
            await _client.from('settlements').select(_settlementSelect).eq('ledger_id', ledgerId);
        return parseRows('settlements', rows, Settlement.fromJson);
      });

  @override
  Future<Settlement> initiateSettlement(String ledgerId) =>
      _settlementRpc('initiate_settlement', {'ledger': ledgerId});

  @override
  Future<Settlement> approveSettlement(String settlementId) =>
      _settlementRpc('approve_settlement', {'id': settlementId});

  @override
  Future<Settlement> cancelSettlement(String settlementId) =>
      _settlementRpc('cancel_settlement', {'id': settlementId});

  /// 三支結算 RPC 只回 `settlements` 主列（沒有 entryIds／approvedBy），
  /// 再撈一次巢狀版本才是完整的 [Settlement]。
  Future<Settlement> _settlementRpc(String fn, Map<String, dynamic> params) => guard(() async {
        final row = await _client.rpc<dynamic>(fn, params: params);
        final id = requireId(row);
        final full =
            await _client.from('settlements').select(_settlementSelect).eq('id', id).single();
        return parseRow('settlements', full, Settlement.fromJson);
      });

}
