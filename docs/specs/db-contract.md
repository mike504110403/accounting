# DB 契約（Supabase）— 波 2 前端接線用

> 對照 `docs/specs/ledger.md`「領域模型」與 ADR-0001～0005。
> Migration 檔在 `supabase/migrations/`；地端驗證用 `supabase/tests/run.sh`。

## Migration 一覽

函式一律用 `create or replace`，同名函式的**最後一次定義**才是現行版本。
最右欄列出「這支 migration 留下來、目前仍生效」的函式，找定義時直接看那一欄。

| 檔名 | 內容 | 這支留下的「活」函式定義 |
| --- | --- | --- |
| `20260902000100_schema.sql` | 擴充（`pg_trgm` 裝在 `extensions` schema，索引用 `extensions.gin_trgm_ops`）、enum、11 張表、索引、邀請碼產生函式 | —（`gen_invite_code` 已被 0017 取代） |
| `20260902000200_rls.sql` | `is_member` / `my_member_id`、全表 RLS 與 policy、authenticated 授權 | `is_member`、`my_member_id` |
| `20260902000300_triggers.sql` | settled 鎖定、settling 期間改動 void、多簽到齊落 settled、`required_signers` | `entries_void_pending_settlement`、`entry_splits_void_pending_settlement`、`entry_splits_lock_settled`、`settlement_finalize_on_approval` |
| `20260902000400_rpc.sql` | `create_ledger`／`join_ledger`／`initiate_settlement`／`approve_settlement`／`search_items` 與授權 | `join_ledger`、`approve_settlement`、`search_items` |
| `20260902000500_realtime.sql` | `supabase_realtime` publication 收錄 entries / settlements / list_items（冪等寫法） | — |
| `20260902000600_entry_identity.sql` | `entries.created_by`／`ledger_id` 不可變（with check 看不到 OLD，用 trigger 補） | `entries_immutable_identity` |
| `20260902000700_void_trigger_compare_values.sql` | void trigger 加 `when` 子句比對新舊值：值不變就不 void（整列 update 安全） | —（只改 trigger 定義） |
| `20260902000800_privilege_hardening.sql` | anon 全表無權；settlements／settlement_entries 前端只讀；entries 欄位級 update；內部函式 revoke anon/authenticated | `entries_force_open_on_insert` |
| `20260902000900_signers_snapshot.sql` | `settlement_signers` 需簽者快照表、settlements 狀態機、簽名守衛、`cancel_settlement` | `required_signers`、`required_signers_internal`、`settlements_status_machine`、`settlement_approvals_guard`、`cancel_settlement` |
| `20260902001000_delete_paths.sql` | delete 走 before trigger（早於 cascade）；settled 不可刪；分攤 delete 鎖 | `entries_before_delete`、`entry_splits_lock_settled_delete` |
| `20260902001100_settlement_conservation.sql` | 結算涵蓋須有分攤列、逐筆 Σshare 守恆、Σnets 守恆、需簽者快照寫入 | —（`initiate_settlement` 已被 0015 取代） |
| `20260902001200_conventions.sql` | pg_trgm 移入 `extensions` schema、realtime publication 冪等、鎖定訊息依欄位分列 | —（`entries_lock_settled` 已被 0016 取代） |
| `20260902001300_concurrency_and_readonly.sql` | 一帳本一 pending 的 partial unique index、settled 不可刪的 delete policy、簽名收回前端、members 身分不可變 | `void_settlements_for_entry`、`settlement_entries_same_ledger`、`members_immutable_identity` |
| `20260902001400_cross_ledger_fk.sql` | `(id, ledger_id)` 唯一鍵＋複合 FK／check trigger，杜絕跨帳本引用 | `list_items_same_ledger`、`entry_splits_same_ledger` |
| `20260902001500_split_conservation_and_rounding.sql` | 分攤守恆 deferred constraint trigger、發起結算 advisory lock、淨額最大餘數法 | `entry_splits_sum_check`、`initiate_settlement` |
| `20260902001600_lock_occurred_on.sql` | 已結帳連 `occurred_on` 一起鎖；settling 期間改日期也 void | `entries_lock_settled` |
| `20260902001700_invite_code.sql` | 邀請碼改 10 碼 CSPRNG、`create_ledger` 撞碼重試 | `gen_invite_code`、`create_ledger` |
| `20260902001800_privilege_lockdown.sql` | 收回全部表權再逐表逐動詞發；關掉 default privileges；entries 的 INSERT 也改欄位級；建帳本只走 RPC | `entries_force_open_on_insert` |
| `20260902001900_fk_indexes.sql` | 補齊所有 FK 子欄位的索引 | — |
| `20260902002000_entry_conservation_and_upsert.sql` | entries 側的分攤守恆（deferred）＋ `upsert_entry` RPC | —（兩支都已被 0021／0022 取代） |
| `20260902002100_upsert_semantics_and_default_privs.sql` | `upsert_entry` 子表改 `null`＝不動；守恆 trigger 重讀當前列；函式 default privileges 關掉 | `entries_split_sum_check` |
| `20260902002200_settled_children_and_column_grants.sql` | 已結帳不接受重寫子表；`ledgers`／`members` 欄位級 UPDATE；`rotate_invite_code` | `upsert_entry`、`rotate_invite_code` |
| `20260902002300_sequences_and_member_insert.sql` | sequences 的授權與 default privileges 一併關掉；`members` 收回 INSERT（加入帳本只走 RPC） | — |
| `20260903000100_budget_allocation_and_funding.sql` | 帳務規則 v1.3（ADR-0007）：`funding` enum ＋ `entries.funding`、`budget_allocation` 表（RLS／欄位級 UPDATE／realtime）、`upsert_entry` 帶 `funding`；**drop `budgets`、drop `categories.rollover`** | `budget_allocation_expense_category`（`upsert_entry` 已被 0027 取代） |
| `20260904000200_rules_v14.sql` | 帳務規則 v1.4（ADR-0008）整套，**刻意不拆成兩支**（中間任何切點都會留下「funding 已 drop 但 `month_summary` 還在讀它」之類的破窗，雲端逐支套用時真的會打到）：`archive` 快照、`members.monthly_topup`、`budget_allocation` 既有資料合併＋`month` generated 欄＋每分類每月唯一＋`amount > 0`＋收回 UPDATE／DELETE、**drop `entries.funding` 與 `funding` enum**、`upsert_entry` 去 funding、`month_closes` 表（只讀＋realtime）、`taipei_month`／`topup_for` 純函式、`entry_member_effects` view、清帳 RPC、鎖定 trigger、`month_summary` 依 v1.4 公式重寫 | `upsert_entry`、`taipei_month`、`topup_for`、`month_close_details`、`month_close_guard`、`month_close_preview`、`close_month`、`raise_if_month_closed`、`entries_month_closed`、`entry_children_month_closed`、`budget_allocation_month_closed`、`month_summary` |

## 寫入入口一覽（波 2 最重要的一張表）

| 想做的事 | 入口 |
| --- | --- |
| **記一筆帳／改帳（帶分攤或細項）** | `upsert_entry(p_entry, p_splits, p_line_items)` —— 同一交易寫完，守恆才過得了 |
| 記一筆帳、改帳、刪帳（不帶分攤） | 直接對 `entries` 寫（受 RLS ＋ 欄位級授權） |
| 細項、分攤、分類、清單 | 直接寫對應的表（受 RLS） |
| **設定本月預算** | 直接 `insert into budget_allocation`（一分類一月一列、`amount > 0`；`created_by` 必須是自己，比照 `entries`）。**設定後不可改不可刪**（沒有 UPDATE／DELETE 授權） |
| 改自己的暱稱／每月補入額 | 直接 update `members` 自己那列 |
| **預覽清帳明細** | `month_close_preview(p_ledger, p_month)` |
| **清帳** | `close_month(p_ledger, p_month)`（`month_closes` 沒有任何寫入 policy） |
| 讀畫面上的衍生數字 | `month_summary(p_ledger, p_until)` |
| 改帳本名稱／`default_ratio`／共同期初餘額 | 直接 update `ledgers` |
| **發起結算** | `initiate_settlement(ledger)` |
| **簽核結算** | `approve_settlement(id)`（`settlement_approvals` 也已收回前端寫入權） |
| **取消結算** | `cancel_settlement(id)` |
| **建帳本／加入帳本** | `create_ledger(name)`／`join_ledger(code)`（`ledgers` 沒有 INSERT 權限） |
| **換邀請碼** | `rotate_invite_code(ledger)`（成員都可呼叫；`invite_code` 欄位不可直接寫） |
| 搜尋 | `search_items(ledger, q)` |

`settlements`、`settlement_entries`、`settlement_signers`、`settlement_approvals` 對前端**只有 select**；
`entries.settled_state` 前端**完全不可寫**（連 insert 都不行）。
結算狀態機只有 RPC 與 trigger 推得動——這是多簽能不能被繞過的分界線。

### 前端角色（authenticated）的完整權限表

`anon` 對 `public` 的所有表**沒有任何權限**。`public` schema 的 default privileges 也已關掉
（Supabase 預設是 GRANT ALL，會讓每張新表自動帶 TRUNCATE／REFERENCES／TRIGGER；
**TRUNCATE 不受 RLS 約束**，拿到就能清空整張表）。波 2 新增表時要記得手動 grant。

**函式要特別小心**：Postgres 對函式的**內建**預設是 `EXECUTE TO PUBLIC`——這是寫死在 `acldefault()` 裡的行為，
`ALTER DEFAULT PRIVILEGES` 只能在「由該角色、在該 schema 新建」時覆蓋掉它，涵蓋不到別的角色建的函式。
所以規矩是：**每新增一支函式，都要顯式 `revoke execute on function … from anon, authenticated, public`**，
真正要給前端用的再 `grant execute … to authenticated`。
守門的是 `supabase/tests/rls.sql` 的白名單全掃描——它掃 `public` 底下**每一支**函式（`proacl` 為 null 時用
`acldefault()` 展開，所以「沒人動過」的函式也會被抓出來），只有白名單內的 RPC 允許授權給 `authenticated`。
新增 RPC 時記得同步更新那份白名單，否則測試會紅。

| 表 | select | insert | update | delete |
| --- | :---: | :---: | :---: | :---: |
| `ledgers` | ✓ | — | 欄位級 | — |
| `members` | ✓ | ✓ | 欄位級 | — |
| `categories`／`list_items`／`line_items`／`entry_splits` | ✓ | ✓ | ✓ | ✓ |
| `budget_allocation` | ✓ | 欄位級 | — | — |
| `entries` | ✓ | 欄位級 | 欄位級 | ✓ |
| `settlements`／`settlement_entries`／`settlement_approvals`／`settlement_signers` | ✓ | — | — | — |
| `month_closes` | ✓ | — | — | — |
| `entry_member_effects`（view） | ✓ | — | — | — |

`entries` 的欄位級授權：
- **INSERT**：`ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method, is_adjustment`
- **UPDATE**：同上但**去掉 `ledger_id` 與 `created_by`**
- 兩者都不含 `settled_state`／`id`／`created_at`。另有 before insert trigger 把 `settled_state` 強制為 `open`。

`budget_allocation` 的欄位級授權：
- **INSERT**：`ledger_id, category_id, amount, occurred_on, note, created_by`（**不含 `id`／`created_at`／`month`**——`month` 是 generated 欄，由 `occurred_on` 推導）。
- **UPDATE／DELETE**：v1.4 起**一欄都不開**。預算是「設定當月預算」的影子紀錄，設定後不可改、不可刪、不可退回（ADR-0008 決策 6）；寫了就是 `permission denied for table budget_allocation`。要改只能等下個月。

`ledgers` 的 UPDATE 只開 `name, default_ratio, opening_balance_shared`；
**`invite_code` 不可寫**——輪替走 `rotate_invite_code`，否則任何成員都能把邀請碼改成自己記得住的字串（等於自選密碼）。
`members` 的 UPDATE 只開 `display_name, monthly_topup, opening_balance_personal`（policy 另限「只能改自己那列」）。
`opening_balance_personal` v1.4 起**廢用、不再進任何公式**（`month_summary` 完全不讀它）。
欄位與授權保留是為了**跨版本並存**：v1.4 build 起前端改送 `monthly_topup`，但雲端隨時可能還有
沒更新的舊 build 在送 `opening_balance_personal`——欄位一旦拿掉，那些 build 會直接寫失敗。
等雲端確認沒有舊 build 在跑，才輪得到另開一支 migration 拔欄位。

## 表與欄位

所有表都有 `id uuid default gen_random_uuid()` 與 `created_at timestamptz default now()`，以下省略。

| 表 | 欄位 |
| --- | --- |
| `ledgers` | `name text`、`invite_code text unique`（**10 碼**大寫英數 base32，`gen_invite_code()` 以 `extensions.gen_random_bytes` 產生）、`default_ratio jsonb`（member_id → 百分比，合計 100）、`opening_balance_shared int` |
| `members` | `ledger_id`、`user_id → auth.users`、`display_name text`、**`monthly_topup int`**（每月補入額，`0 <= x <= 100000000`，預設 0）、`opening_balance_personal int`（**v1.4 廢用**，欄位保留不入公式）、`joined_at`；`unique(ledger_id, user_id)` |
| `categories` | `ledger_id`、`kind entry_kind`、`name text`、`icon text`（對應 `lib/app/category_icon.dart` 的名稱）、`sort int` |
| `entries` | `ledger_id`、`kind entry_kind`、`scope entry_scope`、`amount int`、`category_id`、`occurred_on date`、`note text`、`created_by → members`、`payer_id → members`（null＝共同錢包）、`split_method split_method`、`settled_state settled_state`、`is_adjustment bool` |
| `entry_splits` | `entry_id`、`member_id`、`share numeric(12,2)`；`unique(entry_id, member_id)` |
| `line_items` | `entry_id`、`name text`、`amount int null`、`sort int` |
| `settlements` | `ledger_id`、`status settlement_status`、`initiated_by → members`、`nets jsonb`（member_id → int）、`settled_at timestamptz null` |
| `settlement_entries` | `settlement_id`、`entry_id`；`unique(settlement_id, entry_id)` |
| `settlement_approvals` | `settlement_id`、`member_id`、`approved_at`；`unique(settlement_id, member_id)` |
| `settlement_signers` | `settlement_id`、`member_id`；發起當下定案的**需簽者快照**，之後只讀不改；`unique(settlement_id, member_id)` |
| `budget_allocation` | `ledger_id`、`category_id`（必須是同帳本的**支出**分類）、**`amount int`**（`> 0`）、`occurred_on date`、**`month date`**（`generated always as (date_trunc('month', occurred_on::timestamp))::date stored`）、`note text`、`created_by → members`（必須是呼叫者自己）；**`unique(ledger_id, category_id, month)`**；索引 `(ledger_id, occurred_on)`、`(category_id)`、`(created_by)`；複合 FK `(category_id, ledger_id)`／`(created_by, ledger_id)` 綁死同帳本 |
| `month_closes` | `ledger_id`、`month date`（月初）、`closed_by → members`、`closed_at timestamptz`、`details jsonb`；`unique(ledger_id, month)`（這道 unique 本身就是 `(ledger_id, month)` 的索引，**不另建**普通索引）；索引 `(closed_by)`；複合 FK `(closed_by, ledger_id)` 綁死同帳本。`details` ＝ `{"month": "YYYY-MM-01", "members": [{member_id, display_name, topup, net, ending}...（依 joined_at, id 排序）], "shared_delta": n}`，是清帳當下的**快照**（之後改補入額也不動它）；其中 **`net`／`ending`／`shared_delta` 都是 bigint**（`topup` 是 int，有上界）——`amount` 雖然是 int，一個月加起來輕鬆越過 int 上界，而清帳不可撤銷，最不該在這裡因為型別炸掉 |
| `entry_member_effects`（**view**，`security_invoker = true`） | `ledger_id`、`entry_id`、`member_id`、`occurred_on`、`delta bigint`——**一列＝一筆帳目對一位成員個人餘額的影響**，spec v1.4「該月淨變動」三段的唯一實作：私人筆給 `created_by` 本人 ±amount；未結算代墊給 payer −全額；已結算共同支出給每位成員 −自己的**整數份額**（最大餘數法，同小數以 `member_id` 決定先後——**tie-break 規則與 `initiate_settlement` 相同**，但取整的對象不同：這裡是逐筆份額，那裡是單次結算的淨額）；共同收入與共同錢包支出**不產生任何列**。`month_close_details`（definer，算全體）與 `month_summary`（invoker，只算自己）都只從這裡聚合。**前端沒有理由直接讀它**——畫面數字一律走 `month_summary`；它有 select 權只是因為 `month_summary` 是 invoker、讀它時是以呼叫者身分讀的 |
| `list_items` | `ledger_id`、`title text`、`store text null`、`estimated int null`、`category_id null`（null＝待辦）、`assignee_id null`、`due_on date null`、`done_at timestamptz null`、`entry_id null`、`sort int` |

enum：`entry_kind(expense|income)`、`entry_scope(private|shared)`、`split_method(equal|ratio|amount|common)`、`settled_state(open|settling|settled)`、`settlement_status(pending|settled|void)`。（`funding` enum v1.4 起已 drop。）

### 前端對照的兩個提醒

1. **餘額與預算的數字由 `month_summary` 算**（ADR-0008）：DB 只存帳目、預算影子紀錄（`budget_allocation`）與清帳紀錄（`month_closes`），沒有餘額欄位也沒有 view；畫面上的共同餘額／個人餘額／已花／剩餘／超支一律呼叫 `month_summary(p_ledger, p_until)` 取得，客戶端不自己算完直接顯示。
2. **`SettlementStatus.void_`**：DB 的值是字串 `'void'`，Dart enum 名是 `void_`，序列化兩邊都要手動對映。

### check constraint（前端要先擋，否則 insert 會被 DB 打回）

- `entries_amount_sign`：一般帳 `amount >= 0`；負數僅沖銷紀錄（`is_adjustment = true`，由前端沖銷流程自動產生）。
- `entries_private_payer`：`scope = 'private'` 時 **`payer_id` 必須等於 `created_by`**（收入的私人筆也一樣要帶 `payer_id`，不能留 null）。
- `entries_private_no_split`：private 筆 `split_method` 只能是 `common`（ADR-0003：私人不參與分攤）。
- `entries_private_open`：private 筆 `settled_state` 只能是 `open`。
- `budget_allocation_amount_positive`：`amount > 0`（v1.4 沒有「退回」，0 與負數都無意義）。
- `budget_allocation_one_per_category_month`：`unique (ledger_id, category_id, month)`——同分類同月第二筆會拿到 **23505**，前端要先擋並顯示「本月已設定」。
- `members_monthly_topup_range`：`0 <= monthly_topup <= 100000000`。上界是為了讓「補入額 × 月份數」不會失控（個人餘額全程以 bigint 計算並以 bigint 輸出）。
- `month_closes_month_is_first_day`：`month` 必須是月初；`month_closes_one_per_month`：`unique (ledger_id, month)`（同月只清一次）。
- `budget_allocation` 的分類：跨帳本由複合 FK 擋（`budget_allocation_category_same_ledger`）；收入分類由 trigger 擋（`budget allocation: category must be an expense category`）。

### v1.4 的資料遷移（`20260904000200`，雲端既有資料才用得到）

**先備份**：migration 開頭 `create schema if not exists archive` ＋
`create table archive.budget_allocation_v13 as select * from public.budget_allocation`——
底下的合併是破壞性的（多列併一列、合計 ≤ 0 整組刪掉），回不去，所以先原樣拷一份。
放 `archive` 而不是 `public` 有兩個理由：(1) `rls.sql` 的「public 每張表都要開 RLS 且有 policy」
全表掃描不該被這張快照打紅；(2) 新建 schema 預設不給 PUBLIC `USAGE`，前端角色連 schema 都進不去
（`permission denied for schema archive`），不必再逐表 revoke。
migration 仍對 `public`／`anon`／`authenticated` 各下一次 `revoke all on schema archive`——
不是補洞，是把意圖寫明，好讓 `budget.sql` 段 j1 的 `has_schema_privilege` 斷言有對照物。

`budget_allocation` 從 v1.3 的「撥款流水（一列＝一次撥款，`amount` 可負＝退回）」改成
v1.4 的「每分類每月一筆影子紀錄」，所以 migration 在加 `unique` 與 `amount > 0` **之前**先合併既有資料：

- 同 `(ledger_id, category_id, 月)` 的多列 → 合併成一列：`amount` ＝ 該組合計、`occurred_on` ＝ 該組最小值、
  `note` ＝ 該組任一非空備註（依 `created_at, id` 取第一個）、`created_by` ＝ 最早那列
  （做法是「保留最早那列、其餘刪掉」，所以 `created_by` 自然就是最早那筆的）。
- 合計 **≤ 0** 的組合（撥了又全退）→ **整組刪除**。
- 排序一律用 `(created_at, id)`：`created_at` 並列時由 `id` 決定先後，結果才穩定。
- 地端 `db reset` 時這張表是空的（`seed.sql` 在 migration 之後才跑），所以那句在地端是 no-op。
  **等價邏輯在 `supabase/tests/budget.sql` 的段 j2 用 temp table 鏡像驗過**（同分類同月合併、含負數但合計仍 > 0、
  合計 ≤ 0 整組刪、`created_at` 並列取序穩定四種形狀）——**改 migration 的合併 SQL 就要同步改那一段，反之亦然。**

`month` 欄採 **generated always stored**（`(date_trunc('month', occurred_on::timestamp))::date`）——
`date_trunc(text, timestamp)` 是 immutable（`timestamptz` 版才不是），所以 Postgres 收得下這個表達式，
不需要退回「before insert trigger 填欄位」的做法。

`entries.funding` 是直接 `drop column`：check `entries_funding_common_wallet_only` 與該欄的欄位級授權
隨欄位一起消失，`funding` enum 接著 `drop type`。舊版前端送這個鍵不會報錯（見 `upsert_entry`）。

## RLS 一句話版

- 一切以「你是不是這本帳本的成員」為界：`is_member(ledger_id)`。非成員（含 anon）看到空集合。
- `entries`：`select/update/delete` ＝ 成員 且（`scope = 'shared'` 或 `created_by = my_member_id(ledger_id)`）；`insert` ＝ 成員 且 `created_by = my_member_id(ledger_id)`。**不能以別人的名義記帳。**
  - **欄位級 update 授權**：`authenticated` 只被授權寫這些欄位 ——
    `kind, scope, amount, category_id, occurred_on, note, payer_id, split_method, is_adjustment`。
    `settled_state`、`created_by`、`ledger_id` **完全沒有授權**，前端寫了就是 `permission denied for table entries`。
  - `created_by` 與 `ledger_id` 另有不可變 trigger 當第二道（給 service_role 之類繞過欄位授權的路徑用）。
  - `settled_state` 只有 RPC 與 trigger 推得動：前端**不能**自己把帳目標成 settled。
  - **delete policy 另含 `settled_state <> 'settled'`**：已結帳的帳目對前端而言刪不掉（RLS 過濾＝影響 0 列，不會 raise），
    繞過 RLS 的路徑還有 before delete trigger 擋（`entry settled: delete blocked`）。金額有誤一律走沖銷（反向紀錄＋重記）。
  - 把別人的 shared entry 改成 `private` 會踩到 update 的 with check（改完自己就不該還看得到），一樣被擋。
- `entry_splits`／`line_items`：select 與 insert／update／delete 都跟隨父 `entry`，條件與 `entries` 的 select／update policy 逐字相同（`exists` 子查詢明寫，不只倚賴 `entries` 自身 RLS）。
- `categories`／`list_items`：成員全權（增刪改查）。
- `budget_allocation`：成員可讀可新增，**不可改不可刪**（v1.4 起 `budget_allocation_update`／`budget_allocation_delete` policy 已刪、表權也收回）；insert policy 的 with check 是 `is_member(ledger_id) and created_by = my_member_id(ledger_id)`——**不能以別人的名義設定預算**（形狀與 `entries` 相同，塞別人的 member id 會拿到 42501）。
- `month_closes`：**成員只讀**（只有一條 select policy ＝ `is_member(ledger_id)`）。沒有 insert／update／delete policy，也沒有表權——清帳只能經 `close_month`（security definer），而且不可撤銷。
- `settlements`／`settlement_entries`／`settlement_signers`：**成員只讀**。前端沒有 insert／update／delete 權限，
  結算的一切寫入只能經由 RPC（`initiate_settlement`／`approve_settlement`／`cancel_settlement`）。
  （早期版本是「成員全權」，那讓任何成員都能直接寫一筆 `status='settled'` 的結算，完全繞過多簽。）
- `members`：直接 insert 只能插自己且限已在的帳本 —— **加入新帳本一律走 `join_ledger` RPC**。
- `settlement_approvals`：同帳本**只讀**。insert 已收回，只能走 `approve_settlement`（RPC 內驗需簽者與 pending 狀態）。
- `members`：同帳本成員可讀；只能 update 自己那列，且 `ledger_id`／`user_id` 不可變（trigger）。
- `ledgers`：成員可讀可改；任何登入者可 insert（正式路徑是 `create_ledger`）。

## 輔助函式

| 函式 | 說明 |
| --- | --- |
| `public.is_member(p_ledger uuid) returns boolean` | security definer；呼叫者是否為該帳本成員 |
| `public.my_member_id(p_ledger uuid) returns uuid` | security definer；呼叫者在該帳本的 member id，非成員回 null |
| `public.required_signers(p_settlement uuid) returns setof uuid` | 需簽者＝`nets` 非零成員 − 發起人（ADR-0002） |
| `public.month_close_details(p_ledger uuid, p_month date) returns jsonb` | **內部**（security definer，不 grant 前端）；算清帳明細，要跨成員讀私人筆才算得出每個人的淨變動 |
| `public.month_close_guard(p_ledger uuid, p_month date) returns void` | **內部**；可清條件的唯一一份實作，`month_close_preview` 與 `close_month` 共用 |
| `public.raise_if_month_closed(p_ledger uuid, p_month date) returns void` | **內部**；四支鎖月 trigger 共用的檢查 |
| `public.taipei_month(p_ts timestamptz) returns date` | **純函式**（不讀任何表）；timestamptz → 台北當地月初。「加入月」的唯一定義 |
| `public.topup_for(p_monthly_topup int, p_joined_at timestamptz, p_month date) returns int` | **純函式**；某位成員在某個月有沒有補入額的唯一判準（加入月起才有）。`month_close_details` 與 `month_summary` 共用 |

`taipei_month`／`topup_for` 有 grant 給 `authenticated`（因此也在 `rls.sql` 白名單裡）：
`month_summary` 是 `security invoker`，它呼叫的函式權限是以**原呼叫者**身分檢查的，不 grant 就一路
`permission denied for function`。這兩支不碰任何表、只做日期與大小比較，給前端執行洩不出資料。

## RPC 簽名

多數是 `security definer`、`set search_path = public`、開頭檢查 `auth.uid()`。
**走 `security invoker` 的有三支**，都是刻意的：`search_items`（要吃 RLS，別人的私人筆搜不到）、
`upsert_entry`（RLS 與欄位級授權照常生效，這支只提供原子性）、
`month_summary`（`me` 只算呼叫者自己；非成員被 RLS 濾成空，不必再寫一套成員檢查）。

### `create_ledger(name text) returns public.ledgers`
建帳本 → 把呼叫者插成 member（`display_name` 取 `auth.users.raw_user_meta_data->>'full_name'`，否則 email 的 `@` 前綴）→ `default_ratio` 設成 `{該 member: 100}` → 灌 9 個預設分類（食品／餐飲／日常用品／住房／水電／交通／娛樂；薪水／獎金）。

```dart
final ledger = await supabase.rpc('create_ledger', params: {'name': '我們的家'});
// ledger 是單一 ledgers 列的 Map<String, dynamic>
```

### `join_ledger(code text) returns public.ledgers`
以邀請碼加入（大小寫與前後空白會正規化）。已是成員 → 直接回該帳本，不重複插。新成員加入後 `default_ratio` 重算為均分。錯碼 raise `join_ledger: invalid invite code`。

```dart
final ledger = await supabase.rpc('join_ledger', params: {'code': inviteCode});
```

### `initiate_settlement(ledger uuid) returns public.settlements`
涵蓋條件：`scope = 'shared'`、`kind = 'expense'`、`settled_state = 'open'`、`payer_id is not null`、`split_method <> 'common'`，**且該 entry 真的有 `entry_splits` 列**。
（少了最後一條，一筆「有 payer、split=equal 卻沒建分攤列」的帳目會整筆算進付出卻沒人分攤，Σnets 直接不守恆。）

守恆檢查，任一條不過就 raise、不建結算：
- 逐筆：`|Σshare − amount| < 0.01`，否則 `entry <id>: splits do not sum to amount`。
- 整體：`|Σnets| ≤ 成員數`（四捨五入每人最多差 1 元），否則 `nets do not balance (sum = <n>)`。

`nets[member] = Σ該員付出 − Σ該員分攤`，取整用**最大餘數法**：全員先 `floor`，差額依小數部分由大到小各補 1，同小數以 `member_id` 決定先後。
這樣 **Σnets 恆為 0**（先前用 `round()`，三人 9.5／9.5／−19 這種會算出 Σ = −1，錢憑空少一塊）。餘數歸屬規則見 ADR-0005。
同一帳本同時只允許一個 `pending` 結算：RPC 開頭取 `pg_advisory_xact_lock(ledger)`，資料層另有 partial unique index `settlements(ledger_id) where status = 'pending'`。
建 `pending` settlement ＋ `settlement_entries` ＋ **`settlement_signers` 快照**，涵蓋 entries → `settling`。
發起人自動視為已簽（不寫 `settlement_approvals`，也不在 `settlement_signers` 裡）。

raise 的情況：非成員（`not a member`）、已有 pending（`a pending settlement already exists`）、沒有可結算的 entry（`no settleable entries`）、淨額全為零（`nothing to settle`）、上述兩條守恆檢查。

```dart
final settlement = await supabase.rpc('initiate_settlement', params: {'ledger': ledgerId});
```

### `approve_settlement(id uuid) returns public.settlements`
插一筆自己的 approval；到齊由 trigger 在同一交易落 `settled`。回傳的是**簽完之後**的 settlement（可能已經是 `settled`）。
raise 的情況：找不到（`settlement not found`）、非成員、不是 pending（`settlement is not pending`）、不是需簽者（`not a required signer`，發起人自己簽會踩到這條）。

```dart
final settlement = await supabase.rpc('approve_settlement', params: {'id': settlementId});
if (settlement['status'] == 'settled') { /* 收掉待簽卡片 */ }
```

### `required_signers(p_settlement uuid) returns setof uuid`
讀 `settlement_signers` 快照（**不是**從 `nets` 現算——`nets` 可寫時，發起人只要把對方淨額改成 0 就能讓名單變空、自己一簽就結案）。非該帳本成員呼叫 raise `not a member`；查無此結算 raise `settlement not found`。
```dart
final signers = await supabase.rpc('required_signers', params: {'p_settlement': settlementId});
// List<dynamic>，元素是 member id 字串
```

### `cancel_settlement(id uuid) returns public.settlements`
取消一個 `pending` 結算：status → `void`，涵蓋 entries 回 `open`。
**發起人或任一需簽者**都可以取消（`settlements` 收成唯讀之後，這是唯一的取消入口）。
raise 的情況：查無此結算、非成員、不是 pending（`settlement is not pending`）、既非發起人也非需簽者（`only the initiator or a required signer may cancel`）。
```dart
final settlement = await supabase.rpc('cancel_settlement', params: {'id': settlementId});
```

### `upsert_entry(p_entry jsonb, p_splits jsonb default null, p_line_items jsonb default null) returns public.entries`
**帶分攤或細項的帳目，寫入請走這支。** 同一交易寫完主筆＋整組分攤＋整組細項（子表全刪重建），
所以守恆檢查一定過得了。`security invoker`：RLS 與欄位級授權照常生效，這支只提供原子性。

- `p_entry` 有 `id` → 更新該筆（找不到或看不到 raise `entry not found or not visible`）；沒有 `id` → 新增。
- `created_by` 一律強制為呼叫者自己的 member id，`settled_state` 不受這支影響。
- **v1.4 起沒有 `funding`**（ADR-0008）：`entries.funding` 與 enum 都 drop 了。`p_entry` 裡多送 `'funding'` 不會報錯也不會有任何效果（jsonb 多餘鍵直接被忽略）。
- **鎖定範圍**：`occurred_on` 所在月 **≤ 最後清帳月** → trigger raise `month closed: YYYY-MM`（新增、修改、把日期搬進去、動子表都擋）。
- **已結帳的帳目**：只能改分類與備註（子表兩個參數都留 `null`）。帶了 `p_splits` 或 `p_line_items` 會直接
  raise `entry settled: child tables locked`——不是擋你改細項內容，而是這支的子表寫法是「全刪重建」，
  在 settled 狀態下會被 policy 擋成半套（分攤保住、細項被刪光且沒有錯誤訊息）。
- 子表重建時會比對刪除筆數：若 RLS 靜默過濾掉某些列，直接 raise 而不是留下半套資料。
- **要改已結帳帳目的細項，請直接寫 `line_items` 表**（新增／修改／刪除都可以，ADR-0002 明文允許改細項）。
  被擋的只是 `upsert_entry` 的「整組刪掉重建」寫法，不是細項本身。
- **`p_splits`／`p_line_items` 的三種語意**：
  - `null`（或整個省略）＝**完全不動那張子表**。只想改備註就這樣呼叫。
  - `[]` ＝**清空**那張子表。
  - 有內容 ＝ 全刪重建。
  兩個參數各自獨立：可以只重寫細項而完全不碰分攤。

```dart
final entry = await supabase.rpc('upsert_entry', params: {
  'p_entry': {
    'ledger_id': ledgerId, 'kind': 'expense', 'scope': 'shared',
    'amount': 1000, 'category_id': categoryId,
    'occurred_on': '2026-09-02', 'note': '全聯買菜',
    'payer_id': myMemberId, 'split_method': 'equal',
  },
  'p_splits': [
    {'member_id': myMemberId, 'share': 500},
    {'member_id': wifeMemberId, 'share': 500},
  ],
  'p_line_items': [
    {'name': '雞蛋', 'amount': 89, 'sort': 0},
  ],
});
```

### `rotate_invite_code(ledger uuid) returns public.ledgers`
換一張新的 10 碼邀請碼（舊碼立刻失效）。任一成員都可呼叫；非成員 raise `not a member`。
撞 unique 會自動重抽，最多五次。
```dart
final ledger = await supabase.rpc('rotate_invite_code', params: {'ledger': ledgerId});
```

### `search_items(ledger uuid, q text) returns table(...)`
回傳欄位：`kind text`（`line_item`｜`entry`｜`list_item`）、`id uuid`、`entry_id uuid`、`name text`、`amount int`、`occurred_on date`、`category_id uuid`、`note text`。
比對 `line_items.name`／`entries.note`／`list_items.title`（ILIKE，索引走 `gin_trgm_ops`）。`q` 空字串回空集合。走 `security invoker` → 別人的私人筆搜不到。

```dart
final rows = await supabase.rpc('search_items', params: {'ledger': ledgerId, 'q': keyword});
```

### `month_summary(p_ledger uuid, p_until date) returns jsonb`（v1.4）
畫面上的衍生數字統一從這支拿（`security invoker`，所以只回呼叫者看得到的東西）。
**`p_until` 不夾上界**：前端的月份切換沒有上界（下個月的預算本來就可以先設），所以問下個月要拿得到下個月的 `allocated`／`spent`／`categories`／`month_net`；`shared_balance` 與個人餘額的淨變動一律累計到 `p_until`。
**只有補入額的月份列舉夾在台北本月**（`N` 的上界 ＝ `least(p_until 所在月, 台北本月)`）——補入額是「每個月實際補進來的錢」，還沒到的月份不該先算給你，否則 `p_until` 給 `'9999-12-31'` 會算出九萬個月的補入額。輸出：

```jsonc
{
  "shared_balance": 7500,       // bigint。共同期初 ＋ Σ共同收入 − Σ共同錢包支出（payer_id is null），occurred_on <= until
  "budget_total": 6000,         // bigint。until 所在月的 Σ預算
  "spent_total": 5500,          // bigint。until 所在月的 Σ共同支出（**不分 payer**，代墊也算）
  "overspend_total": 1500,      // bigint。Σ max(0, spent − allocated)
  "categories": [               // 有預算或有共同支出的分類，依 category_id 排序
    // allocated 是 int（單筆預算，受 amount 欄位型別與 amount > 0 的 check 限制）；
    // spent／remaining／over 是 bigint（加總，一個月就越得過 int 上界）
    {"category_id": "…", "allocated": 5000, "spent": 3000, "remaining": 2000, "over": 0}
  ],
  "me": {                       // 只有呼叫者自己；非成員為 null
    "member_id": "…",
    "personal_balance": 8700,   // **bigint**（不轉 int）：算得出來就回得出來，Dart 的 int 是 64-bit
    "monthly_topup": 10000,     // int（有 0～一億的 check）
    "month_net": -1300          // bigint，同上
  }
}
```

- `allocated` 取的是該分類 `month = until 所在月` 的那一筆（0 或 1 筆），**刻意不加 `occurred_on <= until` 這道篩選**：
  預算是「當月的影子紀錄」，設定當下就對整個月生效，不該因為 `until` 落在設定日之前而消失
  （`spent` 則相反，是逐筆累加的實際花費，所以有 `occurred_on <= until`）。
- `N` ＝ [加入月, `least(until 所在月, 台北本月)`] 之間**晚於最後清帳月**的月份數（加入月 ＝ `taipei_month(joined_at)`；加入月晚於 until 所在月 → 0）。
- **「已清帳」全庫只有一個定義：月份 ≤ `max(month_closes.month)`**。鎖月 trigger 用 `<= max`、個人餘額用 `> max`，是同一把尺的兩面。不用「有沒有那一列」判，是因為清帳只能按序推進、正常情況兩者等價，但**雲端人工救援刪掉中間某一列**之後兩者會分岔：被刪那個月會偷偷回到個人餘額裡，而且因為鎖月照樣擋著、改不動，餘額永遠對不平。
  → **人工救援（在雲端 SQL 刪 `month_closes` 列）只能從最後一列往前刪**，不可以挖中間。
  （唯一的例外是 `close_month` 可清條件裡那條 `already closed`：它刻意用「**該月有沒有紀錄**」判，
  職責只是給人看得懂的訊息，不決定鎖不鎖／算不算餘額——真正的判準一律走 `max`。）
- `p_until` 傳 `null` 等同「問到本月底」（`coalesce` 的預設值，不是上界）。
- **問未來月份時的 `personal_balance` 是「不含未來補入額」的保守投影**：預算與已花照那個月算，但補入額只累計到台北本月（那些錢還沒補進來）。所以「下個月的個人餘額」讀起來會偏低——它回答的是「照現在的帳，下個月初我手上有多少」，不是「下個月補完之後」。
- **問已清月份時的 `personal_balance` 恆為 0**：已清月一律 ≤ 最後清帳月，補入額與淨變動兩邊都被排除。要看歷史請讀 `month_closes.details` 的快照，不要拿 `month_summary` 去問過去的月份。
- 份額取整是**逐筆**做的（每筆各自最大餘數法），與 `initiate_settlement` 對**單次結算淨額**做的那次取整是兩件事：同一批帳目，「逐筆份額加總」與「一次算出來的淨額」可能差 **< 1 元／筆**。這是刻意的——個人餘額要能逐筆歸月（ADR-0008 決策 2），沒辦法沿用結算當下那一次的淨額。
- **淨變動**（依帳目 `occurred_on` 歸月）＝ Σ本人私人收入 − Σ本人私人支出 − Σ本人**未結算**代墊的**全額** − Σ**已結算**共同支出中本人的份額。份額取整走 `entry_member_effects`（**最大餘數法**：每筆先全員 `floor`，差額依小數由大到小各補 1，同小數以 `member_id` 決定先後——tie-break 規則與 `initiate_settlement` 相同），所以同一筆的各成員整數份額合計恰等於主筆金額——逐筆 `round()` 會漏／溢一元（567 均分兩人 → 284＋284 ＝ 568）。共同收入與共同錢包支出不進個人。
- v1.3 的 `shared_available` 與 `envelope_total` 兩個鍵**已移除**（共同可用餘額不再預扣信封）。

### `month_close_preview(p_ledger uuid, p_month date) returns jsonb`（v1.4）
清帳預覽。可清條件不過就 raise，過了回 `close_month` 會寫進 `details` 的那份明細，**外加一個 `warnings` 陣列**。
非成員 raise `month_close_preview: not a member`（42501）。

```jsonc
{ "month": "...", "members": [...], "shared_delta": 1000,
  "warnings": [{"code": "unsplit_advances", "count": 3}] }   // 沒事時是 []，不是缺鍵
```

`warnings` 是**結構化**的（`code` ＋ 數量），DB 不回中文句子——文案要配合畫面、要能改字，那是前端的事。

| `code` | 意思 | 前端建議文案 |
| --- | --- | --- |
| `unsplit_advances` | 該月有 `count` 筆「`payer_id` 非 null、`split_method <> 'common'`、**但沒有任何分攤列**」的帳目 | 「{count} 筆代墊尚未拆帳，將由付款人全額承擔」 |

可清條件第 6 條刻意放行這種筆（它結算撿不到，擋了那個月永遠清不掉），但它會由付款人**全額**承擔，
金額可能很難看，而清帳不可撤銷——所以預覽要先講一聲，前端的確認 sheet 應該把它顯示出來。

**`close_month` 落地的 `details` 不含 `warnings`**：那是事實快照，只放當下算出來的數字；
提醒會隨資料變（補了分攤就沒事了），快照不該跟著變。比對兩者時記得 `preview - 'warnings'`。

### `close_month(p_ledger uuid, p_month date) returns public.month_closes`（v1.4）
清帳。同帳本 `pg_advisory_xact_lock` 序列化 → 同一段可清條件檢查 → 寫入 `month_closes`（`closed_by` ＝ 呼叫者、`details` ＝ 當下明細）。任一成員可執行、不需多簽、**不可撤銷**。

**可清條件與訊息（兩支共用，檢查順序就是下表由上而下）**：

| # | 條件 | 不過時的訊息 |
| --- | --- | --- |
| 1 | `p_month` 必須是月初 | `close_month: month must be first day` |
| 2 | 依台北時間早於當月 | `close_month: month not ended` |
| 3 | 該月還沒清過 | `close_month: already closed` |
| 4 | 有可清的月份（下一個可清月早於當月） | `close_month: nothing to close` |
| 5 | 必須是**下一個可清月**（有 closes → `max(month) + 1 月`；沒有 → `least(最早成員加入月, 最早帳目月)`） | `close_month: must close YYYY-MM first` |
| 6 | 該月的拆帳（`scope='shared'`、`kind='expense'`、`payer_id` 非 null、`split_method <> 'common'`、**且有分攤列**）全部 `settled` | `close_month: unsettled entries in month` |

判準第 6 條的 `exists (select 1 from entry_splits …)` 與 `initiate_settlement` **逐字相同**：
沒有分攤列的拆帳筆結算根本撿不到（它也要求 `exists splits`），永遠 `settle` 不了；
清帳若拿 `settled_state` 一刀切就會被這種筆卡死，那個月永遠清不掉。

「已清過」刻意排在「順序」之前：清過的月份一定不等於下一個可清月，排在後面的話重清同月會拿到
`must close … first` 而不是看得懂的 `already closed`。

所有 RPC 的參數名以本檔標頭為準（PostgREST 走**具名**參數，名字打錯會是 `function … does not exist`，不是少一個參數）。

```dart
final preview = await supabase.rpc('month_close_preview',
    params: {'p_ledger': ledgerId, 'p_month': '2026-07-01'});
final row = await supabase.rpc('close_month',
    params: {'p_ledger': ledgerId, 'p_month': '2026-07-01'});
```

## Trigger（前端要預期的錯誤）

| Trigger | 行為 |
| --- | --- |
| `entries_lock_settled_trg` | `settled` 的 entry 改 `amount`／`payer_id`／`split_method`／`scope`／`kind` → raise，訊息依欄位分列：`entry settled: amount locked, use an adjustment entry`／`payer locked`／`split_method locked`／`scope locked`／`kind locked`／`occurred_on locked`（日期會搬動月份歸屬，讓統計與歷史結算對不上，所以也鎖）（一律以 `entry settled: ` 開頭）。分類、備註、細項照樣可改（ADR-0002） |
| `entry_splits_lock_settled_trg` | `settled` 的 entry 新增／修改分攤 → raise `entry settled: split locked` |
| `entries_immutable_identity_trg` | 改 `created_by` → raise `entry: created_by is immutable`；改 `ledger_id` → raise `entry: ledger_id is immutable` |
| `entries_void_pending_settlement_del_trg` | **before delete**（早於 FK cascade，否則 `settlement_entries` 已被清掉、找不到 pending settlement）：settled → raise `entry settled: delete blocked, use an adjustment entry`；settling → 對應 settlement `void`、其餘涵蓋 entries 回 `open` |
| `entry_splits_lock_settled_del_trg` | 直接刪 settled entry 的分攤 → raise `entry settled: split locked`（父 entry 被刪時的 cascade 放行） |
| `settlements_status_machine_trg` | `ledger_id`／`initiated_by`／`nets` 不可變；status 只允許 `pending → settled` 或 `pending → void`，終態 raise `settlement: status <x> is final` |
| `settlement_approvals_guard_trg` | 簽名者必須在 `settlement_signers` 快照名單內、且 settlement 仍 `pending`，否則 raise |
| `entry_splits_sum_check_trg` ＋ `entries_split_sum_check_trg` | **deferred constraint（兩側）**：Σshare 必須等於主筆金額（見上節） |
| `entries_force_open_on_insert_trg` | 新增的帳目一律 `settled_state = 'open'` |
| `a_entries_month_closed_trg` | **before insert/update/delete**：`occurred_on` 所在月 **≤ 最後清帳月** → raise `month closed: YYYY-MM`（訊息帶的是**被擋的那筆所屬的月**，不是最後清帳月）。update 會同時檢查新值與舊值那個月（所以「把日期搬進鎖定範圍」與「動鎖定範圍裡的帳目」都擋）|
| `a_entry_splits_month_closed_trg`／`a_line_items_month_closed_trg` | 同上，看的是父 entry 的 `occurred_on`。父筆被 cascade 刪掉時查不到父列 → 放行 |
| `a_budget_allocation_month_closed_trg` | **before insert/update/delete**：`occurred_on` 所在月 ≤ 最後清帳月 → raise。前端本來就沒有 UPDATE／DELETE 授權，掛三個動詞是為了擋 `service_role` 那條繞過欄位授權的路徑。不能用 `NEW.month`／`OLD.month`：generated 欄是 BEFORE trigger **之後**才算的 |
| `entry_splits_same_ledger_trg`／`list_items_same_ledger_trg`／`settlement_entries_same_ledger_trg` | 跨帳本引用 raise `... belongs to another ledger` |
| `members_immutable_identity_trg` | 改 `ledger_id`／`user_id` → raise `member: ... is immutable` |
| `entries_void_pending_settlement_trg` ＋ `..._del_trg` | `settling` 的 entry 其 `amount`／`payer_id`／`split_method`／`scope`／`kind`／`occurred_on` **值真的變了**，或整筆被刪 → 對應 pending settlement 標 `void`、涵蓋 entries 回 `open`。改備註／分類／細項**不會** void |
| `entry_splits_void_pending_settlement_trg` ＋ `..._ins_del_trg` | 同上，比的是 `share`／`member_id` 的值；分攤的新增與刪除一律 void（分攤集合本身變了） |
| `settlement_finalize_on_approval_trg` | 簽名到齊 → settlement `settled` ＋ `settled_at = now()`、涵蓋 entries `settled` |

前端存檔一律 try/catch：踩到鎖定要顯示「已結帳：金額與分攤鎖定，可整筆沖銷後重新記一筆」；踩到 `month closed` 要顯示「該月已清帳」；踩到 void 要重新拉 settlement 狀態。

### 清帳相關的錯誤訊息一覽（前端要逐條對應文案）

| 來源 | 訊息 | 前端該顯示什麼 |
| --- | --- | --- |
| 鎖月 trigger（四支） | `month closed: YYYY-MM` | 「該月已清帳」——表單日期、列表左滑、明細選單都要先擋 |
| `close_month`／`month_close_preview` | `close_month: month must be first day` | 內部錯誤（前端一律只送月初，送到代表 bug） |
| 同上 | `close_month: month not ended` | 「本月尚未結束」 |
| 同上 | `close_month: already closed` | 「該月已清帳」 |
| 同上 | `close_month: nothing to close` | 「沒有可清的月份」（清帳按鈕 disabled 的原因之一）|
| 同上 | `close_month: must close YYYY-MM first` | 「請先清 YYYY／MM」 |
| 同上 | `close_month: unsettled entries in month` | 「有拆帳尚未簽完」 |
| 同上 | `close_month: not a member`（42501）／`month_close_preview: not a member` | 不該發生（已切帳本才會看到清帳頁）|

**鎖定範圍是「最後清帳月（含）以前」，不是「有清帳紀錄的那幾個月」**（spec 7e4465f）：
清帳只能按序往後推進，所以補記到最早清帳月**之前**的月份永遠不會再是「下一個可清月」，
那筆的影響就會永久留在個人餘額裡清不掉。判準因此是
`occurred_on 月 <= (select max(month) from month_closes where ledger_id = …)`。

**鎖月 trigger 一律用 `a_` 開頭**：trigger 依名稱字母序執行，`entries` 的 before delete 另有
`entries_void_pending_settlement_del_trg`（0010）會把 pending 結算標 void——鎖月檢查必須排在它之前
（`month_close.sql` 的 16b 段用 `pg_trigger` 直接驗這條順序）。

void trigger 是 `after update of <欄位> ... when (old.x is distinct from new.x or ...)`：欄位限定先篩掉無關的更新，`when` 再比新舊值。所以
- **值不變就不 void**：`amount`／`payer_id`／`split_method`／`scope`／`kind` 的值沒變，`settling` 期間改備註、分類、細項不會打斷結算。
- 系統自己的搬狀態路徑（void 把 entries 打回 `open`、多簽落地改成 `settled`）只寫 `settled_state`，不在監看欄位裡，不會回頭觸發自己——不需要任何 session 旗標守衛。

### 分攤守恆：兩側都有 deferred constraint

`entries` 與 `entry_splits` **兩張表都有** deferred constraint trigger：只要該 entry 還有任何分攤列，
Σshare 必須等於主筆金額（容差 0.01）；`split_method = 'common'` 或 `scope = 'private'` 不檢查。
`deferrable initially deferred` 是為了讓「同一交易先建 entry 再建 splits」能過。

PostgREST 每個 request 各自一個交易，所以：
- **改金額或改分攤，一定要在同一個 request 裡做完** → 用 `upsert_entry`。
  只改金額不動分攤，會在**該 request 結束時**就被擋（`entry <id>: splits (...) do not sum to amount (...)`），
  不會拖到發起結算才爆。
- 直寫表仍然允許，但你得自己在同一交易滿足守恆（一次 `insert` 多列分攤，別一列一個 request）。
- 把分攤全部刪光是允許的（改走共同錢包／common 的正常路徑）。

### 更新 entries 的唯一注意事項：先剔除三個欄位

`settled_state`／`created_by`／`ledger_id` 沒有欄位級 update 授權。整列送回時**即使值一模一樣**也會被權限層擋下（`permission denied for table entries`，比 trigger 更早發生）。所以：

```dart
// 對：只送要改的欄位，或送整列但剔除這三欄
await supabase.from('entries').update({
  'amount': e.amount, 'note': e.note, 'category_id': e.categoryId,
  'occurred_on': ..., 'payer_id': ..., 'split_method': ..., 'scope': ..., 'kind': ...,
  'is_adjustment': ...,
}).eq('id', e.id);

// 錯：toJson() 整個丟回去（含 settled_state / created_by / ledger_id）→ permission denied
```
建議在 model 上另備一個 `toUpdateJson()`，固定只吐可寫的**九個**欄位
（`kind, scope, amount, category_id, occurred_on, note, payer_id, split_method, is_adjustment`）。
（v1.4 起沒有 `funding`：欄位與 enum 都 drop 了，舊前端送這個鍵給 `upsert_entry` 不會報錯，只是完全沒有效果。）

## Realtime

`supabase_realtime` publication 收錄：`entries`、`settlements`、`list_items`、`budget_allocation`、`month_closes`（publication 上仍吃 RLS，私人筆不會外流）。五張表都是 `replica identity full`，DELETE payload 才帶得出 `ledger_id` 供前端過濾。

```dart
supabase.channel('ledger:$ledgerId')
  .onPostgresChanges(
    event: PostgresChangeEvent.all, schema: 'public', table: 'settlements',
    filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'ledger_id', value: ledgerId),
    callback: (_) => ref.invalidate(settlementsProvider))
  .onPostgresChanges(
    event: PostgresChangeEvent.all, schema: 'public', table: 'entries',
    filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'ledger_id', value: ledgerId),
    callback: (_) => ref.invalidate(entriesProvider))
  .subscribe();
```

## Apple 登入後的首登流程

```
Sign in with Apple → supabase.auth.signInWithIdToken(provider: apple, ...)
  → select * from members where user_id = auth.uid()
      ├─ 有 → 取第一本（或使用者上次選的）帳本 id，照常載入
      └─ 沒有 → 兩條路，由 UI 讓使用者選：
            ├─ create_ledger('我們的家')  → 得到新帳本＋自己成為成員＋預設分類
            └─ join_ledger('<邀請碼>')    → 加入對方的帳本
```

`members` 查得到多列＝多帳本，設定頁的帳本切換就是換 `ledger_id`。
Apple 不一定給 email／姓名，`create_ledger` 抓不到就用 `'我'`，之後在設定頁改 `members.display_name`（RLS 允許改自己那列）。

## 已知風險（自用取捨，明確記一筆）

| 風險 | 現況 | 為什麼接受 |
| --- | --- | --- |
| 邀請碼可被暴力猜 | 10 碼 base32（≈1.1e15 組），`join_ledger` **沒有失敗次數限流** | 自用、帳本數量極少；真要防要在 Edge Function 或 gotrue 前面做限流。若日後開放給更多人用，這是第一個要補的洞 |
| `ledgers` 的 update 過寬 | 任一成員可改帳本名稱、`default_ratio`、`opening_balance_shared` | 夫妻互信情境；要收緊得引入「帳本管理員」概念，目前不做 |
| 波 2 新增資料表／函式時忘了 grant | 對前端完全不可用（`public` 的 default privileges 已對 tables 與 functions 都關掉） | 這是刻意的：寧可少給，也不要像 Supabase 預設那樣自動帶 TRUNCATE／EXECUTE |
| 函式的 `EXECUTE TO PUBLIC` 是 Postgres 內建預設 | 靠「每支顯式 revoke」＋`rls.sql` 全掃描守，不是靠機制擋 | 想從機制面關掉，得把 RPC 搬到自建的 `api` schema（`public` 不對外曝光、`api` 只放要給前端的函式）。這是波 2 可選的架構調整，不在波 1 範圍 |
| 0017 的 backfill 會換掉舊邀請碼 | 套用 0017 時，任何不符 10 碼格式的既有 `invite_code` 會被重新產生 —— **已經發出去的舊邀請碼當場失效** | 目前雲端還沒有真實資料，影響為零；日後若對已有帳本的環境套這支 migration，要先通知成員重拿邀請碼 |
| `supabase_admin` 那份 default privileges 改不動 | 地端實測：`postgres` 發的那份已清乾淨，`supabase_admin` 發的那份仍帶 anon/authenticated | 它只影響「由 supabase_admin 建立的表」，我們的 migration 都以 `postgres` 身分建表，所以實際上碰不到；雲端 push 後請再跑一次 `rls.sql` 的前置掃描當 smoke test |

## 地端驗證

```bash
~/.local/bin/supabase start          # 只用來驗證；正式開發連雲端（ADR-0005）
supabase/tests/run.sh                # db reset + 逐檔 psql，任一 assert 失敗即非零退出
supabase/tests/run.sh --no-reset     # 只在「剛 reset 過」的 DB 上有效，見下
~/.local/bin/supabase stop
```

`run.sh` 會在 reset 前後等資料庫真的收連線，reset 後再驗兩件事：schema 真的落地、**種子是乾淨的原始狀態**
（帳目 10 筆、沒有殘留結算、每筆分攤加總與主筆金額相符）。不符就自動重試一次 reset，再不行直接以 exit 1 停住、不跑測試。這是因為地端棧有兩個實際踩過的坑：
`db reset` 回來時 Postgres 還沒開始收連線；以及連續 reset 之間棧沒穩定時，CLI 會回
`LegacyDbSetupError`，或回報「migration 都套用了」但連過去卻是空 schema，
測試就變成一連串看不懂的 `type "public.settlements" does not exist`。

**`--no-reset` 只在剛 reset 過的資料庫上有效。** 測試本身都包在 `begin/rollback` 裡，
但只要有人手動改過資料、或另一個 worktree 動過同一個地端棧，計數型斷言（「應看到 10 筆」）就會失敗。
不確定就不要帶這個旗標；`run.sh` 不帶參數＝先 reset 再跑，那條路徑保證從乾淨狀態起跑。
帶了未知參數會直接以 exit 2 報錯，不會靜默去 reset。

**地端棧同時只能從一個 worktree 操作。** `config.toml` 進 git，所以每個 worktree 的
`project_id` 都一樣（`accounting-wt-db`），共用同一組 docker 容器；但 CLI 狀態放在
gitignore 的 `supabase/.temp/`，各 worktree 各一份。從「沒起過棧的那個 worktree」下
`supabase db reset`，CLI 會看到容器在跑卻對不上自己的狀態，報 `LegacyLocalDbRunningError`。
**已經 `supabase link` 過的 worktree 尤其危險**：在那裡下 `db reset` 有打到雲端專案的風險。
要跑測試就到起棧的那個 worktree 跑。

種子資料 `seed.sql` 開頭有「僅供地端、勿灌雲端」警語（它會直接寫 `auth.users`、用固定 UUID 與明文密碼）。種子資料**不含 settlement**（entries 全部停在 `open`），這樣 `initiate_settlement` 的測試才有完整的候選集合可算。日後若要在種子裡放 settlement，涵蓋的 entries 必須同時標成 `settling`，否則狀態機從一開始就不一致。

種子資料（`supabase/seed.sql`）：兩個使用者 `mike@test.local`／`wife@test.local`（密碼皆 `password`）、帳本「我們的家」（邀請碼 `A7K3QZM4XB`）、兩位成員（`monthly_topup` 各 10,000）、9 個分類、10 筆帳目（含一筆均分代墊、兩筆 mike 的私人筆）、7 筆預算影子紀錄（本月 5 個分類各一筆、上月 2 個分類各一筆）、7 筆清單／待辦，與 `lib/domain/mock_data.dart` 同一組意義。
