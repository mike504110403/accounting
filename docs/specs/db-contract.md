# DB 契約（Supabase）— 前端接線用（v1.5）

> 對照 `docs/specs/ledger.md`（spec v1.5）與 ADR-0009。
> Migration 檔在 `supabase/migrations/`；地端驗證用 `supabase/tests/run.sh`。
>
> **v1.5（ADR-0009）改了什麼**：私人筆、逐筆分攤、結算多簽、每月自動補入額、共同期初餘額**整組移除**；
> 帳目只有「家庭支出」與「共同收入」，只記「誰先付」；個人補入改成手動的 `personal_topups`；
> 清帳改成「照補入三方對帳」並可一鍵記一筆共同收入。既有資料 **清空重來**（決策 7）。
> 本檔描述的是**現況**；凡提到 v1.4 以前的東西，一律標「v1.5 已移除」。

## Migration 一覽

函式一律用 `create or replace`，同名函式的**最後一次定義**才是現行版本。
最右欄列出「這支 migration 留下來、目前仍生效」的函式，找定義時直接看那一欄。

| 檔名 | 內容 | 這支留下的「活」函式定義 |
| --- | --- | --- |
| `20260902000100_schema.sql` | 擴充（`pg_trgm` 裝在 `extensions` schema，索引用 `extensions.gin_trgm_ops`）、enum、11 張表、索引、邀請碼產生函式 | —（`gen_invite_code` 已被 0017 取代） |
| `20260902000200_rls.sql` | `is_member` / `my_member_id`、全表 RLS 與 policy、authenticated 授權 | `is_member`、`my_member_id` |
| `20260902000300_triggers.sql` | settled 鎖定、settling 期間改動 void、多簽到齊落 settled、`required_signers` | —（**v1.5 全數 drop**） |
| `20260902000400_rpc.sql` | `create_ledger`／`join_ledger`／`initiate_settlement`／`approve_settlement`／`search_items` 與授權 | `search_items`（`create_ledger`／`join_ledger` 已被 0028 取代；結算三支已 drop） |
| `20260902000500_realtime.sql` | `supabase_realtime` publication 收錄 entries / settlements / list_items（冪等寫法） | — |
| `20260902000600_entry_identity.sql` | `entries.created_by`／`ledger_id` 不可變（with check 看不到 OLD，用 trigger 補） | `entries_immutable_identity` |
| `20260902000700_void_trigger_compare_values.sql` | void trigger 加 `when` 子句比對新舊值：值不變就不 void（整列 update 安全） | —（**v1.5 已 drop**） |
| `20260902000800_privilege_hardening.sql` | anon 全表無權；settlements／settlement_entries 前端只讀；entries 欄位級 update；內部函式 revoke anon/authenticated | —（`entries_force_open_on_insert` **v1.5 已 drop**） |
| `20260902000900_signers_snapshot.sql` | `settlement_signers` 需簽者快照表、settlements 狀態機、簽名守衛、`cancel_settlement` | —（**v1.5 全數 drop**） |
| `20260902001000_delete_paths.sql` | delete 走 before trigger（早於 cascade）；settled 不可刪；分攤 delete 鎖 | —（**v1.5 全數 drop**） |
| `20260902001100_settlement_conservation.sql` | 結算涵蓋須有分攤列、逐筆 Σshare 守恆、Σnets 守恆、需簽者快照寫入 | —（**v1.5 已 drop**） |
| `20260902001200_conventions.sql` | pg_trgm 移入 `extensions` schema、realtime publication 冪等、鎖定訊息依欄位分列 | —（**v1.5 已 drop**） |
| `20260902001300_concurrency_and_readonly.sql` | 一帳本一 pending 的 partial unique index、settled 不可刪的 delete policy、簽名收回前端、members 身分不可變 | `members_immutable_identity`（其餘 **v1.5 已 drop**） |
| `20260902001400_cross_ledger_fk.sql` | `(id, ledger_id)` 唯一鍵＋複合 FK／check trigger，杜絕跨帳本引用 | `list_items_same_ledger`（`entry_splits_same_ledger` **v1.5 已 drop**） |
| `20260902001500_split_conservation_and_rounding.sql` | 分攤守恆 deferred constraint trigger、發起結算 advisory lock、淨額最大餘數法 | —（**v1.5 全數 drop**） |
| `20260902001600_lock_occurred_on.sql` | 已結帳連 `occurred_on` 一起鎖；settling 期間改日期也 void | —（**v1.5 已 drop**） |
| `20260902001700_invite_code.sql` | 邀請碼改 10 碼 CSPRNG、`create_ledger` 撞碼重試 | `gen_invite_code`（`create_ledger` 已被 0028 取代） |
| `20260902001800_privilege_lockdown.sql` | 收回全部表權再逐表逐動詞發；關掉 default privileges；entries 的 INSERT 也改欄位級；建帳本只走 RPC | —（`entries_force_open_on_insert` **v1.5 已 drop**） |
| `20260902001900_fk_indexes.sql` | 補齊所有 FK 子欄位的索引 | — |
| `20260902002000_entry_conservation_and_upsert.sql` | entries 側的分攤守恆（deferred）＋ `upsert_entry` RPC | —（兩支都已被後續取代／drop） |
| `20260902002100_upsert_semantics_and_default_privs.sql` | `upsert_entry` 子表改 `null`＝不動；守恆 trigger 重讀當前列；函式 default privileges 關掉 | —（`entries_split_sum_check` **v1.5 已 drop**） |
| `20260902002200_settled_children_and_column_grants.sql` | 已結帳不接受重寫子表；`ledgers`／`members` 欄位級 UPDATE；`rotate_invite_code` | `rotate_invite_code`（`upsert_entry` 已被 0028 取代） |
| `20260902002300_sequences_and_member_insert.sql` | sequences 的授權與 default privileges 一併關掉；`members` 收回 INSERT（加入帳本只走 RPC） | — |
| `20260903000100_budget_allocation_and_funding.sql` | 帳務規則 v1.3（ADR-0007）：`funding` enum ＋ `entries.funding`、`budget_allocation` 表（RLS／欄位級 UPDATE／realtime）、`upsert_entry` 帶 `funding`；**drop `budgets`、drop `categories.rollover`** | `budget_allocation_expense_category` |
| `20260903000200_month_summary.sql` | v1.3 的 `month_summary`（共同餘額／信封剩餘／超支的單一入口） | —（已被 0027／0028 取代） |
| `20260904000100_replica_identity_full.sql` | publication 上的表改 `replica identity full`（DELETE payload 才帶得出 `ledger_id` 供前端過濾） | — |
| `20260904000200_rules_v14.sql` | 帳務規則 v1.4（ADR-0008）整套：`archive` 快照、`members.monthly_topup`、`budget_allocation` 既有資料合併＋`month` generated 欄＋每分類每月唯一＋`amount > 0`＋收回 UPDATE／DELETE、**drop `entries.funding` 與 `funding` enum**、`month_closes` 表（只讀＋realtime）、`taipei_month`／`topup_for` 純函式、`entry_member_effects` view、清帳 RPC、鎖月 trigger、`month_summary` 依 v1.4 公式重寫 | `taipei_month`、`raise_if_month_closed`、`entries_month_closed`、`entry_children_month_closed`、`budget_allocation_month_closed`（`topup_for`、`entry_member_effects`、`upsert_entry`、四支清帳函式、`month_summary` 已被 0028 取代或 drop） |
| `20260905000100_rules_v15.sql` | **帳務規則 v1.5（ADR-0009）整套，刻意不拆成兩支**（任何中間切點都會留下「`entry_splits` 已 drop 但 `entry_member_effects` 還在讀它」之類的破窗）：truncate 五張表的資料、drop 結算四表＋`entry_splits`＋`entry_member_effects` view、drop `entries.scope`／`split_method`／`settled_state`／`ledgers.default_ratio`／`opening_balance_shared`／`members.monthly_topup`／`opening_balance_personal`、drop 四個 enum 與 20 支函式、`entries` 加 `entries_income_no_payer` ＋ RLS 回到「同帳本全可見」、**新表 `personal_topups`**（RLS／鎖月／realtime）、`upsert_entry` 去 splits、`create_ledger`／`join_ledger` 去 `default_ratio`、`month_closes.income_entry_id`、清帳四支重寫（含 `p_record_income` 與金額上界守衛）、`raise_if_month_closed` 改取共享 advisory lock（修清帳競態）、`month_summary` 依 v1.5 公式重寫 | `upsert_entry`、`create_ledger`、`join_ledger`、`personal_topups_month_closed`、`month_close_details`、`month_close_guard`、`month_close_income_amount`、`month_close_preview`、`close_month`、`month_summary` |

## 寫入入口一覽（前端最重要的一張表）

| 想做的事 | 入口 |
| --- | --- |
| **記一筆帳／改帳（帶細項）** | `upsert_entry(p_entry, p_line_items)` —— 同一交易寫完主筆與整組細項 |
| 記一筆帳、改帳、刪帳（不帶細項） | 直接對 `entries` 寫（受 RLS ＋ 欄位級授權） |
| 細項、分類、清單 | 直接寫對應的表（受 RLS） |
| **記一筆個人補入** | 直接 `insert into personal_topups`（`member_id` 與 `created_by` 都必須是自己、`amount > 0`）。**不可 UPDATE**，要改就刪了重記 |
| 刪掉自己未清月的補入 | 直接 `delete from personal_topups where id = …`（只刪得掉自己那列） |
| **設定本月預算** | 直接 `insert into budget_allocation`（一分類一月一列、`amount > 0`；`created_by` 必須是自己）。**設定後不可改不可刪** |
| 改自己的暱稱 | 直接 update `members` 自己那列（**只剩 `display_name` 這一欄可寫**） |
| **預覽清帳明細** | `month_close_preview(p_ledger, p_month)` |
| **清帳** | `close_month(p_ledger, p_month, p_record_income)`（`month_closes` 沒有任何寫入 policy） |
| 讀畫面上的衍生數字 | `month_summary(p_ledger, p_until)` |
| 改帳本名稱 | 直接 update `ledgers`（**只剩 `name` 可寫**） |
| **建帳本／加入帳本** | `create_ledger(name)`／`join_ledger(code)`（`ledgers` 沒有 INSERT 權限） |
| **換邀請碼** | `rotate_invite_code(ledger)`（成員都可呼叫；`invite_code` 欄位不可直接寫） |
| 搜尋 | `search_items(ledger, q)` |

**v1.5 已移除的入口**：`initiate_settlement`／`approve_settlement`／`cancel_settlement`／`required_signers`
（結算多簽整組廢止，ADR-0009 決策 3），以及 `upsert_entry` 的 `p_splits` 參數。
呼叫它們會拿到 `function … does not exist`（42883）。

### 前端角色（authenticated）的完整權限表

`anon` 對 `public` 的所有表**沒有任何權限**。`public` schema 的 default privileges 也已關掉
（Supabase 預設是 GRANT ALL，會讓每張新表自動帶 TRUNCATE／REFERENCES／TRIGGER；
**TRUNCATE 不受 RLS 約束**，拿到就能清空整張表）。新增表時要記得手動 grant。

**函式要特別小心**：Postgres 對函式的**內建**預設是 `EXECUTE TO PUBLIC`——這是寫死在 `acldefault()` 裡的行為，
`ALTER DEFAULT PRIVILEGES` 只能在「由該角色、在該 schema 新建」時覆蓋掉它，涵蓋不到別的角色建的函式。
所以規矩是：**每新增一支函式，都要顯式 `revoke execute on function … from anon, authenticated, public`**，
真正要給前端用的再 `grant execute … to authenticated`。
守門的是 `supabase/tests/rls.sql` 的白名單全掃描——它掃 `public` 底下**每一支**函式，
只有白名單內的 RPC 允許授權給 `authenticated`。新增 RPC 時記得同步更新那份白名單，否則測試會紅。

| 表 | select | insert | update | delete |
| --- | :---: | :---: | :---: | :---: |
| `ledgers` | ✓ | — | 欄位級（只有 `name`） | — |
| `members` | ✓ | — | 欄位級（只有 `display_name`） | — |
| `categories`／`list_items`／`line_items` | ✓ | ✓ | ✓ | ✓ |
| `budget_allocation` | ✓ | 欄位級 | — | — |
| **`personal_topups`** | ✓ | 欄位級 | **—** | ✓（只有自己那列） |
| `entries` | ✓ | 欄位級 | 欄位級 | ✓ |
| `month_closes` | ✓ | — | — | — |

（v1.5 已移除：`settlements`／`settlement_entries`／`settlement_approvals`／`settlement_signers`／`entry_splits` 五張表，
以及 `entry_member_effects` view。整個 `public` schema 現在**一個 view 都沒有**。）

`entries` 的欄位級授權：

- **INSERT**：`ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id, is_adjustment`
- **UPDATE**：同上但**去掉 `ledger_id` 與 `created_by`**
- 兩者都不含 `id`／`created_at`。（`scope`／`split_method`／`settled_state` 三欄 **v1.5 已移除**。）

`personal_topups` 的授權：

- **INSERT**：欄位級 `ledger_id, member_id, amount, occurred_on, note, created_by`（比照 `entries` 與 `budget_allocation`）。
  **不含 `id`／`created_at`**——`created_at` 是「這筆補入是哪一刻記的」的唯一來源，不給前端自己填。
  `month` 是 generated 欄，寫它一律 `cannot insert a non-DEFAULT value into column "month"`。
- **SELECT／DELETE**：表層級（DELETE 由 policy 限「只刪得掉自己那列」）。
- **UPDATE：完全沒有**，policy 也沒有。補入是一筆一筆的事實紀錄，要改就刪了重記
  （少一條路徑，就少一種「改到別人那列」的可能）。

`budget_allocation` 的欄位級授權：

- **INSERT**：`ledger_id, category_id, amount, occurred_on, note, created_by`（**不含 `id`／`created_at`／`month`**）。
- **UPDATE／DELETE**：**一欄都不開**。預算是「設定當月預算」的影子紀錄，設定後不可改、不可刪、不可退回
  （ADR-0008 決策 6，v1.5 未改）；寫了就是 `permission denied for table budget_allocation`。

`ledgers` 的 UPDATE 只開 `name`；**`invite_code` 不可寫**——輪替走 `rotate_invite_code`，
否則任何成員都能把邀請碼改成自己記得住的字串（等於自選密碼）。
`members` 的 UPDATE 只開 `display_name`（policy 另限「只能改自己那列」）。
（`ledgers.default_ratio`／`opening_balance_shared`、`members.monthly_topup`／`opening_balance_personal`
**v1.5 已移除**，連欄位帶授權一起消失——舊 build 送這些鍵會直接寫失敗，所以務必**先 push migration 再上 build**。）

## 表與欄位

所有表都有 `id uuid default gen_random_uuid()` 與 `created_at timestamptz default now()`，以下省略。

| 表 | 欄位 |
| --- | --- |
| `ledgers` | `name text`、`invite_code text unique`（**10 碼**大寫英數 base32，`gen_invite_code()` 以 `extensions.gen_random_bytes` 產生） |
| `members` | `ledger_id`、`user_id → auth.users`、`display_name text`、`joined_at`；`unique(ledger_id, user_id)` |
| `categories` | `ledger_id`、`kind entry_kind`、`name text`、`icon text`（對應 `lib/app/category_icon.dart` 的名稱）、`sort int` |
| `entries` | `ledger_id`、`kind entry_kind`、`amount int`、`category_id`、`occurred_on date`、`note text`、`created_by → members`、`payer_id → members`（**null＝共同錢包**；`kind = 'income'` 時恆 null）、`is_adjustment bool` |
| `line_items` | `entry_id`、`name text`、`amount int null`、`sort int` |
| **`personal_topups`** | `ledger_id`、`member_id → members`（只能是自己）、**`amount int`**（`> 0`）、`occurred_on date`、**`month date`**（`generated always as (date_trunc('month', occurred_on::timestamp))::date stored`）、`note text`（預設 `''`）、`created_by → members`（必須是自己）；索引 `(ledger_id, occurred_on)`、`(member_id)`、**`(ledger_id, member_id, month)`**（熱查詢的形狀：`month_summary` 與 `month_close_details` 問的都是「這本帳、這個人、這個月」）；複合 FK `(member_id, ledger_id)`／`(created_by, ledger_id)` 綁死同帳本 |
| `budget_allocation` | `ledger_id`、`category_id`（必須是同帳本的**支出**分類）、**`amount int`**（`> 0`）、`occurred_on date`、**`month date`**（generated，同上）、`note text`、`created_by → members`（必須是自己）；**`unique(ledger_id, category_id, month)`**；索引 `(ledger_id, occurred_on)`、`(category_id)`、`(created_by)`；複合 FK `(category_id, ledger_id)`／`(created_by, ledger_id)` |
| `month_closes` | `ledger_id`、`month date`（月初）、`closed_by → members`、`closed_at timestamptz`、**`income_entry_id uuid null → entries on delete set null`**、`details jsonb`；`unique(ledger_id, month)`（這道 unique 本身就是 `(ledger_id, month)` 的索引，**不另建**普通索引）；索引 `(closed_by)`；複合 FK `(closed_by, ledger_id)` |
| `list_items` | `ledger_id`、`title text`、`store text null`、`estimated int null`、`category_id null`（null＝待辦）、`assignee_id null`、`due_on date null`、`done_at timestamptz null`、`entry_id null`、`sort int` |

`month_closes.details` ＝
`{"month": "YYYY-MM-01", "members": [{member_id, display_name, topup, paid, ending}…（依 joined_at, id 排序）], "shared_paid": n}`，
是清帳當下的**快照**。`topup`／`paid`／`ending`／`shared_paid` 都是 **bigint**——`amount` 雖然是 int，
一個月加起來輕鬆越過 int 上界，而清帳不可撤銷，最不該在這裡因為型別炸掉。

enum：只剩 `entry_kind(expense|income)`。
（`entry_scope`、`split_method`、`settled_state`、`settlement_status`、`funding` **v1.5／v1.4 已 drop**。）

`archive.budget_allocation_v13`：0027 留下的 v1.3 撥款流水快照，**v1.5 刻意不動**（遷移可逆性的憑據）。
前端角色連 `archive` schema 的 `USAGE` 都沒有。

### 前端對照的提醒

**畫面上的數字一律由 `month_summary` 算**（ADR-0009）：DB 只存帳目、補入（`personal_topups`）、
預算影子紀錄（`budget_allocation`）與清帳紀錄（`month_closes`），沒有餘額欄位也沒有 view；
共同餘額／個人補入剩餘／已花／剩餘／超支一律呼叫 `month_summary(p_ledger, p_until)` 取得。

### check constraint（前端要先擋，否則 insert 會被 DB 打回）

- `entries_amount_sign`：一般帳 `amount >= 0`；負數僅沖銷紀錄（`is_adjustment = true`，由前端沖銷流程自動產生）。
- **`entries_income_no_payer`**（v1.5 新）：`kind = 'income'` 時 `payer_id` 必須是 null。
  收入只有「共同收入」，一律進共同餘額，沒有付款人。前端的新增表單在 kind = income 時不該顯示「誰先付」那一列。
- **`personal_topups_amount_positive`**（v1.5 新）：`amount > 0`。0 與負數都無意義，退回請刪掉那一列。
- `budget_allocation_amount_positive`：`amount > 0`。
- `budget_allocation_one_per_category_month`：`unique (ledger_id, category_id, month)`——同分類同月第二筆會拿到 **23505**，前端要先擋並顯示「本月已設定」。
- `month_closes_month_is_first_day`：`month` 必須是月初；`month_closes_one_per_month`：`unique (ledger_id, month)`（同月只清一次）。
- 跨帳本一律由複合 FK 擋：`entries_payer_same_ledger`／`entries_category_same_ledger`／
  `personal_topups_member_same_ledger`／`personal_topups_created_by_same_ledger`／
  `budget_allocation_category_same_ledger` 等；`budget_allocation` 的「必須是支出分類」由 trigger 擋
  （`budget allocation: category must be an expense category`）。

（v1.5 已移除：`entries_private_payer`／`entries_private_no_split`／`entries_private_open`／
`members_monthly_topup_range`／`entries_funding_common_wallet_only`。）

### v1.5 的資料處置（`20260905000100`）

**清空重來，不做轉換**（ADR-0009 決策 7）。migration 開頭一句
`truncate table entries, budget_allocation, list_items, settlements, month_closes cascade`——
cascade 一併清掉 `line_items`、`entry_splits`、`settlement_entries`、`settlement_approvals`、`settlement_signers`。
**帳本、成員、分類保留**（那三張表的語意沒變）。

為什麼不轉換：v1.4 的每一筆帳目都帶著 `scope`／`split_method`／`settled_state` 的語意，
而 v1.5 把私人筆、逐筆分攤、結算整組廢掉，沒有一組對應規則能把舊筆轉成新語意
（一筆 equal 分攤的代墊，在 v1.5 到底算「Mike 先付全額」還是「兩人各先付一半」？無解）。

migration 的順序是刻意的，換順序會直接失敗（都實測過）：

1. `truncate` 資料
2. drop 只服務結算／分攤／私人筆的 **trigger**
3. drop 帶「私人筆可見性」條件的 **policy**（policy 對 `scope`／`settled_state` 有 catalog 依賴，不先拆 drop column 會被擋）
4. drop `entry_member_effects` **view**（對 `scope`／`settled_state`／`entry_splits` 都有依賴）
5. drop **回傳型別是 `public.settlements` 的三支 RPC**（`initiate_settlement`／`approve_settlement`／`cancel_settlement`）
   —— 它們對表的複合型別有依賴，不先 drop 就會 `cannot drop table settlements because ... depends on type settlements`（2BP01）
6. drop **表**（子到父）
7. drop 那些表的 **trigger 函式**（表還在時 trigger 對函式有 pg_depend 依賴，drop 不掉）
8. drop **欄位** → drop **enum**

`entries.scope`／`split_method`／`settled_state` 是直接 `drop column`：相關的 check、index 與欄位級授權
隨欄位一起消失。第 2 節接著把 `entries` 的 INSERT／UPDATE 授權**明寫重發**一次，
好讓「授權清單＝可寫欄位清單」在檔案裡看得到。

## RLS 一句話版

- 一切以「你是不是這本帳本的成員」為界：`is_member(ledger_id)`。非成員（含 anon）看到空集合。
- **`entries`：`select`／`update`／`delete` ＝ 成員（就這樣）**；`insert` ＝ 成員 且
  `created_by = my_member_id(ledger_id)`。**不能以別人的名義記帳。**
  v1.5 沒有私人筆，同帳本成員對帳目**全可見、也都編輯得動**（ADR-0009 決策 1）。
  - **欄位級 update 授權**：`authenticated` 只被授權寫
    `kind, amount, category_id, occurred_on, note, payer_id, is_adjustment`。
    `created_by`／`ledger_id`／`id`／`created_at` 完全沒有授權，前端寫了就是 `permission denied for table entries`。
  - `created_by` 與 `ledger_id` 另有不可變 trigger 當第二道（給 `service_role` 之類繞過欄位授權的路徑用）。
  - **v1.5 沒有 settled 鎖**：`entries_before_delete`（0010 的 before delete 守衛）整支 drop，
    update／delete 只剩鎖月（`a_entries_month_closed_trg`）。金額有誤走沖銷（反向紀錄＋重記）。
  - **「未清月的非沖銷關係筆才可刪」這條 DB 不再守，由前端負責**（spec「沖銷」節）：
    DB 端沒有沖銷指向欄，也沒有任何 trigger 擋「刪掉原筆卻留下沖銷筆」或「同一筆沖銷兩次」。
    前端的沖銷配對靠備註短代碼（`reversal.dart` 的 `沖銷 #<tag>`），
    所以列表／明細的刪除入口必須自己把沖銷關係筆排除掉。
- `line_items`：select 與 insert／update／delete 都跟隨父 `entry`，條件與 `entries` 的 policy 逐字相同
  （`exists` 子查詢明寫，不只倚賴 `entries` 自身 RLS）。
- **`personal_topups`**：
  - `select` ＝ 同帳本成員（**兩人都看得到彼此的補入與剩餘**，spec 預算頁每位成員一列）。
  - `insert` ＝ `member_id = my_member_id(ledger_id) and created_by = my_member_id(ledger_id)`
    （`my_member_id` 對非成員回 null，null 比較不成立 → 非成員自然被擋，拿到 42501）。
  - `delete` ＝ `member_id = my_member_id(ledger_id)`（只刪得掉自己的；刪別人的是 RLS 過濾成 0 列，不會 raise）。
  - **沒有 update policy 也沒有 update 授權**。
- `categories`／`list_items`：成員全權（增刪改查）。
- `budget_allocation`：成員可讀可新增，**不可改不可刪**；insert 的 with check 是
  `is_member(ledger_id) and created_by = my_member_id(ledger_id)`——不能以別人的名義設定預算。
- `month_closes`：**成員只讀**（只有一條 select policy）。沒有 insert／update／delete policy，也沒有表權——
  清帳只能經 `close_month`（security definer），而且不可撤銷。
- `members`：同帳本成員可讀；只能 update 自己那列（且只有 `display_name`），
  `ledger_id`／`user_id` 不可變（trigger）。**沒有 INSERT 權限**——加入帳本一律走 `join_ledger`／`create_ledger`。
- `ledgers`：成員可讀、可改名；**沒有 INSERT 權限**（建帳本走 `create_ledger`）。

## 輔助函式

| 函式 | 說明 |
| --- | --- |
| `public.is_member(p_ledger uuid) returns boolean` | security definer；呼叫者是否為該帳本成員 |
| `public.my_member_id(p_ledger uuid) returns uuid` | security definer；呼叫者在該帳本的 member id，非成員回 null |
| `public.month_close_details(p_ledger uuid, p_month date) returns jsonb` | **內部**（security definer，不 grant 前端）；清帳明細的唯一實作，`month_close_preview` 與 `close_month` 共用 |
| `public.month_close_guard(p_ledger uuid, p_month date) returns void` | **內部**；可清條件的唯一實作，兩支共用 |
| `public.month_close_income_amount(p_details jsonb) returns bigint` | **內部**（immutable）；`greatest(0, Σ ending)`。預覽與落地共用同一支，避免「預覽說會記 12,000、實際記了別的數」 |
| `public.raise_if_month_closed(p_ledger uuid, p_month date) returns void` | **內部**；`entries`／`line_items`／`budget_allocation`／`personal_topups` **四支**鎖月 trigger 共用的檢查。**volatile**：它開頭會取 `pg_advisory_xact_lock_shared`（與 `close_month` 的排他鎖同 key），見下方「清帳與一般寫入的競態」 |
| `public.personal_topups_month_closed()` | **內部** trigger 函式；補入的鎖月。它一樣呼叫 `raise_if_month_closed`，所以訊息**與其餘三張表一字不差**（`month closed: YYYY-MM`） |
| `public.taipei_month(p_ts timestamptz) returns date` | **純函式**（不讀任何表）；timestamptz → 台北當地月初。「加入月」與「當月」的唯一定義 |

`taipei_month` 有 grant 給 `authenticated`（因此也在 `rls.sql` 白名單裡）：
`month_summary` 是 `security invoker`，它呼叫的函式權限是以**原呼叫者**身分檢查的，不 grant 就一路
`permission denied for function`。它不碰任何表、只做日期換算，給前端執行洩不出資料。

（v1.5 已移除：`topup_for`、`required_signers`／`required_signers_internal`、
`void_settlements_for_entry`，以及 `entry_member_effects` view。）

## RPC 簽名

多數是 `security definer`、`set search_path = public`、開頭檢查 `auth.uid()`。
**走 `security invoker` 的有三支**，都是刻意的：`search_items`（吃 RLS）、
`upsert_entry`（RLS 與欄位級授權照常生效，這支只提供原子性）、
`month_summary`（非成員被 RLS 濾成空，不必再寫一套成員檢查）。

所有 RPC 的參數名以本檔標頭為準（PostgREST 走**具名**參數，名字打錯會是 `function … does not exist`，不是少一個參數）。

### `create_ledger(name text) returns public.ledgers`

建帳本 → 把呼叫者插成 member（`display_name` 取 `auth.users.raw_user_meta_data->>'full_name'`，
否則 email 的 `@` 前綴，再否則 `'我'`）→ 灌 9 個預設分類（食品／餐飲／日常用品／住房／水電／交通／娛樂；薪水／獎金）。
（v1.5 起**不再寫 `default_ratio`**——那個欄位已經沒了。）

```dart
final ledger = await supabase.rpc('create_ledger', params: {'name': '我們的家'});
```

### `join_ledger(code text) returns public.ledgers`

以邀請碼加入（大小寫與前後空白會正規化）。已是成員 → 直接回該帳本，不重複插。
錯碼 raise `join_ledger: invalid invite code`。（v1.5 起不再重算 `default_ratio`。）

```dart
final ledger = await supabase.rpc('join_ledger', params: {'code': inviteCode});
```

### `upsert_entry(p_entry jsonb, p_line_items jsonb default null) returns public.entries`

**帶細項的帳目，寫入請走這支**（同一交易寫完主筆＋整組細項）。`security invoker`：
RLS 與欄位級授權照常生效，這支只提供原子性。

- `p_entry` 有 `id` → 更新該筆（找不到或看不到 raise `upsert_entry: entry not found or not visible`）；沒有 `id`（或空字串）→ 新增。
- `created_by` 一律強制為呼叫者自己的 member id（`p_entry` 裡帶什麼都沒用）。
- `payer_id`：**有帶這個鍵**才會動它——空字串／null ＝ 共同錢包，member id ＝ 該成員先付。沒帶就維持原值。
- **鎖定範圍**：`occurred_on` 所在月 **≤ 最後清帳月** → trigger raise `month closed: YYYY-MM`
  （新增、修改、把日期搬進去、動細項都擋）。
- `p_line_items` 的三種語意：`null`（或省略）＝**完全不動細項**；`[]` ＝**清空**；有內容 ＝ 全刪重建。
- 全刪重建時會比對刪除筆數：若 RLS 靜默過濾掉某些列，直接 raise 而不是留下半套資料。
- **v1.5 起沒有 `p_splits`**：三參數版已 drop（留著會讓 `upsert_entry(a, b)` 變成 ambiguous）。
  多送 `scope`／`split_method`／`funding` 這些鍵不會報錯也不會有任何效果（jsonb 多餘鍵直接被忽略）。

```dart
final entry = await supabase.rpc('upsert_entry', params: {
  'p_entry': {
    'ledger_id': ledgerId, 'kind': 'expense',
    'amount': 1000, 'category_id': categoryId,
    'occurred_on': '2026-09-02', 'note': '全聯買菜',
    'payer_id': myMemberId,          // null／'' ＝ 共同錢包
  },
  'p_line_items': [
    {'name': '雞蛋', 'amount': 89, 'sort': 0},
  ],
});
```

### `rotate_invite_code(ledger uuid) returns public.ledgers`

換一張新的 10 碼邀請碼（舊碼立刻失效）。任一成員都可呼叫；非成員 raise `rotate_invite_code: not a member`。
撞 unique 會自動重抽，最多五次。

### `search_items(ledger uuid, q text) returns table(...)`

回傳欄位：`kind text`（`line_item`｜`entry`｜`list_item`）、`id uuid`、`entry_id uuid`、`name text`、
`amount int`、`occurred_on date`、`category_id uuid`、`note text`。
比對 `line_items.name`／`entries.note`／`list_items.title`（ILIKE，索引走 `gin_trgm_ops`）。`q` 空字串回空集合。
走 `security invoker` → 吃呼叫者的 RLS。**v1.5 起同帳本成員互相搜得到彼此的帳目**（沒有私人筆了）；
非成員一樣搜不到任何東西。函式本身在 v1.5 沒有改動——可見性一直是由 `entries` 的 select policy 決定的。

### `month_summary(p_ledger uuid, p_until date) returns jsonb`（v1.5）

畫面上的衍生數字統一從這支拿（`security invoker`）。
**`p_until` 不夾上界**：前端的月份切換沒有上界（下個月的預算本來就可以先設），
所以問下個月要拿得到下個月的 `allocated`／`spent`／`categories`／`members`；
`shared_balance` 是**累計值**，一律累計到 `p_until`。`p_until` 傳 `null` ＝「問到本月底」。

```jsonc
{
  "shared_balance": 17000,      // bigint。Σ共同收入 − Σ共同錢包支出（payer_id is null），occurred_on <= until。**無期初**
  "budget_total": 9500,         // bigint。until 所在月的 Σ預算
  "spent_total": 11000,         // bigint。until 所在月的 Σ**全部**支出（不分誰付）
  "overspend_total": 4200,      // bigint。Σ max(0, spent − allocated)
  "categories": [               // 有預算或有支出的分類，依 category_id 排序
    // allocated 是 int（單筆預算）；spent／remaining／over 是 bigint（加總，一個月就越得過 int 上界）
    {"category_id": "…", "allocated": 6000, "spent": 10200, "remaining": 0, "over": 4200}
  ],
  "members": [                  // **全體成員**，依 joined_at, id 排序；都是 until 所在**整月**的數
    {"member_id": "…", "display_name": "Mike", "topup": 10000, "paid": 6000, "remaining": 4000}
  ],
  "shared_paid": 3000           // bigint。until 所在**整月** payer_id is null 的支出合計（對照用）
}
```

- **`shared_balance`**（共同餘額）＝ Σ共同收入 − Σ`payer_id is null` 的支出。
  **成員先付的支出完全不動它**；清帳「一鍵記共同收入」記的是一筆普通收入紀錄，所以走的仍是這條路。
- **`members[*]`**（個人補入剩餘）：`topup` ＝ 該成員 `personal_topups` 中 `month = until 所在月` 的 Σ`amount`；
  `paid` ＝ 該成員為 `payer_id` 的支出（**含沖銷的負數筆**）同條件 Σ；
  `remaining = topup − paid`，**可為負**（先付超過補入時不夾 0——夾 0 會讓「這個月我墊了多少」憑空消失）。
- **兩種口徑，別搞混**：`members[*]` 與 `shared_paid` 取 `p_until` 所在**整月**，
  **不加 `occurred_on <= p_until` 的當日夾限**（spec 的口徑是「每人每月」）；
  `shared_balance`／`spent_total`／`categories` 則維持 `occurred_on <= until` 的累計／夾限口徑。
  理由：補入剩餘是一個月結算一次的數，月中查詢若把「這個月稍晚才發生的先付」切掉，
  預算頁顯示的剩餘會比實際多，也會與 `month_closes.details` 的快照對不起來。
  實務上的差別只在「查當月的月中某一天」，查歷史月份兩者一致。
- `allocated` 取的是該分類 `month = until 所在月` 的那一筆（0 或 1 筆），**刻意不加 `occurred_on <= until`**：
  預算是「當月的影子紀錄」，設定當下就對整個月生效（`spent` 則相反，是逐筆累加，所以有 `occurred_on <= until`）。
- `spent` ＝ 該分類該月**全部**支出，不分誰付（成員先付與共同錢包都算，ADR-0009 三個數表）。
- **已清月照樣由帳目算，不再回 0**：已清月的資料被鎖月 trigger 鎖死，與 `month_closes.details` 的快照必然相等
  （`month_close.sql` 的 c12 逐位比對過）。前端要顯示歷史清帳明細時讀快照比較省事，但兩條路同值。
- **v1.4 的 `me` 鍵已移除**（那時只回呼叫者自己）。v1.5 預算頁要列出每位成員一列，所以改成 `members` 陣列。
- **「已清帳」全庫只有一個定義：月份 ≤ `max(month_closes.month)`**。鎖月 trigger 用 `<= max`。
  不用「有沒有那一列」判，是因為清帳只能按序推進、正常情況兩者等價，但**雲端人工救援刪掉中間某一列**之後
  兩者會分岔。→ **人工救援（在雲端 SQL 刪 `month_closes` 列）只能從最後一列往前刪**，不可以挖中間。
  （唯一的例外是 `close_month` 可清條件裡那條 `already closed`：它刻意用「該月有沒有紀錄」判，
  職責只是給人看得懂的訊息，不決定鎖不鎖。）

### `month_close_preview(p_ledger uuid, p_month date) returns jsonb`（v1.5）

清帳預覽。可清條件不過就 raise（訊息見下表），過了回 `close_month` 會寫進 `details` 的那份明細，
**外加一個 `income_amount`**。非成員 raise `month_close_preview: not a member`（42501）。

```jsonc
{
  "month": "2026-08-01",
  "members": [                  // 依 joined_at, id
    {"member_id": "…", "display_name": "Mike", "topup": 3000, "paid": 1200, "ending": 1800}
  ],
  "shared_paid": 1000,          // 該月共同錢包支出合計，對照用
  "income_amount": 3000         // Σ ending，< 0 時回 0；＝勾選「一鍵記共同收入」時會記的金額
}
```

- `ending` ＝ `topup − paid`。`> 0` →「{成員} 轉 {金額} 給共同帳戶」；`< 0` →「共同帳戶補 {成員} {金額}」；`= 0` →「免處理」。
- **沒有 `warnings` 鍵**（v1.4 的 `unsplit_advances` 隨分攤一起消失）。
- `close_month` 落地的 `details` ＝ **preview 減掉 `income_amount`**，比對時記得 `preview - 'income_amount'`。

### `close_month(p_ledger uuid, p_month date, p_record_income boolean default true) returns public.month_closes`

清帳。同帳本 `pg_advisory_xact_lock` 序列化 → 可清條件檢查 → （視 `p_record_income`）記一筆共同收入 →
寫入 `month_closes`。任一成員可執行、不需多簽、**不可撤銷**。

**可清條件與訊息（與 `month_close_preview` 共用，檢查順序就是下表由上而下）**：

| # | 條件 | 不過時的訊息 |
| --- | --- | --- |
| 1 | `p_month` 必須是月初 | `close_month: month must be first day` |
| 2 | 依台北時間早於當月 | `close_month: month not ended` |
| 3 | 該月還沒清過 | `close_month: already closed` |
| 4 | 有可清的月份（下一個可清月早於當月） | `close_month: nothing to close` |
| 5 | 必須是**下一個可清月**（有 closes → `max(month) + 1 月`；沒有 → `least(最早成員加入月, 最早帳目月, 最早補入月)`，null 略過） | `close_month: must close YYYY-MM first` |

v1.4 的第 6 條（`unsettled entries in month`）**已移除**——沒有結算了。
「已清過」刻意排在「順序」之前：清過的月份一定不等於下一個可清月，排在後面的話重清同月會拿到
`must close … first` 而不是看得懂的 `already closed`。

**一鍵記共同收入**（`p_record_income`，前端確認頁的勾選框，**預設勾**）：

- `p_record_income = true` **且** `income_amount > 0` 時才記；`income_amount ≤ 0` 即使勾了也不記
  （`income_entry_id` 為 null）。
- 記之前先確保帳本有一個 `kind = 'income'`、`name = '清帳轉入'` 的分類；沒有就自動建
  （`icon = 'savings'`，`sort` 取該帳本 income 分類最大 `sort + 1`）。
- 記的那筆：`kind='income'`、`amount = income_amount`、`category_id` ＝ 上面那個分類、
  `occurred_on` ＝ **該清帳月的最後一天**、`note` ＝ `'YYYY／MM 清帳'`（**全形斜線**）、
  `created_by` ＝ 呼叫者、`payer_id = null`、`is_adjustment = false`。
- `month_closes.income_entry_id` 指向它（`on delete set null`）。
  它是一筆普通收入（可沖銷），但落在已清月所以實際上被鎖月鎖住。
- **金額上界**：`details` 裡的 `topup`／`paid`／`ending` 一路是 bigint，
  但**落地時受 `entries.amount` 的 int 上界所限**。`income_amount` 超過 2,147,483,647 時
  `close_month` 會先 raise `close_month: income amount exceeds limit`，
  而不是丟一句看不出所以然的 `integer out of range`（清帳不可撤銷，最不該在這裡丟看不懂的錯）。
- **順序是「先記收入、再寫 `month_closes`」**：反過來的話 `a_entries_month_closed_trg` 會看到
  「這個月已經清了」而擋掉自己剛要記的那一筆（`month_close.sql` c14 用反證驗過這條）。

**清帳與一般寫入的競態（v1.5 修）**：`close_month` 開頭取
`pg_advisory_xact_lock(hashtextextended(p_ledger::text, 0))` 把同帳本的清帳序列化，
但鎖月檢查（`raise_if_month_closed`）原本只是一個 READ COMMITTED 的 `select max(month)`，
不參與這把鎖。於是有一個真的會發生的窗口：

```
T1  A 呼叫 close_month，取排他鎖、算好 details 快照（此時上月還沒有 month_closes 列）
T2  B 同時補記一筆上月的帳目 → raise_if_month_closed 看不到任何 month_closes 列 → 放行
T3  A 寫入 month_closes、commit
    ⇒ B 那筆錢沒被算進快照，但它所屬的月份立刻鎖死：改不掉、刪不掉、也永遠不會再被清一次
```

修法：`raise_if_month_closed` 開頭取**共享**鎖 `pg_advisory_xact_lock_shared`，key 與上面逐字相同。
一般寫入之間彼此不互斥（記帳照常並行），但 `close_month` 的排他鎖擋得住它們，
反之 `close_month` 也必須等在途的寫入 commit。
同一交易先排他、後共享是安全的（`close_month` 自己記那筆清帳收入時會觸發鎖月檢查），
lock manager 對「同一交易已持有的鎖」不視為衝突。
`month_close.sql` 的 c18 用 `pg_locks` ＋ `pg_get_functiondef` 兩道把這件事釘住。

```dart
final preview = await supabase.rpc('month_close_preview',
    params: {'p_ledger': ledgerId, 'p_month': '2026-08-01'});
final row = await supabase.rpc('close_month',
    params: {'p_ledger': ledgerId, 'p_month': '2026-08-01', 'p_record_income': true});
```

## Trigger（前端要預期的錯誤）

| Trigger | 行為 |
| --- | --- |
| `entries_immutable_identity_trg` | 改 `created_by` → raise `entry: created_by is immutable`；改 `ledger_id` → raise `entry: ledger_id is immutable` |
| `members_immutable_identity_trg` | 改 `ledger_id`／`user_id` → raise `member: ... is immutable` |
| `a_entries_month_closed_trg` | **before insert/update/delete**：`occurred_on` 所在月 **≤ 最後清帳月** → raise `month closed: YYYY-MM`（訊息帶的是**被擋的那筆所屬的月**，不是最後清帳月）。update 會同時檢查新值與舊值那個月（所以「把日期搬進鎖定範圍」與「動鎖定範圍裡的帳目」都擋）|
| `a_line_items_month_closed_trg` | 同上，看的是父 entry 的 `occurred_on`。父筆被 cascade 刪掉時查不到父列 → 放行 |
| `a_budget_allocation_month_closed_trg` | **before insert/update/delete**：`occurred_on` 所在月 ≤ 最後清帳月 → raise。前端本來就沒有 UPDATE／DELETE 授權，掛三個動詞是為了擋 `service_role` 那條繞過欄位授權的路徑 |
| **`a_personal_topups_month_closed_trg`** | **before insert/update/delete**：`occurred_on` 所在月 ≤ 最後清帳月 → raise `month closed: YYYY-MM`。**與帳目／細項／預算共用同一支 `raise_if_month_closed`、訊息一字不差**：四張表同一句話、同一個判準，前端一條 `startsWith('month closed:')` 就對映得完 |
| `budget_allocation_expense_category_trg` | 預算只能掛支出分類 → raise `budget allocation: category must be an expense category` |
| `list_items_same_ledger_trg` | 跨帳本引用 raise `list_item: ... belongs to another ledger` |

**鎖月 trigger 一律用 `a_` 開頭**：trigger 依名稱字母序執行，這個慣例從 0027 起就在，
v1.5 的 `personal_topups` 照著取名。
（v1.5 已移除的 trigger：`entries_lock_settled_trg`、`entries_force_open_on_insert_trg`、
`entries_split_sum_check_trg`、`entries_void_pending_settlement_trg`／`..._del_trg`、
`entry_splits_*`（隨表消失）、`settlements_status_machine_trg`、`settlement_approvals_guard_trg`、
`settlement_finalize_on_approval_trg`、`settlement_entries_same_ledger_trg`、
`a_entry_splits_month_closed_trg`。）

前端存檔一律 try/catch：踩到 `month closed:` 要顯示「該月已清帳」。
**v1.5 沒有任何 `entry settled: …` 的錯誤**——那一整組隨結算消失了，前端不必再對映。

### 錯誤訊息一覽（前端要逐條對應文案）

| 來源 | 訊息 | 前端該顯示什麼 |
| --- | --- | --- |
| `a_entries_month_closed_trg`／`a_line_items_...`／`a_budget_allocation_...` | `month closed: YYYY-MM` | 「該月已清帳」——表單日期、列表左滑、明細選單都要先擋 |
| `a_personal_topups_month_closed_trg` | `month closed: YYYY-MM`（與上一列同格式） | 「該月已清帳」——補入的新增與刪除入口在已清月要先擋掉 |
| `close_month`／`month_close_preview` | `close_month: month must be first day` | 內部錯誤（前端一律只送月初，送到代表 bug） |
| 同上 | `close_month: month not ended` | 「本月尚未結束」 |
| 同上 | `close_month: already closed` | 「該月已清帳」 |
| 同上 | `close_month: nothing to close` | 「沒有可清的月份」（清帳按鈕 disabled 的原因之一）|
| 同上 | `close_month: must close YYYY-MM first` | 「請先清 YYYY／MM」 |
| 同上 | `close_month: not a member`（42501）／`month_close_preview: not a member` | 不該發生（已切帳本才會看到清帳頁）|
| `upsert_entry` | `upsert_entry: not a member`（42501）／`entry not found or not visible` | 不該發生 |
| `personal_topups` 的 RLS | `new row violates row-level security policy for table "personal_topups"`（42501） | 「只能補自己的」——前端本來就不該讓使用者選別人 |
| `personal_topups` 的 check | `... violates check constraint "personal_topups_amount_positive"`（23514） | 「補入金額要大於 0」 |
| `entries` 的 check | `... violates check constraint "entries_income_no_payer"`（23514） | 內部錯誤（收入表單不該顯示「誰先付」） |

**鎖定範圍是「最後清帳月（含）以前」，不是「有清帳紀錄的那幾個月」**：
清帳只能按序往後推進，所以補記到最早清帳月**之前**的月份永遠不會再是「下一個可清月」，
那筆的影響就會永久留在補入剩餘裡清不掉。判準因此是
`occurred_on 月 <= (select max(month) from month_closes where ledger_id = …)`。

### 更新 entries 的注意事項：先剔除兩個欄位

`created_by`／`ledger_id`（以及 `id`／`created_at`）沒有欄位級 update 授權。
整列送回時**即使值一模一樣**也會被權限層擋下（`permission denied for table entries`，比 trigger 更早發生）。

```dart
// 對：只送要改的欄位，或送整列但剔除身分欄
await supabase.from('entries').update({
  'kind': ..., 'amount': ..., 'category_id': ..., 'occurred_on': ...,
  'note': ..., 'payer_id': ..., 'is_adjustment': ...,
}).eq('id', e.id);

// 錯：toJson() 整個丟回去（含 created_by / ledger_id）→ permission denied
```

建議在 model 上另備一個 `toUpdateJson()`，固定只吐可寫的**七個**欄位
（`kind, amount, category_id, occurred_on, note, payer_id, is_adjustment`）。

## Realtime

`supabase_realtime` publication 收錄**五張表**：
`entries`、`list_items`、`budget_allocation`、`month_closes`、**`personal_topups`**
（publication 上仍吃 RLS）。五張表都是 `replica identity full`，DELETE payload 才帶得出 `ledger_id` 供前端過濾。
（`settlements` 隨 drop table 自動離開 publication。）

```dart
supabase.channel('ledger:$ledgerId')
  .onPostgresChanges(
    event: PostgresChangeEvent.all, schema: 'public', table: 'entries',
    filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'ledger_id', value: ledgerId),
    callback: (_) => ref.invalidate(entriesProvider))
  .onPostgresChanges(
    event: PostgresChangeEvent.all, schema: 'public', table: 'personal_topups',
    filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'ledger_id', value: ledgerId),
    callback: (_) => ref.invalidate(topupsProvider))
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
Apple 不一定給 email／姓名，`create_ledger` 抓不到就用 `'我'`；首登／加入帳本兩關都要求填「你的名稱」，
之後在設定頁改 `members.display_name`（RLS 允許改自己那列）。

## 已知風險（自用取捨，明確記一筆）

| 風險 | 現況 | 為什麼接受 |
| --- | --- | --- |
| 邀請碼可被暴力猜 | 10 碼 base32（≈1.1e15 組），`join_ledger` **沒有失敗次數限流** | 自用、帳本數量極少；真要防要在 Edge Function 或 gotrue 前面做限流 |
| `ledgers`／`entries` 的寫入權過寬 | 任一成員可改帳本名稱、可改／刪其他成員記的帳目（v1.5 沒有私人筆也沒有 settled 鎖） | 夫妻互信情境；要收緊得引入「帳本管理員」概念，目前不做 |
| **沖銷唯一性與沖銷關係筆的刪除，DB 完全不擋** | 沒有 `entries.adjusts_entry_id`，也沒有任何 constraint／trigger 擋「同一筆沖銷兩次」或「刪掉原筆卻留下沖銷筆」 | v1.5 的沖銷配對靠前端備註短代碼（`沖銷 #<tag>`），DB 只看得到一筆負金額的 `is_adjustment` 紀錄。自用、兩人、操作都經 app，接受由前端擋；要在 DB 補這道得先加沖銷指向欄，另開任務 |
| **`personal_topups.created_by`／`month_closes.income_entry_id` 沒有 FK 索引** | 兩者都是 `on delete restrict`／`set null` 的 FK 子欄位，沒有索引 | 成員永遠不會被刪（沒有 delete 授權）；`entries` 被刪時 `month_closes` 只有個位數列。0019 的「FK 都要有索引」慣例在這兩處是刻意的例外 |
| 新增資料表／函式時忘了 grant | 對前端完全不可用（`public` 的 default privileges 已對 tables 與 functions 都關掉） | 這是刻意的：寧可少給，也不要像 Supabase 預設那樣自動帶 TRUNCATE／EXECUTE |
| 函式的 `EXECUTE TO PUBLIC` 是 Postgres 內建預設 | 靠「每支顯式 revoke」＋`rls.sql` 全掃描守，不是靠機制擋 | 想從機制面關掉，得把 RPC 搬到自建的 `api` schema。目前不做 |
| **v1.5 migration 會清資料並 drop 舊表** | `entries`／`budget_allocation`／`list_items`／`month_closes` 清空，結算四表與 `entry_splits` 消失 | ADR-0009 決策 7 的明文裁示。**舊 build 對新 DB 必炸**——先 push migration 再上 build，兩人同時更新 |
| `supabase_admin` 那份 default privileges 改不動 | 地端實測：`postgres` 發的那份已清乾淨，`supabase_admin` 發的那份仍帶 anon/authenticated | 它只影響「由 supabase_admin 建立的表」，我們的 migration 都以 `postgres` 身分建表；雲端 push 後請再跑一次 `rls.sql` 的前置掃描當 smoke test |

## 地端驗證

```bash
~/.local/bin/supabase start          # 只用來驗證；正式開發連雲端（ADR-0005）
supabase/tests/run.sh                # db reset + 逐檔 psql，任一 assert 失敗即非零退出
supabase/tests/run.sh --no-reset     # 只在「剛 reset 過」的 DB 上有效，見下
~/.local/bin/supabase stop
```

測試檔：`budget.sql`、`integrity.sql`、`month_close.sql`、`month_summary.sql`、`replica_identity.sql`、
`rls.sql`、`rpc.sql`、**`topups.sql`**（v1.5 新增，驗 `personal_topups` 的 RLS／授權／check／鎖月）。
（`settlement.sql` 隨結算多簽一起刪除。）

`run.sh` 會在 reset 前後等資料庫真的收連線，reset 後再驗兩件事：schema 真的落地
（`entries`／`month_closes`／`personal_topups` 三張表都在）、**種子是乾淨的原始狀態**
（`entries` 8 筆、`personal_topups` 5 筆、`month_closes` 0 筆）。
不符就自動重試一次 reset，再不行直接以 exit 1 停住、不跑測試。這是因為地端棧有兩個實際踩過的坑：
`db reset` 回來時 Postgres 還沒開始收連線；以及連續 reset 之間棧沒穩定時，CLI 會回
`LegacyDbSetupError`，或回報「migration 都套用了」但連過去卻是空 schema。
**改 `seed.sql` 的筆數就要同步改 `run.sh` 的 `seed_ready`。**

**`--no-reset` 只在剛 reset 過的資料庫上有效。** 測試本身都包在 `begin/rollback` 裡，
但只要有人手動改過資料、或另一個 worktree 動過同一個地端棧，計數型斷言就會失敗。
帶了未知參數會直接以 exit 2 報錯，不會靜默去 reset。

**地端棧同時只能從一個 worktree 操作。** `config.toml` 進 git，所以每個 worktree 的
`project_id` 都一樣（`accounting`），共用同一組 docker 容器；但 CLI 狀態放在
gitignore 的 `supabase/.temp/`，各 worktree 各一份。從「沒起過棧的那個 worktree」下
`supabase db reset`，CLI 會看到容器在跑卻對不上自己的狀態，報 `LegacyLocalDbRunningError`
（`PATH` 少了 `/usr/local/bin` 讓 CLI 找不到 docker 時也是同一個錯誤，別被誤導）。
**已經 `supabase link` 過的 worktree 尤其危險**：在那裡下 `db reset` 有打到雲端專案的風險。

種子資料（`supabase/seed.sql`）——形狀刻意對齊 spec「驗收總表／三個數」那一組：

- 兩個使用者 `mike@test.local`／`wife@test.local`（密碼皆 `password`）、帳本「我們的家」（邀請碼 `A7K3QZM4XB`）、
  兩位成員（`joined_at` 明寫成**上月月初**，否則首次可清月會變成本月、清帳測試無從跑起）、9 個分類。
- **本月**（6 筆帳目）：共同收入 20,000；共同錢包付 3,000；Mike 先付**淨** 6,000
  （原筆 7,000 ＋ 同日同付款人的沖銷筆 −1,000，備註用 `#7g2k` 短代碼配對）；老婆 先付 1,200 ＋ 800 ＝ 2,000；
  補入 Mike 6,000 ＋ 4,000 ＝ 10,000、老婆 10,000；預算 食品 6,000／日常用品 1,500／交通 2,000。
  →`month_summary(本月底)` ＝ `shared_balance` 17,000、`spent_total` 11,000、`shared_paid` 3,000、
  Mike `{10000, 6000, 4000}`、老婆 `{10000, 2000, 8000}`；「食品」已花 10,200，三種付款來源都有。
  那組沖銷是**刻意**放的：`month_summary` 的先付若漏算負數筆，`month_summary.sql` 的 m0 會直接紅。
- **上月**（2 筆帳目，清帳測試用）：**只有成員先付的支出與補入，沒有收入也沒有共同錢包支出**——
  共同餘額是累計水位，上月放了任何一種，本月底的 17,000 就不成立。
  Mike 補入 3,000 先付 1,200、老婆 補入 2,000 先付 800
  →`ending` 1,800／1,200、`shared_paid` 0、`income_amount` 3,000。
- 5 筆細項、7 筆清單／待辦。
- **不再出現** `scope`／`split_method`／`entry_splits`／`default_ratio`／`opening_balance_*`／`monthly_topup`。

種子資料開頭有「僅供地端、勿灌雲端」警語（它會直接寫 `auth.users`、用固定 UUID 與明文密碼）。
