/// 假資料與記憶體 repository（波 1 畫面用；波 2 換成 Supabase 實作，provider 介面不變）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';

const kLedgerId = 'ledger-1';
const kMeId = 'm-mike';
const kWifeId = 'm-wife';

/// 帳本狀態：記憶體版，支援更新（名稱、default_ratio、期初餘額…）。
class LedgerNotifier extends Notifier<Ledger> {
  @override
  Ledger build() => const Ledger(
        id: kLedgerId,
        name: '我們的家',
        inviteCode: 'A7K3QZ',
        defaultRatio: {kMeId: 50, kWifeId: 50},
        openingBalanceShared: 120000,
      );

  void update(Ledger l) => state = l;
}

/// 可寫入的帳本狀態（wave1-budget-settings 寫入用：`ref.read(ledgerStateProvider.notifier).update(...)`）。
final ledgerStateProvider = NotifierProvider<LedgerNotifier, Ledger>(LedgerNotifier.new);

/// 讀取入口，型別維持 Provider&lt;Ledger&gt;（供其他工人 `overrideWithValue` 測試用，不隨波 1 內部改法變動）。
final ledgerProvider = Provider<Ledger>((ref) => ref.watch(ledgerStateProvider));

/// 目前登入者的 member id。
final currentMemberIdProvider = Provider<String>((ref) => kMeId);

/// 成員狀態：記憶體版，支援更新（期初餘額…）。
class MembersNotifier extends Notifier<List<Member>> {
  @override
  List<Member> build() => const [
        Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike', openingBalancePersonal: 50000),
        Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆', openingBalancePersonal: 30000),
      ];

  void update(Member m) => state = [for (final x in state) x.id == m.id ? m : x];
}

/// 可寫入的成員狀態（寫入用：`ref.read(membersStateProvider.notifier).update(...)`）。
final membersStateProvider = NotifierProvider<MembersNotifier, List<Member>>(MembersNotifier.new);

/// 讀取入口，型別維持 Provider&lt;List&lt;Member&gt;&gt;（供其他工人 `overrideWithValue` 測試用）。
final membersProvider = Provider<List<Member>>((ref) => ref.watch(membersStateProvider));

/// 分類狀態：記憶體版，支援新增／修改／刪除／拖曳排序。
class CategoriesNotifier extends Notifier<List<Category>> {
  @override
  List<Category> build() => const [
        Category(id: 'c-food', ledgerId: kLedgerId, kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0, rollover: true),
        Category(id: 'c-dining', ledgerId: kLedgerId, kind: EntryKind.expense, name: '餐飲', icon: 'local_dining', sort: 1),
        Category(id: 'c-daily', ledgerId: kLedgerId, kind: EntryKind.expense, name: '日常用品', icon: 'inventory_2', sort: 2, rollover: true),
        Category(id: 'c-house', ledgerId: kLedgerId, kind: EntryKind.expense, name: '住房', icon: 'home', sort: 3),
        Category(id: 'c-util', ledgerId: kLedgerId, kind: EntryKind.expense, name: '水電', icon: 'bolt', sort: 4),
        Category(id: 'c-transport', ledgerId: kLedgerId, kind: EntryKind.expense, name: '交通', icon: 'directions_car', sort: 5),
        Category(id: 'c-fun', ledgerId: kLedgerId, kind: EntryKind.expense, name: '娛樂', icon: 'sports_esports', sort: 6),
        Category(id: 'c-salary', ledgerId: kLedgerId, kind: EntryKind.income, name: '薪水', icon: 'payments', sort: 0),
        Category(id: 'c-bonus', ledgerId: kLedgerId, kind: EntryKind.income, name: '獎金', icon: 'card_giftcard', sort: 1),
      ];

  void add(Category c) => state = [...state, c];
  void update(Category c) => state = [for (final x in state) x.id == c.id ? c : x];
  void remove(String id) => state = state.where((x) => x.id != id).toList();

  /// 拖曳排序：oldIndex/newIndex 相對於「同 kind、依 sort 排序」後的清單
  /// （ReorderableListView.onReorderItem 語意：newIndex 已針對移除 oldIndex 項目調整過，直接 insert 即可）。
  void reorder(EntryKind kind, int oldIndex, int newIndex) {
    final group = state.where((c) => c.kind == kind).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    // 越界（負值、超出當前 kind 分類數）就當沒事發生，不動 state——呼叫端傳壞索引不該讓資料跑掉。
    if (oldIndex < 0 || oldIndex >= group.length || newIndex < 0 || newIndex >= group.length) return;
    final others = state.where((c) => c.kind != kind).toList();
    final item = group.removeAt(oldIndex);
    group.insert(newIndex, item);
    final resorted = [
      for (var i = 0; i < group.length; i++)
        Category(id: group[i].id, ledgerId: group[i].ledgerId, kind: group[i].kind, name: group[i].name, icon: group[i].icon, sort: i, rollover: group[i].rollover),
    ];
    // 寫回前依 kind、sort 統一排序，不依賴消費端各自 sort——狀態本身就是一致的。
    state = [...others, ...resorted]..sort((a, b) {
      final byKind = a.kind.index.compareTo(b.kind.index);
      return byKind != 0 ? byKind : a.sort.compareTo(b.sort);
    });
  }
}

/// 可寫入的分類狀態（寫入用：`ref.read(categoriesStateProvider.notifier).add/update/remove/reorder(...)`）。
final categoriesStateProvider = NotifierProvider<CategoriesNotifier, List<Category>>(CategoriesNotifier.new);

/// 讀取入口，型別維持 Provider&lt;List&lt;Category&gt;&gt;（供其他工人 `overrideWithValue` 測試用）。
final categoriesProvider = Provider<List<Category>>((ref) => ref.watch(categoriesStateProvider));

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

List<Entry> _seedEntries() {
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
  // 上個月一些資料，讓趨勢與 rollover 有東西可算。
  final pm = DateTime(y, m - 1, 1);
  list.addAll([
    Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.income, scope: EntryScope.shared, amount: 52000, categoryId: 'c-salary', occurredOn: DateTime(pm.year, pm.month, 5), createdBy: kMeId, note: '薪水'),
    Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 26000, categoryId: 'c-house', occurredOn: DateTime(pm.year, pm.month, 1), createdBy: kMeId, note: '房租', splitMethod: SplitMethod.common),
    Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 6200, categoryId: 'c-food', occurredOn: DateTime(pm.year, pm.month, 10), createdBy: kMeId, note: '整月買菜', splitMethod: SplitMethod.common),
    Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 3900, categoryId: 'c-dining', occurredOn: DateTime(pm.year, pm.month, 18), createdBy: kWifeId, note: '外食', splitMethod: SplitMethod.common),
    Entry(id: id(), ledgerId: kLedgerId, kind: EntryKind.expense, scope: EntryScope.shared, amount: 1100, categoryId: 'c-daily', occurredOn: DateTime(pm.year, pm.month, 20), createdBy: kMeId, note: '日用品', splitMethod: SplitMethod.common),
  ]);
  return list;
}

/// 帳目狀態：記憶體版，支援新增／修改／刪除。
class EntriesNotifier extends Notifier<List<Entry>> {
  @override
  List<Entry> build() => _seedEntries();

  void add(Entry e) => state = [...state, e];
  void update(Entry e) => state = [for (final x in state) x.id == e.id ? e : x];
  void remove(String id) => state = state.where((x) => x.id != id).toList();
}

final entriesProvider = NotifierProvider<EntriesNotifier, List<Entry>>(EntriesNotifier.new);

class BudgetsNotifier extends Notifier<List<Budget>> {
  @override
  List<Budget> build() {
    final now = DateTime.now();
    final m = DateTime(now.year, now.month, 1);
    final pm = DateTime(now.year, now.month - 1, 1);
    return [
      Budget(id: 'b-1', ledgerId: kLedgerId, categoryId: 'c-food', month: pm, limit: 5500),
      Budget(id: 'b-2', ledgerId: kLedgerId, categoryId: 'c-dining', month: pm, limit: 4000),
      Budget(id: 'b-3', ledgerId: kLedgerId, categoryId: 'c-daily', month: pm, limit: 1500),
      Budget(id: 'b-4', ledgerId: kLedgerId, categoryId: 'c-house', month: pm, limit: 26000),
      Budget(id: 'b-5', ledgerId: kLedgerId, categoryId: 'c-util', month: m, limit: 3000),
      Budget(id: 'b-6', ledgerId: kLedgerId, categoryId: 'c-transport', month: m, limit: 2000),
    ];
  }

  void upsert(Budget b) {
    final i = state.indexWhere((x) => x.categoryId == b.categoryId && x.month == b.month);
    state = i < 0 ? [...state, b] : [for (var k = 0; k < state.length; k++) k == i ? b : state[k]];
  }
}

final budgetsProvider = NotifierProvider<BudgetsNotifier, List<Budget>>(BudgetsNotifier.new);

class ListItemsNotifier extends Notifier<List<ListItem>> {
  @override
  List<ListItem> build() => [
        const ListItem(id: 'l-1', ledgerId: kLedgerId, title: '衛生紙', store: '藥局', estimated: 199, categoryId: 'c-daily'),
        const ListItem(id: 'l-2', ledgerId: kLedgerId, title: '酸奶', store: '超市', estimated: 120, categoryId: 'c-food', assigneeId: kWifeId),
        const ListItem(id: 'l-3', ledgerId: kLedgerId, title: '麵包', store: '超市', estimated: 80, categoryId: 'c-food'),
        const ListItem(id: 'l-4', ledgerId: kLedgerId, title: '牛奶', store: '超市', estimated: 95, categoryId: 'c-food'),
        const ListItem(id: 'l-5', ledgerId: kLedgerId, title: '運動鞋', store: '購物中心', estimated: 2500, categoryId: 'c-daily', assigneeId: kMeId),
        ListItem(id: 'l-6', ledgerId: kLedgerId, title: '繳管理費', dueOn: DateTime.now().add(const Duration(days: 3)), assigneeId: kMeId),
        ListItem(id: 'l-7', ledgerId: kLedgerId, title: '預約牙醫', dueOn: DateTime.now().add(const Duration(days: 10)), assigneeId: kWifeId),
      ];

  void add(ListItem i) => state = [...state, i];
  void update(ListItem i) => state = [for (final x in state) x.id == i.id ? i : x];
  void remove(String id) => state = state.where((x) => x.id != id).toList();
}

final listItemsProvider = NotifierProvider<ListItemsNotifier, List<ListItem>>(ListItemsNotifier.new);

class SettlementsNotifier extends Notifier<List<Settlement>> {
  @override
  List<Settlement> build() => [
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

  void add(Settlement s) => state = [...state, s];
  void update(Settlement s) => state = [for (final x in state) x.id == s.id ? s : x];
}

final settlementsProvider = NotifierProvider<SettlementsNotifier, List<Settlement>>(SettlementsNotifier.new);
