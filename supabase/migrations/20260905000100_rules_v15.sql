-- Migration 0028 — 帳務規則 v1.5（ADR-0009 ＋ spec v1.5）
--
-- 一支裝完整套（比照 0027 的理由，刻意不拆）：任何中間切點都會留下
-- 「entry_splits 已 drop 但 entry_member_effects 還在讀它」之類的破窗，
-- 雲端逐支套用時那個窗口是真的會被打到的。
--
-- 語意（ADR-0009）：概念上只有一種帳目＝家庭支出，只區分「買的東西類型（分類）」
-- 與「誰先付錢」；個人補入改手動記（personal_topups）；清帳＝照補入三方對帳，
-- 可一鍵把應轉入淨額記成一筆共同收入。
--
-- 三個數（每個只有一個來源）：
--   共同餘額       ＝ Σ共同收入 − Σ共同錢包支出（payer_id is null）        ← 無期初
--   個人補入剩餘   ＝ Σ該月補入 − Σ該月本人先付的支出（依 occurred_on 歸月）
--   分類預算剩餘   ＝ 預算 − 該分類該月全部支出（不分誰付）
--
-- 內容：
--   1. 不可逆區（truncate ＋ 全部 drop）
--   2. entries：收入不得有付款人、RLS 回到「同帳本全可見」、欄位級授權重發
--   3. personal_topups 新表（RLS／鎖月／realtime）
--   4. ledgers／members 欄位級授權重發
--   5. upsert_entry 去 splits（兩參數版）
--   6. create_ledger／join_ledger 去 default_ratio
--   7. month_closes.income_entry_id、raise_if_month_closed 取共享鎖（修清帳競態）
--   8. 清帳：明細、可清條件、預覽、執行（含一鍵記共同收入）
--   9. month_summary 依 v1.5 公式重寫
--  10. Realtime publication 收尾

-- ============================================================================
-- ==== 不可逆 ====
-- 以下整段是 truncate 與 drop，套用後回不去（ADR-0009 決策 7「既有資料清空重來」）。
-- 雲端 dev／prod 的表裡有 v1.4 的真實資料，所以順序是：
--   先 truncate 資料 → 再 drop 依賴（trigger／policy／view）→ 最後才 drop 表／欄／enum／函式。
-- 反過來（先 drop 欄）會被「policy 依賴這個欄位」擋下來。
-- ============================================================================

-- ---------- 1a. 清空資料（ADR-0009 決策 7） ----------
-- 為什麼清空而不轉換：v1.4 的每一筆帳目都帶著 scope／split_method／settled_state 的語意，
-- 而 v1.5 把「私人筆」「逐筆分攤」「結算」整組廢掉，沒有一組對應規則能把舊筆轉成新語意
-- （一筆 equal 分攤的代墊，在 v1.5 到底算「Mike 先付全額」還是「兩人各先付一半」？無解）。
-- 決策 7 因此選擇清空重來，帳本／成員／分類保留（那三張表的語意沒變）。
-- cascade 會一併清掉 line_items、entry_splits、settlement_entries、settlement_approvals、
-- settlement_signers（它們都 FK 指向被點名的表）。
-- truncate 不觸發 row trigger，所以 a_entries_month_closed_trg 的鎖月不會擋這一步。
truncate table
  public.entries,
  public.budget_allocation,
  public.list_items,
  public.settlements,
  public.month_closes
cascade;

-- ---------- 1b. drop 只服務結算／分攤／私人筆的 trigger ----------
-- 逐一寫明「drop 了什麼、它原本擋什麼」：
--   entries_force_open_on_insert_trg      — 新帳目強制 settled_state='open'（v1.5 沒有這個欄）
--   entries_lock_settled_trg              — 已結算的帳目鎖 amount／payer／split_method／scope／kind／occurred_on
--   entries_split_sum_check_trg           — entries 側的 deferred 守恆：Σshare 必須等於 amount
--   entries_void_pending_settlement_trg   — settling 期間改實質欄位 → 把 pending 結算打成 void
--   entries_void_pending_settlement_del_trg（函式 entries_before_delete）
--                                          — settled 不可刪 ＋ 刪 settling 筆時先 void 結算
-- v1.5 沒有結算、沒有分攤，這五條全部失去對象。
-- 保留：a_entries_month_closed_trg（鎖月）、entries_immutable_identity_trg（created_by／ledger_id 不可變）。
drop trigger entries_force_open_on_insert_trg on public.entries;
drop trigger entries_lock_settled_trg on public.entries;
drop trigger entries_split_sum_check_trg on public.entries;
drop trigger entries_void_pending_settlement_trg on public.entries;
drop trigger entries_void_pending_settlement_del_trg on public.entries;

-- entry_splits／settlements 三表上的 trigger 隨表 drop 一起消失（1f），這裡不逐一 drop：
--   a_entry_splits_month_closed_trg、entry_splits_lock_settled_trg、entry_splits_lock_settled_del_trg、
--   entry_splits_same_ledger_trg、entry_splits_sum_check_trg、
--   entry_splits_void_pending_settlement_trg、entry_splits_void_pending_settlement_ins_del_trg、
--   settlements_status_machine_trg、settlement_entries_same_ledger_trg、
--   settlement_approvals_guard_trg、settlement_finalize_on_approval_trg

-- ---------- 1c. drop 帶「私人筆可見性」條件的 policy（ADR-0009 決策 1） ----------
-- 這四＋四條的 using／with check 都寫著 `scope = 'shared' or created_by = my_member_id(...)`
-- （entries_delete 另外還有 `settled_state <> 'settled'`、entries_insert 有 `settled_state = 'open'`），
-- 直接依賴著等一下要 drop 的兩個欄位——不先拆掉，drop column 會被依賴關係擋住。
-- 第 2 節以「同帳本成員全可見」重建。
drop policy entries_select on public.entries;
drop policy entries_insert on public.entries;
drop policy entries_update on public.entries;
drop policy entries_delete on public.entries;
drop policy line_items_select on public.line_items;
drop policy line_items_insert on public.line_items;
drop policy line_items_update on public.line_items;
drop policy line_items_delete on public.line_items;
-- entry_splits 與結算四表的 policy 隨表 drop 消失（1f）。

-- ---------- 1d. drop entry_member_effects view（ADR-0009 決策 3／4） ----------
-- 它是 v1.4「一筆帳目對一位成員個人餘額的影響」的唯一實作：私人筆、未結算代墊、
-- 已結算份額（最大餘數法）三段。v1.5 只剩「payer_id = 該成員的支出」一段條件，
-- 一個 where 子句就寫完，view 沒有存在價值（ADR-0009 後果節的「縮成先付一項」）。
-- 必須排在 drop column／drop table 之前：view 對 entries.scope、entries.settled_state、
-- entry_splits 都有真正的 catalog 依賴。
drop view public.entry_member_effects;

-- ---------- 1e. drop 函式（第一批：必須在 drop table 之前） ----------
-- 這三支的**回傳型別**是 public.settlements（表的複合型別），對表有 catalog 依賴：
-- 表還在時它們擋不住 drop table，但 drop table 會因為「function ... depends on type settlements」
-- 而失敗（實測 SQLSTATE 2BP01）。所以順序是：先這批函式 → 再表 → 再表的 trigger 函式。
--   initiate_settlement／approve_settlement／cancel_settlement — 多簽結算的三個入口（決策 3 廢止）
drop function public.initiate_settlement(uuid);
drop function public.approve_settlement(uuid);
drop function public.cancel_settlement(uuid);

-- 同一批：與表沒有型別依賴、也已經沒有 trigger 指著它們的函式。
--   required_signers／required_signers_internal — 需簽者名單（隨多簽廢止）
--   void_settlements_for_entry                 — settling 期間打掉結算的內部函式
--   entries_lock_settled                       — 已結算鎖 amount／payer／split_method／scope／kind／occurred_on
--   entries_void_pending_settlement            — settling 期間改實質欄位 → 結算 void
--   entries_before_delete                      — settled 不可刪 ＋ 刪 settling 筆時先 void 結算
--   entries_split_sum_check                    — entries 側 deferred 守恆（Σshare ＝ amount）
--   entries_force_open_on_insert               — 新帳目強制 settled_state='open'
--   topup_for                                  — v1.4「每月自動補入額適不適用」的判準（決策 2 改手動）
--   upsert_entry(jsonb,jsonb,jsonb)            — 帶 p_splits 的三參數版（第 5 節換兩參數版）
--     必須真的 drop 而不是留著：新版是 upsert_entry(jsonb, jsonb default null)，
--     兩者並存時 upsert_entry(a, b) 會是 ambiguous function call。
drop function public.required_signers(uuid);
drop function public.required_signers_internal(uuid);
drop function public.void_settlements_for_entry(uuid);
drop function public.entries_lock_settled();
drop function public.entries_void_pending_settlement();
drop function public.entries_before_delete();
drop function public.entries_split_sum_check();
drop function public.entries_force_open_on_insert();
drop function public.topup_for(int, timestamptz, date);
drop function public.upsert_entry(jsonb, jsonb, jsonb);

-- ---------- 1f. drop 結算四表與分攤表（ADR-0009 決策 3） ----------
-- settlement_approvals — 簽名
-- settlement_signers   — 需簽者快照
-- settlement_entries   — 一次結算涵蓋哪些帳目
-- settlements          — 結算本體（status／nets）
-- entry_splits         — 逐筆分攤
-- 順序由子到父，避免 FK 擋住。它們身上的 RLS policy、grant、index、trigger 隨表一起消失，
-- supabase_realtime publication 也會自動移除 settlements（publication 成員是 catalog 依賴）。
drop table public.settlement_approvals;
drop table public.settlement_signers;
drop table public.settlement_entries;
drop table public.settlements;
drop table public.entry_splits;

-- ---------- 1g. drop 函式（第二批：這些是剛剛那五張表的 trigger 函式） ----------
-- 表還在時 drop 不掉——trigger 對函式有 pg_depend 依賴，會被
-- 「cannot drop function ... because other objects depend on it」擋下來。
--   settlement_finalize_on_approval — 簽名到齊 → settlement settled、涵蓋 entries settled
--   settlements_status_machine      — 結算狀態機（終態不可改、nets 不可變）
--   settlement_approvals_guard      — 簽名只收快照名單內的人、只在 pending 期間
--   settlement_entries_same_ledger  — 結算涵蓋的帳目必須同帳本
--   entry_splits_lock_settled／entry_splits_lock_settled_delete — settled 的分攤不可改不可刪
--   entry_splits_void_pending_settlement                        — 改分攤 → 結算 void
--   entry_splits_sum_check                                      — 分攤側 deferred 守恆
--   entry_splits_same_ledger                                    — 分攤成員必須同帳本
drop function public.settlement_finalize_on_approval();
drop function public.settlements_status_machine();
drop function public.settlement_approvals_guard();
drop function public.settlement_entries_same_ledger();
drop function public.entry_splits_lock_settled();
drop function public.entry_splits_lock_settled_delete();
drop function public.entry_splits_void_pending_settlement();
drop function public.entry_splits_sum_check();
drop function public.entry_splits_same_ledger();

-- ---------- 1h. drop 欄位（ADR-0009 決策 1／2／3） ----------
-- entries.scope         — 私人／共同範圍（決策 1 整個廢掉）
-- entries.split_method  — 逐筆分攤方式（決策 3）
-- entries.settled_state — 結算狀態機（決策 3）
--   隨這三欄一起消失的：check entries_private_payer／entries_private_no_split／entries_private_open、
--   index entries_settle_idx、欄位級 insert／update 授權。
alter table public.entries drop column scope;
alter table public.entries drop column split_method;
alter table public.entries drop column settled_state;

-- ledgers.default_ratio          — 分攤預設比例（決策 3，沒有分攤就沒有比例）
-- ledgers.opening_balance_shared — 共同期初餘額（決策 4：共同餘額無期初）
alter table public.ledgers drop column default_ratio;
alter table public.ledgers drop column opening_balance_shared;

-- members.monthly_topup             — v1.4 的每月自動補入額（決策 2 改手動記 personal_topups）
--   隨欄位消失：check members_monthly_topup_range。
-- members.opening_balance_personal  — v1.3 的個人期初餘額，v1.4 起已不進任何公式，決策 7 直接 drop 不轉換
alter table public.members drop column monthly_topup;
alter table public.members drop column opening_balance_personal;

-- ---------- 1i. drop enum（ADR-0009 決策 1／3） ----------
-- 四個 enum 的最後一個使用者都在上面被 drop 掉了，留著只會讓人以為還有語意。
drop type public.entry_scope;
drop type public.split_method;
drop type public.settled_state;
drop type public.settlement_status;

-- 註：archive.budget_allocation_v13（0027 的 v1.3 撥款流水快照）刻意**不動**——
-- 它是遷移可逆性的憑據，與 v1.5 的規則無關，而且前端本來就進不去 archive schema。

-- ============================================================================
-- ==== 不可逆結束 ====
-- 以下都是新增／重建，重跑不會再毀資料。
-- ============================================================================

-- ---------- 2. entries ----------
-- 收入只有「共同收入」，一律進共同餘額，沒有付款人（spec v1.5 領域模型：kind=income 恆 null）。
-- 為什麼是 check 而不是靠 RPC：payer_id 是欄位級可寫的，前端可以不經 upsert_entry 直接 insert。
alter table public.entries
  add constraint entries_income_no_payer
  check (kind <> 'income' or payer_id is null);

-- RLS 回到「同帳本成員全部可見」（ADR-0009 決策 1）。
-- insert 仍限「以自己的名義記帳」；update／delete 不再有 settled 鎖，只剩鎖月
--（a_entries_month_closed_trg，0027 建立、本支保留）。
create policy entries_select on public.entries
  for select to authenticated
  using (public.is_member(ledger_id));

create policy entries_insert on public.entries
  for insert to authenticated
  with check (
    public.is_member(ledger_id)
    and created_by = public.my_member_id(ledger_id)
  );

create policy entries_update on public.entries
  for update to authenticated
  using (public.is_member(ledger_id))
  with check (public.is_member(ledger_id));

create policy entries_delete on public.entries
  for delete to authenticated
  using (public.is_member(ledger_id));

-- line_items 的可見性與寫入權跟隨父 entry（條件與上面逐字相同）。
create policy line_items_select on public.line_items
  for select to authenticated
  using (exists (select 1 from public.entries e
                 where e.id = entry_id and public.is_member(e.ledger_id)));
create policy line_items_insert on public.line_items
  for insert to authenticated
  with check (exists (select 1 from public.entries e
                      where e.id = entry_id and public.is_member(e.ledger_id)));
create policy line_items_update on public.line_items
  for update to authenticated
  using (exists (select 1 from public.entries e
                 where e.id = entry_id and public.is_member(e.ledger_id)))
  with check (exists (select 1 from public.entries e
                      where e.id = entry_id and public.is_member(e.ledger_id)));
create policy line_items_delete on public.line_items
  for delete to authenticated
  using (exists (select 1 from public.entries e
                 where e.id = entry_id and public.is_member(e.ledger_id)));

-- 欄位級授權依剩下的欄位重發（0018 的慣例）。
-- drop column 已經把 scope／split_method 從授權清單裡帶走，這裡明寫一次是為了
-- 「授權清單＝可寫欄位清單」這件事在檔案裡看得到，不必回頭推導 0018 減去 1h。
-- id／created_at／created_by（update 時）／ledger_id（update 時）／settled_state（已不存在）一律不給。
revoke insert, update on public.entries from authenticated;
grant insert (
  ledger_id, kind, amount, category_id, occurred_on, note,
  created_by, payer_id, is_adjustment
) on public.entries to authenticated;
grant update (
  kind, amount, category_id, occurred_on, note,
  payer_id, is_adjustment
) on public.entries to authenticated;

-- ---------- 3. personal_topups（ADR-0009 決策 2） ----------
-- 每人每月自己按「補入」記金額，可多筆、可備註；未清月可刪，已清月鎖定。
-- 「個人補入剩餘」＝ Σ該月補入 − Σ該月本人先付的支出，這張表是前半段的唯一來源。
create table public.personal_topups (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete restrict,
  -- 0 與負數都無意義：補入是「把錢預留出來」，退回請刪掉那一列。
  amount int not null constraint personal_topups_amount_positive check (amount > 0),
  occurred_on date not null,
  -- 由 occurred_on 推導的月初（比照 budget_allocation.month，0027 的 3b）。
  -- date_trunc(text, timestamp) 是 immutable（timestamptz 版才不是），所以先轉 timestamp。
  month date generated always as ((date_trunc('month', occurred_on::timestamp))::date) stored,
  note text not null default '',
  created_by uuid not null references public.members (id) on delete restrict,
  created_at timestamptz not null default now()
);

-- 跨帳本：照 0014／0024 的慣例用複合 FK（被參照的 (id, ledger_id) 唯一鍵已存在），
-- 綁死「補入的成員與記錄者都屬於這一本帳」。單欄 FK 保留（複合比較嚴，兩者並存不衝突）。
alter table public.personal_topups
  add constraint personal_topups_member_same_ledger
  foreign key (member_id, ledger_id) references public.members (id, ledger_id) on delete restrict;
alter table public.personal_topups
  add constraint personal_topups_created_by_same_ledger
  foreign key (created_by, ledger_id) references public.members (id, ledger_id) on delete restrict;

create index personal_topups_ledger_occurred_idx on public.personal_topups (ledger_id, occurred_on);
create index personal_topups_member_idx on public.personal_topups (member_id);
-- 熱查詢的形狀：預算頁與清帳明細問的都是「這本帳、這個人、這個月的補入」
-- （month_summary 的 per CTE、month_close_details 的 calc CTE 都是這三欄），
-- 上面兩支索引任一支都要多掃一輪才篩得完。
create index personal_topups_ledger_member_month_idx
  on public.personal_topups (ledger_id, member_id, month);

alter table public.personal_topups enable row level security;

-- select：同帳本成員都看得到彼此的補入與剩餘（spec「兩人都看得到」）。
create policy personal_topups_select on public.personal_topups
  for select to authenticated
  using (public.is_member(ledger_id));

-- insert：只能補自己的，也只能以自己的名義記（my_member_id 對非成員回 null，
-- null 比較的結果是 null＝不通過，所以非成員自然被擋）。
create policy personal_topups_insert on public.personal_topups
  for insert to authenticated
  with check (
    member_id = public.my_member_id(ledger_id)
    and created_by = public.my_member_id(ledger_id)
  );

-- delete：只能刪自己的。
create policy personal_topups_delete on public.personal_topups
  for delete to authenticated
  using (member_id = public.my_member_id(ledger_id));

-- **刻意沒有 update policy 也沒有 update 授權**：補入是一筆一筆的事實紀錄，
-- 要改就刪了重記（少一條路徑，就少一種「改到別人那列」的可能）。
-- INSERT 走**欄位級**（比照 entries 的 0018 與 budget_allocation 的 0024）：
-- id 與 created_at 不給前端填——整表授權的話前端可以自己指定 id 與時間戳，
-- 那是「補入是哪一刻記的」這件事的唯一來源。month 是 generated 欄，本來就寫不了。
grant select, delete on public.personal_topups to authenticated;
grant insert (ledger_id, member_id, amount, occurred_on, note, created_by)
  on public.personal_topups to authenticated;

-- 鎖月：已清帳月份的補入不可新增、修改、刪除（spec「已清帳月份」節）。
-- 訊息**複用 `raise_if_month_closed`**（`month closed: YYYY-MM`），與帳目、細項、預算完全一致：
-- 四張表同一句話、同一個判準，前端只要一條 `startsWith('month closed:')` 就對映得完，
-- 也不必為了「這次是補入還是帳目」再分一次支。訊息帶的是**被擋的那筆所屬的月**。
create or replace function public.personal_topups_month_closed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- update／delete 看舊列那個月（把補入搬出鎖定範圍也要擋）。
  -- 注意不能用 NEW.month／OLD.month——generated 欄位是在 BEFORE trigger **之後**才算出來的
  -- （同 0027 對 budget_allocation 的註記）。
  if TG_OP <> 'INSERT' then
    perform public.raise_if_month_closed(
      OLD.ledger_id, (date_trunc('month', OLD.occurred_on::timestamp))::date);
  end if;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;

  -- insert／update 看新列那個月（補記到鎖定範圍裡也要擋）。
  perform public.raise_if_month_closed(
    NEW.ledger_id, (date_trunc('month', NEW.occurred_on::timestamp))::date);
  return NEW;
end;
$$;
revoke execute on function public.personal_topups_month_closed() from anon, authenticated, public;

-- trigger 依名稱字母序執行，鎖月一律用 `a_` 開頭（0027 的慣例）。
create trigger a_personal_topups_month_closed_trg
  before insert or update or delete on public.personal_topups
  for each row execute function public.personal_topups_month_closed();

-- ---------- 4. ledgers／members 欄位級授權重發 ----------
-- 0022 開的是 ledgers(name, default_ratio, opening_balance_shared) 與
-- members(display_name, opening_balance_personal)；1h 把其中四欄 drop 掉了，
-- 這裡把剩下的明寫一次（同 2 節的理由：授權清單要在檔案裡看得到）。
-- invite_code 依舊不給寫——輪替走 rotate_invite_code。
revoke update on public.ledgers from authenticated;
grant update (name) on public.ledgers to authenticated;

revoke update on public.members from authenticated;
grant update (display_name) on public.members to authenticated;

-- ---------- 5. upsert_entry（去 splits，兩參數） ----------
-- 語意與 v1.4 相同，只是少了 p_splits：
--   p_line_items null（或省略）＝完全不動細項；[] ＝清空；有內容 ＝全刪重建。
--   p_entry.id 空或缺 ＝ 新增，否則更新。
-- security invoker：RLS 與欄位級授權照常生效，這支只提供「同一交易寫完主筆與細項」的原子性。
-- 全刪重建後比對 row_count（0022 的 Q）：RLS 把某些子表列濾掉時，
-- 靜默掉資料比直接 raise 難查太多。
create or replace function public.upsert_entry(
  p_entry jsonb,
  p_line_items jsonb default null
)
returns public.entries
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid := nullif(p_entry ->> 'id', '')::uuid;
  v_ledger uuid := nullif(p_entry ->> 'ledger_id', '')::uuid;
  v_me uuid;
  v_entry public.entries;
  v_expected int;
  v_deleted int;
begin
  if auth.uid() is null then
    raise exception 'upsert_entry: not authenticated' using errcode = '28000';
  end if;
  if v_ledger is null then
    raise exception 'upsert_entry: ledger_id required' using errcode = 'P0001';
  end if;
  v_me := public.my_member_id(v_ledger);
  if v_me is null then
    raise exception 'upsert_entry: not a member' using errcode = '42501';
  end if;

  if v_id is null then
    insert into public.entries (
      ledger_id, kind, amount, category_id, occurred_on, note,
      created_by, payer_id, is_adjustment
    ) values (
      v_ledger,
      (p_entry ->> 'kind')::public.entry_kind,
      (p_entry ->> 'amount')::int,
      (p_entry ->> 'category_id')::uuid,
      (p_entry ->> 'occurred_on')::date,
      coalesce(p_entry ->> 'note', ''),
      v_me,
      nullif(p_entry ->> 'payer_id', '')::uuid,
      coalesce((p_entry ->> 'is_adjustment')::boolean, false)
    )
    returning * into v_entry;
  else
    update public.entries e set
      kind          = coalesce((p_entry ->> 'kind')::public.entry_kind, e.kind),
      amount        = coalesce((p_entry ->> 'amount')::int, e.amount),
      category_id   = coalesce(nullif(p_entry ->> 'category_id', '')::uuid, e.category_id),
      occurred_on   = coalesce((p_entry ->> 'occurred_on')::date, e.occurred_on),
      note          = coalesce(p_entry ->> 'note', e.note),
      payer_id      = case when p_entry ? 'payer_id' then nullif(p_entry ->> 'payer_id', '')::uuid else e.payer_id end,
      is_adjustment = coalesce((p_entry ->> 'is_adjustment')::boolean, e.is_adjustment)
    where e.id = v_id
    returning * into v_entry;
    if not found then
      raise exception 'upsert_entry: entry not found or not visible' using errcode = 'P0001';
    end if;
  end if;

  if p_line_items is not null then
    select count(*) into v_expected from public.line_items li where li.entry_id = v_entry.id;
    delete from public.line_items where entry_id = v_entry.id;
    get diagnostics v_deleted = row_count;
    if v_deleted <> v_expected then
      raise exception 'upsert_entry: could not replace line items (% of % rows deleted)', v_deleted, v_expected
        using errcode = '42501';
    end if;
    insert into public.line_items (entry_id, name, amount, sort)
    select v_entry.id, x ->> 'name', nullif(x ->> 'amount', '')::int, coalesce((x ->> 'sort')::int, 0)
    from jsonb_array_elements(p_line_items) x;
  end if;

  select * into v_entry from public.entries e where e.id = v_entry.id;
  return v_entry;
end;
$$;

revoke execute on function public.upsert_entry(jsonb, jsonb) from anon, public;
grant execute on function public.upsert_entry(jsonb, jsonb) to authenticated;

-- 註：search_items 不必改。它從 0004 起就沒有 scope 條件，可見性一直是靠 entries 的
-- RLS policy 決定；第 2 節把那條 policy 放寬成「同帳本全可見」之後，搜尋自動變成 v1.5 語意。

-- ---------- 6. create_ledger／join_ledger 去 default_ratio ----------
-- 0017／0004 的活定義原樣複製，只拿掉對 default_ratio 的寫入（欄位已在 1h drop）。
-- display_name 的預設邏輯（full_name → email 前綴 → '我'／'成員'）一字不改。
create or replace function public.create_ledger(name text)
returns public.ledgers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ledger public.ledgers;
  v_display text;
  v_try int := 0;
begin
  if v_uid is null then
    raise exception 'create_ledger: not authenticated' using errcode = '28000';
  end if;
  if name is null or btrim(name) = '' then
    raise exception 'create_ledger: name required' using errcode = 'P0001';
  end if;

  select coalesce(
           nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
           nullif(split_part(u.email, '@', 1), ''),
           '我'
         )
    into v_display
  from auth.users u
  where u.id = v_uid;

  -- 邀請碼撞 unique 就重抽（10 碼下幾乎不會發生，但併發時不該讓使用者看到 500）。
  loop
    v_try := v_try + 1;
    begin
      insert into public.ledgers (name) values (btrim(name)) returning * into v_ledger;
      exit;
    exception when unique_violation then
      if v_try >= 5 then
        raise exception 'create_ledger: could not allocate an invite code' using errcode = 'P0001';
      end if;
    end;
  end loop;

  insert into public.members (ledger_id, user_id, display_name)
  values (v_ledger.id, v_uid, coalesce(v_display, '我'));

  insert into public.categories (ledger_id, kind, name, icon, sort) values
    (v_ledger.id, 'expense', '食品',     'restaurant',     0),
    (v_ledger.id, 'expense', '餐飲',     'local_dining',   1),
    (v_ledger.id, 'expense', '日常用品', 'inventory_2',    2),
    (v_ledger.id, 'expense', '住房',     'home',           3),
    (v_ledger.id, 'expense', '水電',     'bolt',           4),
    (v_ledger.id, 'expense', '交通',     'directions_car', 5),
    (v_ledger.id, 'expense', '娛樂',     'sports_esports', 6),
    (v_ledger.id, 'income',  '薪水',     'payments',       0),
    (v_ledger.id, 'income',  '獎金',     'card_giftcard',  1);

  return v_ledger;
end;
$$;
revoke execute on function public.create_ledger(text) from anon, public;
grant execute on function public.create_ledger(text) to authenticated;

create or replace function public.join_ledger(code text)
returns public.ledgers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ledger public.ledgers;
  v_display text;
begin
  if v_uid is null then
    raise exception 'join_ledger: not authenticated' using errcode = '28000';
  end if;
  if code is null or btrim(code) = '' then
    raise exception 'join_ledger: code required' using errcode = 'P0001';
  end if;

  select * into v_ledger from public.ledgers l where l.invite_code = upper(btrim(code));
  if not found then
    raise exception 'join_ledger: invalid invite code' using errcode = 'P0001';
  end if;

  -- 已是成員直接回。
  if exists (select 1 from public.members m where m.ledger_id = v_ledger.id and m.user_id = v_uid) then
    return v_ledger;
  end if;

  select coalesce(
           nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
           nullif(split_part(u.email, '@', 1), ''),
           '成員'
         )
    into v_display
  from auth.users u
  where u.id = v_uid;

  insert into public.members (ledger_id, user_id, display_name)
  values (v_ledger.id, v_uid, coalesce(v_display, '成員'));

  return v_ledger;
end;
$$;
revoke execute on function public.join_ledger(text) from anon, public;
grant execute on function public.join_ledger(text) to authenticated;

-- ---------- 7. month_closes.income_entry_id ----------
-- 清帳勾了「一鍵記共同收入」時記下的那一筆收入（spec「清帳」節）。
-- on delete set null 而不是 restrict：那筆收入是普通收入（可沖銷），
-- 而清帳紀錄本身不該因為收入被動過就消失或卡住。
alter table public.month_closes
  add column income_entry_id uuid references public.entries (id) on delete set null;

-- ---------- 7b. 鎖月檢查取共享鎖（與 close_month 的排他鎖成對） ----------
-- 修的是一個真的會發生的競態（security ＋ db review 同報）：
--   T1  A 呼叫 close_month，取排他 advisory lock，算好 details 快照（此時上月還沒有 month_closes 列）
--   T2  B 在同一瞬間補記一筆上月的帳目：raise_if_month_closed 讀 month_closes 看不到任何列 → 放行
--   T3  A 寫入 month_closes、commit
--   結果：B 那筆錢**沒被算進快照**，但它所屬的月份立刻被鎖死——改不掉、刪不掉、也永遠不會再被清一次。
-- 根因是 raise_if_month_closed 只是一個 READ COMMITTED 的 select，不參與 close_month 的序列化。
-- 修法：把它拉進同一把鎖——用**共享**鎖，寫入之間彼此不互斥（記帳照樣可以並行），
-- 只有 close_month 的排他鎖擋得住它們；反之 close_month 也必須等在途的寫入 commit。
-- key 與 close_month 逐字相同：hashtextextended(p_ledger::text, 0)。
--
-- 同一交易內先排他、後共享是安全的：close_month 自己記那筆「清帳轉入」收入時會觸發這支，
-- 而 lock manager 對「同一交易已持有的鎖」不視為衝突，直接授予。
--
-- volatile（0027 是 stable）：取鎖有副作用，繼續標 stable 是在騙 planner。
-- 它只被四支 BEFORE trigger 呼叫，volatile 不影響任何查詢計畫。
create or replace function public.raise_if_month_closed(p_ledger uuid, p_month date)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_last date;
begin
  perform pg_advisory_xact_lock_shared(hashtextextended(p_ledger::text, 0));

  select max(mc.month) into v_last
  from public.month_closes mc where mc.ledger_id = p_ledger;

  if v_last is not null and p_month <= v_last then
    -- 訊息帶「被擋的那個月」，不是最後清帳月：使用者要看到的是自己動到的那筆屬於哪個月。
    raise exception 'month closed: %', to_char(p_month, 'YYYY-MM') using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function public.raise_if_month_closed(uuid, date) from anon, authenticated, public;

-- ---------- 8. 清帳 ----------
-- 8a. 明細：預覽與落地快照共用同一段 SQL（spec「明細（預覽與紀錄同一份）」）。
-- security definer：要算**每一位**成員的補入與先付。v1.5 的 RLS 已經是同帳本全可見，
-- 用 invoker 也算得出來，但保留 definer 有兩個理由：
--   (1) 它是內部 helper（沒有 grant 給任何前端角色），definer 讓它與呼叫者的 RLS 脫鉤，
--       日後 RLS 再收緊也不會讓清帳明細悄悄少一列；
--   (2) close_month 是 definer，兩者身分一致比較好推理。
--
-- 成員 M 在月 m：
--   topup ＝ Σ personal_topups(member_id = M, month = m)
--   paid  ＝ Σ entries(kind = 'expense', payer_id = M, 該月)      ← 沖銷筆是負 amount，自然流過同一條
--   ending ＝ topup − paid（> 0 應轉入共同帳戶、< 0 共同帳戶應補、= 0 免處理）
-- shared_paid ＝ Σ entries(kind = 'expense', payer_id is null, 該月)，僅供對照。
create or replace function public.month_close_details(p_ledger uuid, p_month date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with mem as (
  select m.id, m.display_name, m.joined_at
  from public.members m
  where m.ledger_id = p_ledger
),
calc as (
  select m.id,
         m.display_name,
         m.joined_at,
         coalesce((select sum(t.amount)
                     from public.personal_topups t
                    where t.ledger_id = p_ledger
                      and t.member_id = m.id
                      and t.month = p_month), 0)::bigint as topup,
         coalesce((select sum(e.amount)
                     from public.entries e
                    where e.ledger_id = p_ledger
                      and e.kind = 'expense'
                      and e.payer_id = m.id
                      and (date_trunc('month', e.occurred_on::timestamp))::date = p_month), 0)::bigint as paid
  from mem m
),
sp as (
  select coalesce(sum(e.amount), 0)::bigint as shared_paid
  from public.entries e
  where e.ledger_id = p_ledger
    and e.kind = 'expense'
    and e.payer_id is null
    and (date_trunc('month', e.occurred_on::timestamp))::date = p_month
)
select jsonb_build_object(
  'month', to_char(p_month, 'YYYY-MM-DD'),
  'members', coalesce((
    select jsonb_agg(jsonb_build_object(
             'member_id', c.id,
             'display_name', c.display_name,
             -- 三個數字一律 bigint：單筆 amount 是 int，但一個月加起來可以輕鬆越過 int 上界；
             -- 轉 int 等於把「算得出來」變成「整支 RPC 炸掉」，而清帳不可撤銷，最不該在這裡炸。
             'topup', c.topup,
             'paid', c.paid,
             'ending', c.topup - c.paid)
           order by c.joined_at, c.id)
    from calc c), '[]'::jsonb),
  'shared_paid', (select shared_paid from sp)
);
$$;
revoke execute on function public.month_close_details(uuid, date) from anon, authenticated, public;

-- 8b. 可清條件（spec「可清條件」＋ brief 的五條訊息，順序由上而下）。
-- preview 與 close_month 共用這一段，訊息逐字相同。
-- 「已清過」必須排在「順序」之前：清過的月份一定不等於下一個可清月，
-- 排在後面的話重清同月會拿到 "must close … first"，而不是看得懂的 "already closed"。
-- v1.4 的第 6 條（該月有未結算代墊）隨結算一起消失（ADR-0009 決策 3）。
create or replace function public.month_close_guard(p_ledger uuid, p_month date)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cur date := public.taipei_month(now());
  v_next date;
begin
  if p_month is null or p_month <> (date_trunc('month', p_month::timestamp))::date then
    raise exception 'close_month: month must be first day' using errcode = 'P0001';
  end if;

  if p_month >= v_cur then
    raise exception 'close_month: month not ended' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.month_closes mc
              where mc.ledger_id = p_ledger and mc.month = p_month) then
    raise exception 'close_month: already closed' using errcode = 'P0001';
  end if;

  -- 下一個可清月：清過就是「上次 ＋ 1 月」，沒清過就是「最早有成員、有帳目或有補入的那個月」。
  -- least() 會忽略 null，三個來源任一為空都不影響。
  select (max(mc.month) + interval '1 month')::date into v_next
  from public.month_closes mc where mc.ledger_id = p_ledger;
  if v_next is null then
    select least(
      (select min(public.taipei_month(m.joined_at))
         from public.members m where m.ledger_id = p_ledger),
      (select min((date_trunc('month', e.occurred_on::timestamp))::date)
         from public.entries e where e.ledger_id = p_ledger),
      (select min(t.month)
         from public.personal_topups t where t.ledger_id = p_ledger)
    ) into v_next;
  end if;

  if v_next is null or v_next >= v_cur then
    raise exception 'close_month: nothing to close' using errcode = 'P0001';
  end if;
  if p_month <> v_next then
    raise exception 'close_month: must close % first', to_char(v_next, 'YYYY-MM')
      using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function public.month_close_guard(uuid, date) from anon, authenticated, public;

-- 8c. income_amount 的唯一實作：preview 與 close_month 都讀這一支，
-- 兩邊各寫一遍的話「預覽說會記 12,000、實際記了別的數」是遲早的事，而那是錢。
create or replace function public.month_close_income_amount(p_details jsonb)
returns bigint
language sql
immutable
set search_path = public
as $$
  select greatest(0, coalesce((
    select sum((m ->> 'ending')::bigint)
    from jsonb_array_elements(p_details -> 'members') m), 0));
$$;
revoke execute on function public.month_close_income_amount(jsonb) from anon, authenticated, public;

-- 8d. 預覽：可清條件不過就 raise 對應訊息，過了回明細 ＋ income_amount。
-- income_amount ＝ Σ ending（＝Σ應轉入 − Σ應補出），≤ 0 回 0；勾選「一鍵記共同收入」時記的就是這個數。
-- v1.4 的 warnings 鍵隨分攤一起消失（沒有「沒有分攤列的拆帳筆」這種東西了）。
create or replace function public.month_close_preview(p_ledger uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_details jsonb;
begin
  if auth.uid() is null then
    raise exception 'month_close_preview: not authenticated' using errcode = '28000';
  end if;
  if public.my_member_id(p_ledger) is null then
    raise exception 'month_close_preview: not a member' using errcode = '42501';
  end if;

  perform public.month_close_guard(p_ledger, p_month);

  v_details := public.month_close_details(p_ledger, p_month);
  return v_details || jsonb_build_object(
    'income_amount', public.month_close_income_amount(v_details));
end;
$$;
revoke execute on function public.month_close_preview(uuid, date) from anon, public;
grant execute on function public.month_close_preview(uuid, date) to authenticated;

-- 8e. 執行：任一成員可清、不需多簽、不可撤銷（ADR-0009 決策 4）。
create or replace function public.close_month(
  p_ledger uuid,
  p_month date,
  p_record_income boolean default true
)
returns public.month_closes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid;
  v_details jsonb;
  v_income bigint;
  v_category uuid;
  v_entry uuid;
  v_row public.month_closes;
begin
  if auth.uid() is null then
    raise exception 'close_month: not authenticated' using errcode = '28000';
  end if;
  -- 明文成員檢查：不能靠「closed_by 是 NOT NULL、非成員填不出來」這種巧合擋
  -- （那樣非成員拿到的會是 not-null violation 或 guard 的無關訊息）。
  v_me := public.my_member_id(p_ledger);
  if v_me is null then
    raise exception 'close_month: not a member' using errcode = '42501';
  end if;

  -- 同一帳本序列化，兩個人同時按「清帳」不會各清一次。
  perform pg_advisory_xact_lock(hashtextextended(p_ledger::text, 0));

  perform public.month_close_guard(p_ledger, p_month);

  v_details := public.month_close_details(p_ledger, p_month);
  v_income := public.month_close_income_amount(v_details);

  -- 一鍵記共同收入（spec「清帳」節）：金額 ≤ 0 就不記，即使勾了也一樣。
  -- **順序很重要**：收入筆必須在 month_closes 之前 insert。
  -- 反過來的話 a_entries_month_closed_trg 會看到「這個月已經清了」而擋掉自己剛要記的那筆。
  if p_record_income and v_income > 0 then
    -- 分類「清帳轉入」：帳本沒有就自動建一個 income 分類，排在現有 income 分類之後。
    select c.id into v_category
    from public.categories c
    where c.ledger_id = p_ledger and c.kind = 'income' and c.name = '清帳轉入'
    order by c.sort, c.id
    limit 1;

    if v_category is null then
      insert into public.categories (ledger_id, kind, name, icon, sort)
      values (p_ledger, 'income', '清帳轉入', 'savings',
              coalesce((select max(c.sort) + 1 from public.categories c
                         where c.ledger_id = p_ledger and c.kind = 'income'), 0))
      returning id into v_category;
    end if;

    -- 明細一路 bigint，但**落地受 entries.amount 的 int 上界所限**。
    -- 直接 cast 會拋 `integer out of range`，看不出是清帳金額爆掉還是別的地方；
    -- 這裡先擋一道，訊息講清楚是哪一件事（清帳不可撤銷，最不該在這裡丟看不懂的錯）。
    if v_income > 2147483647 then
      raise exception 'close_month: income amount exceeds limit' using errcode = 'P0001';
    end if;

    insert into public.entries (
      ledger_id, kind, amount, category_id, occurred_on, note,
      created_by, payer_id, is_adjustment
    ) values (
      p_ledger,
      'income',
      v_income::int,
      v_category,
      (p_month + interval '1 month - 1 day')::date,
      format('%s／%s 清帳', to_char(p_month, 'YYYY'), to_char(p_month, 'MM')),
      v_me,
      null,
      false
    )
    returning id into v_entry;
  end if;

  insert into public.month_closes (ledger_id, month, closed_by, details, income_entry_id)
  values (p_ledger, p_month, v_me, v_details, v_entry)
  returning * into v_row;

  return v_row;
end;
$$;
revoke execute on function public.close_month(uuid, date, boolean) from anon, public;
grant execute on function public.close_month(uuid, date, boolean) to authenticated;

-- 0027 的兩參數版必須 drop：留著的話 close_month(l, m) 會是 ambiguous，
-- 而且它算的是 v1.4 的舊公式、也不會寫 income_entry_id。
drop function public.close_month(uuid, date);

-- ---------- 9. month_summary 依 v1.5 公式重寫 ----------
-- 輸出（v1.4 的 me 鍵移除，改為全體成員的 members 陣列 ＋ shared_paid）：
--   { shared_balance, budget_total, spent_total, overspend_total,
--     categories: [{category_id, allocated, spent, remaining, over}],
--     members:    [{member_id, display_name, topup, paid, remaining}],
--     shared_paid }
--
--   shared_balance ＝ Σ共同收入 − Σ共同錢包支出（payer_id is null），occurred_on <= until，**無期初**。
--   allocated ＝ 該分類 until 所在月的那一筆預算（0 或 1 筆），**刻意不篩 occurred_on**：
--     預算是當月的影子紀錄，設定當下就對整個月生效。spent 則相反，逐筆累加所以有 occurred_on <= until。
--   spent ＝ 該分類該月**全部**支出（不分 payer：成員先付與共同錢包都算，ADR-0009 三個數表）。
--   members[*].topup／paid ＝ until 所在**整月**的補入與先付（**不夾 until 當日**）；
--     remaining ＝ topup − paid，**可為負**。
--   shared_paid ＝ until 所在整月 payer_id is null 的支出合計（對照用，與清帳明細同口徑、同樣不夾當日）。
--
-- 已清月照樣由帳目算，不再回 0：已清月的資料被鎖月 trigger 鎖死，與 month_closes.details
-- 的快照必然相等，兩條路算出同一個數，前端讀哪一份都行。
-- p_until **不夾上界**（前端月份切換沒有上界，下個月的預算是合法的、可以先設）；
-- p_until 為 null ＝ 問到本月底。
-- 仍是 security invoker：非成員被 RLS 濾成空集，拿到的是一組 0。
create or replace function public.month_summary(p_ledger uuid, p_until date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_until date := coalesce(
    p_until,
    (public.taipei_month(now()) + interval '1 month - 1 day')::date);
  -- 使用者要看的那個月——allocated／spent／categories／members 全都照這個月算。
  v_month date := (date_trunc('month', v_until::timestamp))::date;
begin
  return (
    with sb as (
      -- 加總一律 bigint：單筆 amount 是 int，但加起來越得過 int 上界，
      -- 屆時會回 integer out of range 而不是數字。
      select coalesce(sum(case
               when kind = 'income' then amount
               when payer_id is null then -amount
               else 0 end), 0)::bigint as shared_balance
      from entries
      where ledger_id = p_ledger and occurred_on <= v_until
    ),
    alloc as (
      select category_id, amount::int as allocated
      from budget_allocation
      where ledger_id = p_ledger and month = v_month
    ),
    spent as (
      select category_id, sum(amount)::bigint as spent
      from entries
      where ledger_id = p_ledger and kind = 'expense'
        and (date_trunc('month', occurred_on::timestamp))::date = v_month
        and occurred_on <= v_until
      group by category_id
    ),
    env as (
      select coalesce(a.category_id, s.category_id) as category_id,
             coalesce(a.allocated, 0) as allocated,
             coalesce(s.spent, 0) as spent,
             greatest(0, coalesce(a.allocated, 0) - coalesce(s.spent, 0)) as remaining,
             greatest(0, coalesce(s.spent, 0) - coalesce(a.allocated, 0)) as over
      from alloc a
      full outer join spent s using (category_id)
    ),
    mem as (
      select m.id, m.display_name, m.joined_at
      from members m
      where m.ledger_id = p_ledger
    ),
    per as (
      select m.id,
             m.display_name,
             m.joined_at,
             -- **整月，不夾 p_until 當日**（spec 的口徑是「每人每月」）：
             -- 補入剩餘是一個月結算一次的數，月中查詢不該看到「還沒發生的先付」被切掉一半——
             -- 那會讓預算頁在月中顯示的剩餘比實際多，也會與 month_closes.details 的快照對不起來。
             -- shared_balance／spent_total／categories 則相反，維持 occurred_on <= until 的累計口徑。
             coalesce((select sum(t.amount) from personal_topups t
                        where t.ledger_id = p_ledger
                          and t.member_id = m.id
                          and t.month = v_month), 0)::bigint as topup,
             -- 沖銷筆是負 amount，自然流過同一條 sum（漏掉它，先付會虛高、剩餘會虛低）。
             coalesce((select sum(e.amount) from entries e
                        where e.ledger_id = p_ledger
                          and e.kind = 'expense'
                          and e.payer_id = m.id
                          and (date_trunc('month', e.occurred_on::timestamp))::date = v_month), 0)::bigint as paid
      from mem m
    ),
    sp as (
      -- 與 members 同一個口徑：整月，不夾當日（它是清帳明細的對照數）。
      select coalesce(sum(amount), 0)::bigint as shared_paid
      from entries
      where ledger_id = p_ledger and kind = 'expense' and payer_id is null
        and (date_trunc('month', occurred_on::timestamp))::date = v_month
    )
    select jsonb_build_object(
      'shared_balance', (select shared_balance from sb),
      'budget_total', coalesce((select sum(allocated) from env), 0)::bigint,
      'spent_total', coalesce((select sum(spent) from env), 0)::bigint,
      'overspend_total', coalesce((select sum(over) from env), 0)::bigint,
      'categories', coalesce(
        (select jsonb_agg(jsonb_build_object(
            'category_id', category_id,
            'allocated', allocated,
            'spent', spent,
            -- remaining／over 跟著 spent 走 bigint：over ＝ spent − allocated，
            -- 上界是 spent 而不是 allocated，留 int 等於把溢位從 spent 搬到這裡。
            'remaining', remaining,
            'over', over) order by category_id)
         from env), '[]'::jsonb),
      'members', coalesce(
        (select jsonb_agg(jsonb_build_object(
            'member_id', p.id,
            'display_name', p.display_name,
            'topup', p.topup,
            'paid', p.paid,
            -- 個人補入剩餘刻意**不夾 0**：先付超過補入就是負數（spec「可為負」），
            -- 夾 0 會讓「這個月我墊了多少」在畫面上憑空消失。
            'remaining', p.topup - p.paid) order by p.joined_at, p.id)
         from per p), '[]'::jsonb),
      'shared_paid', (select shared_paid from sp)
    )
  );
end;
$$;

-- 慣例（20260902001100 起）：函式 ACL 白名單——public/anon 全收回、只留 authenticated。
revoke all on function public.month_summary(uuid, date) from public, anon;
grant execute on function public.month_summary(uuid, date) to authenticated;

-- ---------- 10. Realtime publication ----------
-- settlements 已隨 drop table 自動離開 publication（1f）。
-- 加入 personal_topups，並比照 0026 設 replica identity full：
-- DELETE 事件在預設 replica identity（主鍵）下帶不出 ledger_id，前端就沒辦法依帳本過濾。
-- 最終 publication ＝ entries, list_items, budget_allocation, month_closes, personal_topups。
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'personal_topups'
  ) then
    alter publication supabase_realtime add table public.personal_topups;
  end if;
end;
$$;
alter table public.personal_topups replica identity full;

comment on table public.personal_topups is
  '個人補入（ADR-0009 決策 2）：每人每月手動記的預留金額。只能寫自己那列，已清月鎖定。';
