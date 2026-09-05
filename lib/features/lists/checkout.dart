/// 清單頁的純函式：店家分組、購物項目結帳組裝、到期狀態判斷。
/// 不含 UI；供 widget 呼叫，也直接被單元測試覆蓋。
library;

import '../../domain/models.dart';

/// 沒有店家的購物項目分組標籤。
const kNoStoreLabel = '未分店家';

/// 依 `store` 分組（null → [kNoStoreLabel]），組內依 `sort` 排序；
/// 分組本身依店名字母序，[kNoStoreLabel] 固定排最後。
Map<String, List<ListItem>> groupByStore(List<ListItem> items) {
  final map = <String, List<ListItem>>{};
  for (final item in items) {
    final key = item.store ?? kNoStoreLabel;
    map.putIfAbsent(key, () => []).add(item);
  }
  for (final group in map.values) {
    group.sort((a, b) => a.sort.compareTo(b.sort));
  }
  final keys = map.keys.toList()
    ..sort((a, b) {
      if (a == kNoStoreLabel) return b == kNoStoreLabel ? 0 : 1;
      if (b == kNoStoreLabel) return -1;
      return a.compareTo(b);
    });
  return {for (final k in keys) k: map[k]!};
}

/// 依購物清單項目組裝一筆家庭支出（勾選結帳流程唯一組裝點，v1.5／ADR-0009）：
/// - `actuals` 缺項用該項目的 estimated，兩者皆無則 0。
/// - `total`＝各項金額加總（UI 唯讀，v1.5 不可手改）。
/// - note 用第一個有填店家的項目店名，都沒有則「購物」。
/// - 只記「誰先付」：[payerId] 為 null＝共同錢包、否則該成員先付；沒有範圍／分攤（ADR-0009 廢）。
Entry buildEntryFromItems({
  required List<ListItem> items,
  required Map<String, int> actuals,
  required int total,
  required String categoryId,
  required DateTime date,
  required String ledgerId,
  required String me,
  required String? payerId, // null＝共同錢包
}) {
  assert(items.isNotEmpty);
  // id 一律留空字串＝新筆，交給 repository（Supabase 由 DB）產生。
  const entryId = '';
  String? storeName;
  for (final item in items) {
    if (item.store != null && item.store!.isNotEmpty) {
      storeName = item.store;
      break;
    }
  }
  final lineItems = <LineItem>[
    for (var i = 0; i < items.length; i++)
      LineItem(
        id: '',
        entryId: entryId,
        name: items[i].title,
        amount: actuals[items[i].id] ?? items[i].estimated ?? 0,
        sort: i,
      ),
  ];
  return Entry(
    id: entryId,
    ledgerId: ledgerId,
    kind: EntryKind.expense,
    amount: total,
    categoryId: categoryId,
    occurredOn: date,
    createdBy: me,
    note: storeName ?? '購物',
    payerId: payerId,
    lineItems: lineItems,
  );
}

/// models.dart 的 [ListItem] 沒有 copyWith，這裡就地組裝一份改了 doneAt／entryId 的複本。
ListItem withDone(ListItem item, DateTime? doneAt, {String? entryId}) {
  return ListItem(
    id: item.id,
    ledgerId: item.ledgerId,
    title: item.title,
    store: item.store,
    estimated: item.estimated,
    categoryId: item.categoryId,
    assigneeId: item.assigneeId,
    dueOn: item.dueOn,
    doneAt: doneAt,
    entryId: entryId ?? item.entryId,
    sort: item.sort,
  );
}

/// 多選結帳完成後，把整批項目標成同一筆 entry 完成。
List<ListItem> markItemsDone(List<ListItem> items, String entryId, DateTime doneAt) =>
    [for (final item in items) withDone(item, doneAt, entryId: entryId)];

/// 已完成購物項目在「已完成」列顯示的實際金額：
/// - 找到 item.entryId 對應的 entry，優先用該筆 entry 底下對應的細項金額，找不到細項或 entry 就回退 entry.amount／estimated。
/// - 同一筆 entry 下若有多個同名項目，用「ListItem 依 id 排序的名次」對應「LineItem 依 sort 排序的名次」配對——
///   這是近似對應，不保證與當初勾選時的真實對應關係一致；models.dart 目前沒有欄位能精確反查（LineItem 不記
///   來源 ListItem id），是約束內最佳解。波 2 若 line_item 加上反查欄位，這裡要改成精確比對。
int resolveDoneAmount(ListItem item, List<Entry> entries, List<ListItem> allItems) {
  Entry? entry;
  for (final e in entries) {
    if (e.id == item.entryId) {
      entry = e;
      break;
    }
  }
  if (entry == null) return item.estimated ?? 0;

  final sameNameItems = allItems.where((i) => i.entryId == item.entryId && i.title == item.title).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final sameNameLineItems = entry.lineItems.where((li) => li.name == item.title).toList()
    ..sort((a, b) => a.sort.compareTo(b.sort));
  final rank = sameNameItems.indexWhere((i) => i.id == item.id);
  if (rank >= 0 && rank < sameNameLineItems.length) {
    return sameNameLineItems[rank].amount ?? entry.amount;
  }
  return entry.amount;
}
