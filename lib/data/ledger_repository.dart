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
  /// 衍生數字（共同餘額／可用餘額／信封／超支／個人餘額）一律由後端依 Supabase
  /// 資料計算（Mike 裁示 2026-09-03）；`until` 只取日期分量。
  Future<MonthSummary> monthSummary(String ledgerId, DateTime until);

  // ── 帳本層 ──────────────────────────────────────────────────────────
  /// 目前登入者所屬的所有帳本（`members` 多列＝多帳本）。
  Future<List<Ledger>> myLedgers();
  Future<Ledger> createLedger(String name);
  Future<Ledger> joinLedger(String code);
  Future<Ledger> rotateInviteCode(String ledgerId);

  /// 只送 `name, default_ratio, opening_balance_shared`（其餘欄位沒有 update 授權）。
  Future<void> updateLedger(Ledger ledger);

  /// 只送 `display_name, opening_balance_personal`，且只能是自己那列。
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
  /// [writeSplits]／[writeLineItems] 對應 `upsert_entry` 的三種語意：
  /// `false` ＝ 那張子表完全不動（`null`）；`true` ＝ 用 `entry` 上的清單全刪重建
  /// （空清單就是清空）。已結帳的帳目兩個都必須是 `false`，否則 DB raise。
  Future<Entry> upsertEntry(Entry entry, {bool writeSplits = true, bool writeLineItems = true});

  Future<void> removeEntry(String id);

  /// 直接重寫某筆帳目的細項（先刪後插，同一批）。
  ///
  /// **已結帳的帳目要改細項只能走這支**：ADR-0002 明文允許改細項，但 `upsert_entry`
  /// 的子表寫法是「全刪重建」，settled 下會被 policy 擋成半套，所以那支直接 raise。
  /// `line_items` 表本身對成員是全權（select/insert/update/delete），跟隨父 entry 的 RLS。
  Future<List<LineItem>> replaceLineItems(String entryId, List<LineItem> items);

  // ── 預算撥款 ────────────────────────────────────────────────────────
  Future<List<BudgetAllocation>> fetchAllocations(String ledgerId);
  Future<BudgetAllocation> addAllocation(BudgetAllocation allocation);
  Future<void> removeAllocation(String id);

  // ── 清單／待辦 ──────────────────────────────────────────────────────
  Future<List<ListItem>> fetchListItems(String ledgerId);
  Future<ListItem> addListItem(ListItem item);
  Future<void> updateListItem(ListItem item);
  Future<void> removeListItem(String id);

  // ── 結算（一律走 RPC，前端對 settlements 只有 select） ──────────────
  Future<List<Settlement>> fetchSettlements(String ledgerId);
  Future<Settlement> initiateSettlement(String ledgerId);
  Future<Settlement> approveSettlement(String settlementId);
  Future<Settlement> cancelSettlement(String settlementId);
}

/// 目前使用的資料來源。預設是記憶體實作——測試與 `--dart-define=USE_MOCK=true` 直接可用；
/// `main.dart` 連雲端時 override 成 `SupabaseLedgerRepository`。
final ledgerRepositoryProvider = Provider<LedgerRepository>((ref) => InMemoryLedgerRepository());

/// 目前帳本快照。所有 Notifier 的 `build()` 從這裡取初值（同步）。
///
/// 快取失效時機：切換帳本／登入／登出後 `ref.invalidate(snapshotProvider)`，
/// repository 內的快照已經換過，這裡重算就會把整份資料換掉。
final snapshotProvider = Provider<LedgerSnapshot>((ref) => ref.watch(ledgerRepositoryProvider).snapshot);
