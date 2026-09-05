/// Supabase 實作。寫入入口一律照 `docs/specs/db-contract.md`「寫入入口一覽」：
/// 帳目走 `upsert_entry` RPC、清帳走 `month_close_preview`／`close_month`，
/// 其餘直接寫表（只送有欄位級授權的欄位）。
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
          _client.from('personal_topups').select().eq('ledger_id', ledgerId),
          _client.from('month_closes').select().eq('ledger_id', ledgerId),
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
          topups: parseRows('personal_topups', results[6] as List, PersonalTopup.fromJson),
          closes: parseRows('month_closes', results[7] as List, MonthClose.fromJson),
          currentMemberId: me.first.id,
        );
        return _snapshot;
      });

  /// 巢狀 select：一次把細項帶回來，不做 N+1（v1.5 沒有分攤子表）。
  static const _entrySelect = '*, line_items(*)';

  // ── 帳本層 ──────────────────────────────────────────────────────────

  @override
  Future<MonthSummary> monthSummary(String ledgerId, DateTime until) => guard(() async {
        final json = await _client.rpc('month_summary', params: {
          'p_ledger': ledgerId,
          'p_until': _dateParam(until),
        });
        // 走 parseRow（與 monthClosePreview 同法）：缺鍵／型別不符要變成可讀的
        // 「資料格式不正確」，不能讓 TypeError 掉進 guard 最外層被誤報成「連線失敗」。
        return parseRow('month_summary', (json as Map).cast<String, dynamic>(),
            MonthSummary.fromJson);
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
        // v1.5：只有 `name` 有 UPDATE 授權；多送一欄（例如 invite_code）就是 permission denied。
        await _client.from('ledgers').update({'name': ledger.name}).eq('id', ledger.id);
        _snapshot = _snapshot.copyWith(ledger: ledger);
      });

  @override
  Future<void> updateMember(Member member) => guard(() async {
        // v1.5：只有 `display_name` 可改，且只能是自己那列。
        await _client
            .from('members')
            .update({'display_name': member.displayName}).eq('id', member.id);
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
  Future<Entry> upsertEntry(Entry entry, {bool writeLineItems = true}) =>
      guard(() async {
        final row = await _client.rpc<dynamic>('upsert_entry', params: {
          'p_entry': entry.toUpsertJson(),
          // null＝不動細項；[]＝清空；有內容＝全刪重建（db-contract 三種語意）。
          'p_line_items': writeLineItems
              ? [
                  for (final li in entry.lineItems)
                    {'name': li.name, 'amount': li.amount, 'sort': li.sort},
                ]
              : null,
        });
        final id = requireId(row);
        // RPC 只回主筆；細項要再撈一次才拿得到 DB 產生的 id。
        final full = await _client.from('entries').select(_entrySelect).eq('id', id).single();
        return parseRow('entries', full, Entry.fromJson);
      });

  @override
  Future<List<LineItem>> replaceLineItems(String entryId, List<LineItem> items) => guard(() async {
        // 先刪後插。`line_items` 對成員是全權，跟隨父 entry 的 RLS
        //（已清月份的父筆連細項都動不了，那是 DB 的鎖月 trigger 擋的）。
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
        // 被 delete policy 過濾掉＝影響 0 列且不 raise，要自己看回傳列數。
        final rows = await _client.from('entries').delete().eq('id', id).select('id');
        if (rows.isEmpty) throw const LedgerException('這筆帳目無法刪除，請重新整理');
      });

  // ── 個人補入（v1.5）─────────────────────────────────────────────────

  @override
  Future<List<PersonalTopup>> fetchTopups(String ledgerId) => guard(() async {
        final rows = await _client.from('personal_topups').select().eq('ledger_id', ledgerId);
        return parseRows('personal_topups', rows, PersonalTopup.fromJson);
      });

  @override
  Future<PersonalTopup> addTopup(PersonalTopup topup) => guard(() async {
        final payload = topup.toJson()
          ..remove('id')
          // 不能以別人的名義補入：created_by 一律強制成自己（比照 addAllocation）。
          // `member_id` **照送呼叫端給的值**——補到別人頭上必須被 RLS 打回 42501，
          // 前端偷偷改寫成自己的話那道 policy 永遠測不到，兩個實作也會分岔
          //（記憶體版對同一個輸入是丟「沒有權限執行這個操作」）。
          ..['created_by'] = _myMemberId;
        final row = await _client.from('personal_topups').insert(payload).select().single();
        return parseRow('personal_topups', row, PersonalTopup.fromJson);
      });

  @override
  Future<void> removeTopup(String id) => guard(() async {
        // 別人的那列被 delete policy 過濾掉＝影響 0 列且不 raise，要自己看回傳列數
        //（比照 removeEntry）。靜靜成功的話，畫面會把一列根本沒刪掉的補入抹掉。
        final rows = await _client.from('personal_topups').delete().eq('id', id).select('id');
        if (rows.isEmpty) throw const LedgerException('這筆補入無法刪除，請重新整理');
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
          // 不能以別人的名義設定預算：created_by 一律強制成自己。
          ..['created_by'] = _myMemberId;
        final row = await _client.from('budget_allocation').insert(payload).select().single();
        return parseRow('budget_allocation', row, BudgetAllocation.fromJson);
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

  // ── 月清帳 ──────────────────────────────────────────────────────────

  @override
  Future<List<MonthClose>> fetchMonthCloses(String ledgerId) => guard(() async {
        final rows = await _client.from('month_closes').select().eq('ledger_id', ledgerId);
        return parseRows('month_closes', rows, MonthClose.fromJson);
      });

  @override
  Future<MonthCloseDetails> monthClosePreview(String ledgerId, DateTime month) => guard(() async {
        final json = await _client.rpc('month_close_preview', params: {
          'p_ledger': ledgerId,
          // 不代為正規化成月初：DB 的第一條可清條件就是「必須是月初」，
          // 前端偷偷改掉的話那條 raise 永遠打不到，兩個實作也會分岔。
          'p_month': _dateParam(month),
        });
        return parseRow('month_close_preview', (json as Map).cast<String, dynamic>(),
            MonthCloseDetails.fromJson);
      });

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month, {bool recordIncome = true}) =>
      guard(() async {
        final row = await _client.rpc<dynamic>('close_month', params: {
          'p_ledger': ledgerId,
          'p_month': _dateParam(month),
          'p_record_income': recordIncome,
        });
        return parseRow('month_closes', asRowMap(row), MonthClose.fromJson);
      });
}

/// `date` 參數一律送 `YYYY-MM-DD`（PostgREST 走具名參數，型別由 DB 那側決定）。
String _dateParam(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

