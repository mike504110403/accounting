/// 測試共用的資料層腳手架。
///
/// 波 2 之後 Notifier 的初值來自 `snapshotProvider`（也就是 repository 手上的快照），
/// 寫入也真的打到 repository——所以「換一組資料」的正確做法是換一個 seed 過的
/// [InMemoryLedgerRepository]，而不是只 override Notifier 的 `build()`
/// （那樣 state 有假資料、repository 沒有，一寫入就對不上）。
library;

import 'dart:async';

import 'package:accounting/data/in_memory_repository.dart';
import 'package:accounting/data/ledger_repository.dart';
import 'package:accounting/data/realtime.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/domain/month_summary.dart';

/// 波 1 那組假資料的快照。
LedgerSnapshot seedSnapshot() => InMemoryLedgerRepository().snapshot;

/// 以波 1 假資料為底，換掉指定的幾張表。
LedgerSnapshot snapshotWith({
  Ledger? ledger,
  List<Member>? members,
  List<Category>? categories,
  List<Entry>? entries,
  List<BudgetAllocation>? allocations,
  List<ListItem>? listItems,
  List<Settlement>? settlements,
  List<MonthClose>? closes,
  String? currentMemberId,
}) =>
    seedSnapshot().copyWith(
      ledger: ledger,
      members: members,
      categories: categories,
      entries: entries,
      allocations: allocations,
      listItems: listItems,
      settlements: settlements,
      closes: closes,
      currentMemberId: currentMemberId,
    );

/// 指定內容的記憶體 repository。
InMemoryLedgerRepository repoWith({
  Ledger? ledger,
  List<Member>? members,
  List<Category>? categories,
  List<Entry>? entries,
  List<BudgetAllocation>? allocations,
  List<ListItem>? listItems,
  List<Settlement>? settlements,
  List<MonthClose>? closes,
  String? currentMemberId,
}) =>
    InMemoryLedgerRepository(
      seed: snapshotWith(
        ledger: ledger,
        members: members,
        categories: categories,
        entries: entries,
        allocations: allocations,
        listItems: listItems,
        settlements: settlements,
        closes: closes,
        currentMemberId: currentMemberId,
      ),
    );

/// 一筆清帳紀錄（v1.4）。`details` 是清帳當下的事實快照，測試要什麼數字就給什麼數字。
MonthClose closeFixture({
  required DateTime month,
  String? id,
  String closedBy = kMeId,
  DateTime? closedAt,
  List<MonthCloseMemberLine> members = const [],
  int sharedDelta = 0,
}) =>
    MonthClose(
      id: id ?? 'mc-${month.year}-${month.month.toString().padLeft(2, '0')}',
      ledgerId: kLedgerId,
      month: month,
      closedBy: closedBy,
      closedAt: closedAt ?? DateTime(month.year, month.month + 1, 3, 9),
      details: MonthCloseDetails(month: month, members: members, sharedDelta: sharedDelta),
    );

/// 清帳明細裡的一位成員：`ending` 一律＝`topup + net`（DB 那側也是這樣算的，
/// 測試自己編一個對不上的 ending 只會測到不存在的世界）。
MonthCloseMemberLine closeLine({
  required String memberId,
  required String displayName,
  int topup = 0,
  int net = 0,
}) =>
    MonthCloseMemberLine(
      memberId: memberId,
      displayName: displayName,
      topup: topup,
      net: net,
      ending: topup + net,
    );

/// 讓指定的寫入操作一律失敗，其餘照常——用來驗「失敗路徑不留半套狀態」。
///
/// 繼承而不是包一層 delegate：介面有二十幾支方法，delegate 的樣板碼比測試本身還長。
class FailingRepository extends InMemoryLedgerRepository {
  FailingRepository({
    super.seed,
    this.failUpsertEntry = false,
    this.failRemoveEntry = false,
    this.failAddCategory = false,
    this.failUpdateCategory = false,
    this.failRemoveCategory = false,
    this.failSaveCategoryOrder = false,
    this.failAddListItem = false,
    this.failUpdateListItem = false,
    this.failRemoveListItem = false,
    this.failUpdateListItemOnCall = -1,
    this.failAddAllocation = false,
    this.failUpdateLedger = false,
    this.failUpdateMember = false,
    this.failInitiateSettlement = false,
    this.failApproveSettlement = false,
    this.failMyLedgers = false,
    this.failJoinLedger = false,
    this.failCreateLedger = false,
    this.failMonthClosePreview = false,
    this.failCloseMonth = false,
  });

  final bool failUpsertEntry;
  final bool failRemoveEntry;
  final bool failAddCategory;
  final bool failUpdateCategory;
  final bool failRemoveCategory;
  final bool failSaveCategoryOrder;
  final bool failAddListItem;
  final bool failUpdateListItem;
  final bool failRemoveListItem;

  /// ≥0＝**只有第 n 次**（0 起算）`updateListItem` 失敗，其餘照常成功。
  ///
  /// 刻意只炸一次：補償迴圈自己也會呼叫 `updateListItem`，若「第 n 次以後全炸」，
  /// 復原本身也會被打中，測到的就變成「連補償都救不回來」那個更極端的情境。
  final int failUpdateListItemOnCall;
  final bool failAddAllocation;
  final bool failUpdateLedger;
  final bool failUpdateMember;
  final bool failInitiateSettlement;
  final bool failApproveSettlement;
  final bool failMyLedgers;
  final bool failJoinLedger;
  final bool failCreateLedger;

  /// 清帳的兩條 await：預覽炸掉 → 頁內錯誤行不開 sheet；清帳炸掉 → sheet 內錯誤行不 pop。
  final bool failMonthClosePreview;
  final bool failCloseMonth;

  int _updateListItemCalls = 0;

  static Never _boom() => throw const LedgerException('boom');

  @override
  Future<Entry> upsertEntry(Entry entry, {bool writeSplits = true, bool writeLineItems = true}) =>
      failUpsertEntry
          ? _boom()
          : super.upsertEntry(entry, writeSplits: writeSplits, writeLineItems: writeLineItems);

  @override
  Future<void> removeEntry(String id) => failRemoveEntry ? _boom() : super.removeEntry(id);

  @override
  Future<Category> addCategory(Category c) => failAddCategory ? _boom() : super.addCategory(c);

  @override
  Future<void> updateCategory(Category c) => failUpdateCategory ? _boom() : super.updateCategory(c);

  @override
  Future<void> removeCategory(String id) => failRemoveCategory ? _boom() : super.removeCategory(id);

  @override
  Future<void> saveCategoryOrder(List<Category> ordered) =>
      failSaveCategoryOrder ? _boom() : super.saveCategoryOrder(ordered);

  @override
  Future<ListItem> addListItem(ListItem i) => failAddListItem ? _boom() : super.addListItem(i);

  @override
  Future<void> updateListItem(ListItem i) {
    if (failUpdateListItem) return _boom();
    if (failUpdateListItemOnCall >= 0 && _updateListItemCalls++ == failUpdateListItemOnCall) {
      return _boom();
    }
    return super.updateListItem(i);
  }

  @override
  Future<void> removeListItem(String id) => failRemoveListItem ? _boom() : super.removeListItem(id);

  @override
  Future<BudgetAllocation> addAllocation(BudgetAllocation a) =>
      failAddAllocation ? _boom() : super.addAllocation(a);

  @override
  Future<void> updateLedger(Ledger l) => failUpdateLedger ? _boom() : super.updateLedger(l);

  @override
  Future<void> updateMember(Member m) => failUpdateMember ? _boom() : super.updateMember(m);

  @override
  Future<Settlement> initiateSettlement(String ledgerId) =>
      failInitiateSettlement ? _boom() : super.initiateSettlement(ledgerId);

  @override
  Future<Settlement> approveSettlement(String id) =>
      failApproveSettlement ? _boom() : super.approveSettlement(id);

  @override
  Future<List<Ledger>> myLedgers() => failMyLedgers ? _boom() : super.myLedgers();

  @override
  Future<Ledger> joinLedger(String code) => failJoinLedger ? _boom() : super.joinLedger(code);

  @override
  Future<Ledger> createLedger(String name) => failCreateLedger ? _boom() : super.createLedger(name);

  @override
  Future<MonthCloseDetails> monthClosePreview(String ledgerId, DateTime month) =>
      failMonthClosePreview ? _boom() : super.monthClosePreview(ledgerId, month);

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month) =>
      failCloseMonth ? _boom() : super.closeMonth(ledgerId, month);
}

/// 「這個帳號還沒有任何帳本」的 repository：首登流程用。
///
/// 一開始快照是空的（`hasLedgerProvider` 因此為 false → redirect 送去 `/onboarding`），
/// 建帳本或以邀請碼加入之後就恢復成一般的記憶體實作。
class NoLedgerRepository extends InMemoryLedgerRepository {
  NoLedgerRepository() {
    clearSnapshot();
  }

  @override
  Future<List<Ledger>> myLedgers() async => snapshot.isEmpty ? const [] : super.myLedgers();
}

/// 手動觸發的 Realtime 事件來源：驗「事件到達就重抓該表」。
class FakeRealtimeSource implements RealtimeSource {
  void Function(LedgerTable table)? _onChange;
  String? subscribedLedgerId;
  int unsubscribeCount = 0;

  @override
  void subscribe(String ledgerId, void Function(LedgerTable table) onChange) {
    subscribedLedgerId = ledgerId;
    _onChange = onChange;
  }

  @override
  Future<void> unsubscribe() async {
    unsubscribeCount++;
    _onChange = null;
  }

  void emit(LedgerTable table) => _onChange?.call(table);
}

/// 有帳本、但本機還沒選過（快照是空的）——換一台裝置／清過瀏覽器資料就是這個狀態。
class UnselectedLedgerRepository extends InMemoryLedgerRepository {
  UnselectedLedgerRepository() {
    clearSnapshot();
  }
}

/// 上一個帳號的快照還留在記憶體裡，但新登入的帳號一本帳本也沒有。
///
/// 專門用來驗「換帳號不得看到上一個帳號的資料」：只要哪一個 frame 漏了清快照，
/// 舊帳本的字串就會出現在畫面上。
class StaleSnapshotRepository extends InMemoryLedgerRepository {
  @override
  Future<List<Ledger>> myLedgers() async => const [];
}

/// `loadSnapshot` 在 [failLoad] 為 true 時失敗：驗開機載快照失敗的錯誤畫面與重試。
/// 把旗標翻掉就是「網路恢復了」。
class FlakyLoadRepository extends InMemoryLedgerRepository {
  FlakyLoadRepository({super.seed});

  bool failLoad = true;

  @override
  Future<LedgerSnapshot> loadSnapshot(String ledgerId) {
    if (failLoad) throw const LedgerException('連線失敗，請檢查網路後再試');
    return super.loadSnapshot(ledgerId);
  }
}

/// `monthSummary`（`month_summary` RPC）永遠不 resolve：用來驗「server 還沒回應時
/// 畫面吃前端本地公式的 fallback 值」（`monthSummaryProvider(...).value` 永遠是
/// null，不是「resolve 成某個值」，兩者對呼叫端的意義不同，這裡要驗的是前者）。
class NeverRespondingMonthSummaryRepository extends InMemoryLedgerRepository {
  NeverRespondingMonthSummaryRepository({super.seed});

  @override
  Future<MonthSummary> monthSummary(String ledgerId, DateTime until) =>
      Completer<MonthSummary>().future;
}
