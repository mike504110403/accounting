/// 資料層的唯一 seam：`LedgerRepository` 介面 ＋ 兩個實作共用的 provider。
///
/// 兩個實作（[InMemoryLedgerRepository]、`SupabaseLedgerRepository`）跑**同一組**契約測試
/// （`test/data/ledger_repository_contract_test.dart`），所以頁面只要對著介面寫就好。
///
/// 慣例：
/// - **新筆用 `id: ''`**（沿用 `Entry.toUpsertJson()` 的「id 空字串＝新筆」契約）；
///   id 由 repository（Supabase 則是 DB）產生，經回傳值交還呼叫端。
/// - 讀取是快照式：[LedgerRepository.snapshot] 是同步 getter，
///   [LedgerRepository.loadSnapshot] 載入並快取，`fetchXxx` 供 Realtime 事件重抓單表。
/// - 所有方法失敗一律丟 [LedgerException]（已中文化），呼叫端不需要認得 PostgREST。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/month_summary.dart';
import 'in_memory_repository.dart';
import 'snapshot.dart';

export 'errors.dart' show LedgerException;
export 'snapshot.dart';

/// 邀請碼長度（`docs/specs/db-contract.md`：10 碼大寫英數 base32）。
const kInviteCodeLength = 10;

abstract class LedgerRepository {
  // ── 快照 ────────────────────────────────────────────────────────────
  /// 目前已載入的帳本快照；還沒載入時回 [LedgerSnapshot.empty]。
  LedgerSnapshot get snapshot;

  /// 載入整本帳本並快取成 [snapshot]。
  Future<LedgerSnapshot> loadSnapshot(String ledgerId);

  /// 登出／切帳本前把快照清掉（換帳號不得看到上一本的資料）。
  void clearSnapshot();

  // ── 月摘要（DB 端計算）───────────────────────────────────────────────
  /// 衍生數字（共同餘額／預算／已花／超支／每人補入剩餘）一律由後端依 Supabase
  /// 資料計算（Mike 裁示 2026-09-03）；`until` 只取日期分量。
  Future<MonthSummary> monthSummary(String ledgerId, DateTime until);

  // ── 帳本層 ──────────────────────────────────────────────────────────
  /// 目前登入者所屬的所有帳本（`members` 多列＝多帳本）。
  Future<List<Ledger>> myLedgers();
  Future<Ledger> createLedger(String name);
  Future<Ledger> joinLedger(String code);
  Future<Ledger> rotateInviteCode(String ledgerId);

  /// 只送 `name`（v1.5 起 `ledgers` 只有這一欄有 update 授權）。
  Future<void> updateLedger(Ledger ledger);

  /// 只送 `display_name`，且只能是自己那列（v1.5 起 `members` 只有這一欄可改）。
  Future<void> updateMember(Member member);

  Future<Ledger> fetchLedger(String ledgerId);
  Future<List<Member>> fetchMembers(String ledgerId);

  // ── 分類 ────────────────────────────────────────────────────────────
  Future<List<Category>> fetchCategories(String ledgerId);
  Future<Category> addCategory(Category category);
  Future<void> updateCategory(Category category);
  Future<void> removeCategory(String id);

  /// 拖曳排序後一次寫回整組（已重新編好 `sort`）。
  Future<void> saveCategoryOrder(List<Category> ordered);

  // ── 帳目 ────────────────────────────────────────────────────────────
  Future<List<Entry>> fetchEntries(String ledgerId);

  /// 新增或更新一筆帳目（`entry.id` 為空＝新增）。
  ///
  /// [writeLineItems] 對應 `upsert_entry` 的 `p_line_items` 三種語意：
  /// `false` ＝ 細項完全不動（`null`）；`true` ＝ 用 `entry.lineItems` 全刪重建
  /// （空清單就是清空）。v1.5 起沒有分攤子表，所以只剩這一個旗標。
  Future<Entry> upsertEntry(Entry entry, {bool writeLineItems = true});

  Future<void> removeEntry(String id);

  /// 直接重寫某筆帳目的細項（先刪後插，同一批）。
  ///
  /// `line_items` 表本身對成員是全權（select/insert/update/delete），跟隨父 entry 的 RLS；
  /// 已清月份的帳目連細項都動不了（DB 的 `a_line_items_month_closed_trg` 看父筆的 occurred_on）。
  Future<List<LineItem>> replaceLineItems(String entryId, List<LineItem> items);

  // ── 個人補入（v1.5／ADR-0009）────────────────────────────────────────
  Future<List<PersonalTopup>> fetchTopups(String ledgerId);

  /// 記一筆自己的補入。**只能寫自己那列**（`member_id = created_by = 本人`），
  /// 金額必須 > 0，已清月份不可寫；`month` 是 DB 產生的欄位，不送。
  Future<PersonalTopup> addTopup(PersonalTopup topup);

  /// 刪掉自己的一筆補入（未清月才行；`personal_topups` 沒有 UPDATE）。
  Future<void> removeTopup(String id);

  // ── 預算（影子紀錄）──────────────────────────────────────────────────
  Future<List<BudgetAllocation>> fetchAllocations(String ledgerId);

  /// 設定某分類某月的預算。**每分類每月至多一筆、金額 > 0、設定後不可改不可刪**
  /// （v1.4／ADR-0008；DB 連 UPDATE／DELETE 授權都收回了，所以沒有對應的 remove）。
  Future<BudgetAllocation> addAllocation(BudgetAllocation allocation);

  // ── 清單／待辦 ──────────────────────────────────────────────────────
  Future<List<ListItem>> fetchListItems(String ledgerId);
  Future<ListItem> addListItem(ListItem item);
  Future<void> updateListItem(ListItem item);
  Future<void> removeListItem(String id);

  // ── 月清帳（v1.5，只讀 ＋ 兩支 RPC）──────────────────────────────────
  Future<List<MonthClose>> fetchMonthCloses(String ledgerId);

  /// 清帳預覽：可清條件不過就丟 [LedgerException]（中文），過了回和落地
  /// `details` 相同的明細，外加 `income_amount`（落地的快照不帶）。
  Future<MonthCloseDetails> monthClosePreview(String ledgerId, DateTime month);

  /// 執行清帳。任一成員可執行、不需多簽、**不可撤銷**；失敗一律丟 [LedgerException]。
  ///
  /// [recordIncome]＝「一鍵記共同收入」（預設勾）：在同一段交易裡把
  /// 「Σ應轉入 − Σ應補出」記成該月最後一天、分類「清帳轉入」的一筆共同收入
  /// （金額 ≤ 0 就不記），`MonthClose.incomeEntryId` 指向它。
  Future<MonthClose> closeMonth(String ledgerId, DateTime month, {bool recordIncome = true});
}

/// 目前使用的資料來源。預設是記憶體實作——測試與 `--dart-define=USE_MOCK=true` 直接可用；
/// `main.dart` 連雲端時 override 成 `SupabaseLedgerRepository`。
final ledgerRepositoryProvider = Provider<LedgerRepository>((ref) => InMemoryLedgerRepository());

/// 目前帳本快照。所有 Notifier 的 `build()` 從這裡取初值（同步）。
///
/// 快取失效時機：切換帳本／登入／登出後 `ref.invalidate(snapshotProvider)`，
/// repository 內的快照已經換過，這裡重算就會把整份資料換掉。
final snapshotProvider = Provider<LedgerSnapshot>((ref) => ref.watch(ledgerRepositoryProvider).snapshot);
