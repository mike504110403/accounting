/// 帳本快照：一次把整本帳本的資料撈進記憶體，之後所有讀取都是同步的
/// （Mike 裁示 A：快照式，provider 維持同步 `Notifier<T>`，不引入 AsyncNotifier）。
library;

import '../domain/models.dart';

/// 一本帳本在某個時間點的完整內容。
///
/// 刻意**不覆寫 `==`**：`snapshotProvider` 靠「換了一個新實例」通知所有 Notifier 重建，
/// 值相等就不重建的話，「切到另一本內容碰巧一樣的帳本」會靜靜不換資料。
class LedgerSnapshot {
  const LedgerSnapshot({
    required this.ledger,
    required this.members,
    required this.categories,
    required this.entries,
    required this.allocations,
    required this.listItems,
    required this.topups,
    required this.closes,
    required this.currentMemberId,
  });

  /// 尚未載入任何帳本時的佔位快照。
  ///
  /// 這種狀態下 `router.redirect` 已經把使用者送去 `/login` 或 `/onboarding`，
  /// 四個 Tab 不會被 build；佔位值只是讓 provider 圖不必為了「還沒登入」丟例外。
  factory LedgerSnapshot.empty() => const LedgerSnapshot(
        ledger: Ledger(id: '', name: '', inviteCode: ''),
        members: [],
        categories: [],
        entries: [],
        allocations: [],
        listItems: [],
        topups: [],
        closes: [],
        currentMemberId: '',
      );

  final Ledger ledger;
  final List<Member> members;
  final List<Category> categories;
  final List<Entry> entries;
  final List<BudgetAllocation> allocations;
  final List<ListItem> listItems;

  /// 個人補入（v1.5／ADR-0009）：每人每月手動記的補入，兩人都看得到彼此的。
  final List<PersonalTopup> topups;

  /// 這本帳本的清帳紀錄（v1.5／ADR-0009），前端只讀。
  final List<MonthClose> closes;

  /// 目前登入者在這本帳本的 member id。
  final String currentMemberId;

  bool get isEmpty => ledger.id.isEmpty;

  LedgerSnapshot copyWith({
    Ledger? ledger,
    List<Member>? members,
    List<Category>? categories,
    List<Entry>? entries,
    List<BudgetAllocation>? allocations,
    List<ListItem>? listItems,
    List<PersonalTopup>? topups,
    List<MonthClose>? closes,
    String? currentMemberId,
  }) =>
      LedgerSnapshot(
        ledger: ledger ?? this.ledger,
        members: members ?? this.members,
        categories: categories ?? this.categories,
        entries: entries ?? this.entries,
        allocations: allocations ?? this.allocations,
        listItems: listItems ?? this.listItems,
        topups: topups ?? this.topups,
        closes: closes ?? this.closes,
        currentMemberId: currentMemberId ?? this.currentMemberId,
      );
}
