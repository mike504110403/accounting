/// 清單頁的純函式：店家分組、購物項目結帳組裝、到期狀態判斷。
/// 不含 UI；供 widget 呼叫，也直接被單元測試覆蓋。
library;

import '../../domain/models.dart';

/// 沒有店家的購物項目分組標籤。
const kNoStoreLabel = '未分店家';

int _seq = 0;

/// 產生本機端唯一 id（波 1 記憶體 repository 用；波 2 換 Supabase 後由 DB 產生）。
String newListId(String prefix) {
  _seq++;
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$_seq';
}

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

/// 依購物清單項目組裝一筆共同支出（勾選結帳流程唯一組裝點）：
/// - `actuals` 缺項用該項目的 estimated，兩者皆無則 0。
/// - `total` 由呼叫端決定（可手改，ADR-0001 允許與細項加總有差額）。
/// - note 用第一個有填店家的項目店名，都沒有則「購物」。
/// - 依 ADR-0005 新增共同支出預設：payer 共同錢包、split common。
Entry buildEntryFromItems({
  required List<ListItem> items,
  required Map<String, int> actuals,
  required int total,
  required String categoryId,
  required DateTime date,
  required String ledgerId,
  required String me,
}) {
  assert(items.isNotEmpty);
  final entryId = newListId('e');
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
        id: newListId('li'),
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
    scope: EntryScope.shared,
    amount: total,
    categoryId: categoryId,
    occurredOn: date,
    createdBy: me,
    note: storeName ?? '購物',
    splitMethod: SplitMethod.common,
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

/// 待辦到期狀態：過期、3 天內即將到期、正常、無到期日。
enum DueStatus { none, overdue, soon, normal }

DueStatus dueStatus(DateTime? dueOn, DateTime now) {
  if (dueOn == null) return DueStatus.none;
  final today = DateTime(now.year, now.month, now.day);
  final due = DateTime(dueOn.year, dueOn.month, dueOn.day);
  final diffDays = due.difference(today).inDays;
  if (diffDays < 0) return DueStatus.overdue;
  if (diffDays <= 3) return DueStatus.soon;
  return DueStatus.normal;
}
