/// 各表的 provider 層。**provider 名稱與型別是波 1 就固定下來的公開介面，不隨資料來源變動**。
///
/// 形狀（Mike 裁示 A：快照式）：
/// - `build()` 從 `snapshotProvider` 同步取初值——所以頁面不必處理 loading／error 狀態，
///   也不需要 AsyncNotifier。
/// - 每個寫入方法都是 `Future`：`await repository.xxx()` 成功之後才改 `state`，
///   失敗時 `state` 根本沒動過（不做樂觀更新＝不需要回滾邏輯，也就不會有回滾寫錯的路徑）。
/// - 新增類方法回傳「DB 存好之後」的實體：id 由 DB 產生，呼叫端要拿它做後續動作
///   （例如 checkout 第二步失敗時要刪掉剛建的 entry）。
/// - `refresh()` 給 Realtime 事件用：重抓該表整份取代 state。
///
/// 假資料本身住在 `lib/data/in_memory_repository.dart`。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ledger_repository.dart';
import 'models.dart';

export '../data/in_memory_repository.dart' show InMemoryLedgerRepository, kLedgerId, kMeId, kWifeId;
export '../data/ledger_repository.dart'
    show LedgerRepository, LedgerException, LedgerSnapshot, ledgerRepositoryProvider, snapshotProvider;

/// 帳本狀態（v1.5 只剩名稱與邀請碼）。
class LedgerNotifier extends Notifier<Ledger> {
  @override
  Ledger build() => ref.watch(snapshotProvider).ledger;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// 只有名稱改得動（repository 也只送 `name`）。
  Future<void> update(Ledger l) async {
    await _repo.updateLedger(l);
    state = l;
  }

  /// 換一張新的 10 碼邀請碼（舊碼立刻失效）。
  Future<void> rotateInviteCode() async {
    state = await _repo.rotateInviteCode(state.id);
  }

  Future<void> refresh() async {
    state = await _repo.fetchLedger(state.id);
  }
}

/// 可寫入的帳本狀態（寫入用：`await ref.read(ledgerStateProvider.notifier).update(...)`）。
final ledgerStateProvider = NotifierProvider<LedgerNotifier, Ledger>(LedgerNotifier.new);

/// 讀取入口，型別維持 Provider&lt;Ledger&gt;（供其他工人 `overrideWithValue` 測試用）。
final ledgerProvider = Provider<Ledger>((ref) => ref.watch(ledgerStateProvider));

/// 目前登入者在這本帳本的 member id。
final currentMemberIdProvider = Provider<String>((ref) => ref.watch(snapshotProvider).currentMemberId);

/// 成員狀態（v1.5 只有「我的名稱」改得動）。
class MembersNotifier extends Notifier<List<Member>> {
  @override
  List<Member> build() => ref.watch(snapshotProvider).members;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  Future<void> update(Member m) async {
    await _repo.updateMember(m);
    state = [for (final x in state) x.id == m.id ? m : x];
  }

  Future<void> refresh() async {
    state = await _repo.fetchMembers(ref.read(snapshotProvider).ledger.id);
  }
}

/// 可寫入的成員狀態（寫入用：`await ref.read(membersStateProvider.notifier).update(...)`）。
final membersStateProvider = NotifierProvider<MembersNotifier, List<Member>>(MembersNotifier.new);

/// 讀取入口，型別維持 Provider&lt;List&lt;Member&gt;&gt;（供其他工人 `overrideWithValue` 測試用）。
final membersProvider = Provider<List<Member>>((ref) => ref.watch(membersStateProvider));

/// 分類狀態：新增／修改／刪除／拖曳排序。
class CategoriesNotifier extends Notifier<List<Category>> {
  @override
  List<Category> build() => _sorted(ref.watch(snapshotProvider).categories);

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// 狀態本身就依 kind、sort 一致排好，不依賴各消費端自己 sort。
  static List<Category> _sorted(List<Category> cs) => [...cs]..sort((a, b) {
        final byKind = a.kind.index.compareTo(b.kind.index);
        return byKind != 0 ? byKind : a.sort.compareTo(b.sort);
      });

  /// [c] 的 id 留空字串＝新筆，由 repository（Supabase 則是 DB）產生 id。
  Future<Category> add(Category c) async {
    final saved = await _repo.addCategory(c);
    state = _sorted([...state, saved]);
    return saved;
  }

  Future<void> update(Category c) async {
    await _repo.updateCategory(c);
    state = _sorted([for (final x in state) x.id == c.id ? c : x]);
  }

  Future<void> remove(String id) async {
    await _repo.removeCategory(id);
    state = state.where((x) => x.id != id).toList();
  }

  /// 拖曳排序：oldIndex/newIndex 相對於「同 kind、依 sort 排序」後的清單
  /// （ReorderableListView.onReorderItem 語意：newIndex 已針對移除 oldIndex 項目調整過，直接 insert 即可）。
  Future<void> reorder(EntryKind kind, int oldIndex, int newIndex) async {
    final group = state.where((c) => c.kind == kind).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    // 越界（負值、超出當前 kind 分類數）就當沒事發生，不動 state——呼叫端傳壞索引不該讓資料跑掉。
    if (oldIndex < 0 || oldIndex >= group.length || newIndex < 0 || newIndex >= group.length) return;
    final item = group.removeAt(oldIndex);
    group.insert(newIndex, item);
    final resorted = [
      for (var i = 0; i < group.length; i++)
        Category(
          id: group[i].id,
          ledgerId: group[i].ledgerId,
          kind: group[i].kind,
          name: group[i].name,
          icon: group[i].icon,
          sort: i,
        ),
    ];
    await _repo.saveCategoryOrder(resorted);
    final byId = {for (final c in resorted) c.id: c};
    state = _sorted([for (final c in state) byId[c.id] ?? c]);
  }

  Future<void> refresh() async {
    state = _sorted(await _repo.fetchCategories(ref.read(snapshotProvider).ledger.id));
  }
}

/// 可寫入的分類狀態（寫入用：`await ref.read(categoriesStateProvider.notifier).add/update/remove/reorder(...)`）。
final categoriesStateProvider =
    NotifierProvider<CategoriesNotifier, List<Category>>(CategoriesNotifier.new);

/// 讀取入口，型別維持 Provider&lt;List&lt;Category&gt;&gt;（供其他工人 `overrideWithValue` 測試用）。
final categoriesProvider = Provider<List<Category>>((ref) => ref.watch(categoriesStateProvider));

/// 帳目狀態：新增／修改／刪除。寫入一律走 `upsert_entry`（主筆＋細項同一交易）。
class EntriesNotifier extends Notifier<List<Entry>> {
  @override
  List<Entry> build() => ref.watch(snapshotProvider).entries;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// [e] 的 id 留空字串＝新筆。回傳的是存好之後（帶 DB id 與子表 id）的那筆。
  Future<Entry> add(Entry e) async {
    final saved = await _repo.upsertEntry(e);
    state = [...state, saved];
    return saved;
  }

  /// [writeLineItems] 見 `LedgerRepository.upsertEntry`（`false`＝細項完全不動）。
  Future<Entry> update(Entry e, {bool writeLineItems = true}) async {
    final saved = await _repo.upsertEntry(e, writeLineItems: writeLineItems);
    state = [for (final x in state) x.id == saved.id ? saved : x];
    return saved;
  }

  /// 直接重寫細項（先刪後插）。
  Future<void> replaceLineItems(String entryId, List<LineItem> items) async {
    final saved = await _repo.replaceLineItems(entryId, items);
    state = [
      for (final x in state) x.id == entryId ? x.copyWith(lineItems: saved) : x,
    ];
  }

  Future<void> remove(String id) async {
    await _repo.removeEntry(id);
    state = state.where((x) => x.id != id).toList();
  }

  Future<void> refresh() async {
    state = await _repo.fetchEntries(ref.read(snapshotProvider).ledger.id);
  }
}

final entriesProvider = NotifierProvider<EntriesNotifier, List<Entry>>(EntriesNotifier.new);

/// 預算狀態（ADR-0008，v1.5 沿用）：一列＝某分類某月的預算影子紀錄。
/// **只有 add**——設定後不可改、不可刪、不可退回（DB 連 UPDATE／DELETE 授權都收回了）。
class AllocationsNotifier extends Notifier<List<BudgetAllocation>> {
  @override
  List<BudgetAllocation> build() => ref.watch(snapshotProvider).allocations;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// [a] 的 id 留空字串＝新筆。
  Future<BudgetAllocation> add(BudgetAllocation a) async {
    final saved = await _repo.addAllocation(a);
    state = [...state, saved];
    return saved;
  }

  Future<void> refresh() async {
    state = await _repo.fetchAllocations(ref.read(snapshotProvider).ledger.id);
  }
}

final allocationsProvider =
    NotifierProvider<AllocationsNotifier, List<BudgetAllocation>>(AllocationsNotifier.new);

class ListItemsNotifier extends Notifier<List<ListItem>> {
  @override
  List<ListItem> build() => ref.watch(snapshotProvider).listItems;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// [i] 的 id 留空字串＝新筆。
  Future<ListItem> add(ListItem i) async {
    final saved = await _repo.addListItem(i);
    state = [...state, saved];
    return saved;
  }

  Future<void> update(ListItem i) async {
    await _repo.updateListItem(i);
    state = [for (final x in state) x.id == i.id ? i : x];
  }

  Future<void> remove(String id) async {
    await _repo.removeListItem(id);
    state = state.where((x) => x.id != id).toList();
  }

  Future<void> refresh() async {
    state = await _repo.fetchListItems(ref.read(snapshotProvider).ledger.id);
  }
}

final listItemsProvider = NotifierProvider<ListItemsNotifier, List<ListItem>>(ListItemsNotifier.new);

/// 個人補入狀態（v1.5／ADR-0009）：每人每月手動記的補入，**只有 add／remove**
/// （`personal_topups` 沒有 UPDATE），而且只能動自己那列。
///
/// 快取生命週期與其他表相同：`build()` 從 `snapshotProvider` 取初值（切帳本／登入／
/// 登出時整份重建）；Realtime 的 `personal_topups` 事件與輪詢都走 [refresh] 重抓整表；
/// [add]／[remove] 成功後同步更新 state，不等事件回來。
class TopupsNotifier extends Notifier<List<PersonalTopup>> {
  @override
  List<PersonalTopup> build() => ref.watch(snapshotProvider).topups;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// [t] 的 id 留空字串＝新筆。回傳的是存好之後（帶 DB id 與 month）的那筆。
  Future<PersonalTopup> add(PersonalTopup t) async {
    final saved = await _repo.addTopup(t);
    state = [...state, saved];
    return saved;
  }

  Future<void> remove(String id) async {
    await _repo.removeTopup(id);
    state = state.where((x) => x.id != id).toList();
  }

  Future<void> refresh() async {
    state = await _repo.fetchTopups(ref.read(snapshotProvider).ledger.id);
  }
}

final topupsProvider =
    NotifierProvider<TopupsNotifier, List<PersonalTopup>>(TopupsNotifier.new);

/// 清帳紀錄（v1.5／ADR-0009）。前端只讀：清帳只能經 `close_month` RPC，
/// 成功之後由呼叫端（或 Realtime 的 `month_closes` 事件）`refresh()` 把列表換掉。
class MonthClosesNotifier extends Notifier<List<MonthClose>> {
  @override
  List<MonthClose> build() => ref.watch(snapshotProvider).closes;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  Future<void> refresh() async {
    state = await _repo.fetchMonthCloses(ref.read(snapshotProvider).ledger.id);
  }
}

final monthClosesProvider =
    NotifierProvider<MonthClosesNotifier, List<MonthClose>>(MonthClosesNotifier.new);
