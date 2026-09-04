-- Migration 0027 — 帳務規則 v1.4（ADR-0008 ＋ spec 7e4465f 精確化）
--
-- spec v1.4「餘額與預算」「清帳」節。一支 migration 裝完整套規則，**刻意不拆兩支**：
-- 中間任何一個切點都會留下「funding 已 drop 但 month_summary 還在讀它」之類的破窗，
-- 雲端逐支套用時那個窗口是真的會被打到的（db review minor2）。
--
-- 內容：
--   1. archive schema ＋ v1.3 撥款流水快照（遷移可逆）
--   2. members.monthly_topup（每月補入額）
--   3. budget_allocation 改每分類每月一筆影子紀錄（含既有資料合併）
--   4. drop entries.funding ＋ funding enum；upsert_entry 去 funding
--   5. month_closes 表 ＋ 清帳 RPC ＋ 已清帳月份鎖定 trigger
--   6. 錢公式的唯一實作（taipei_month／topup_for 純函式 ＋ entry_member_effects view）
--   7. month_summary 依 v1.4 公式重寫

-- ---------- 1. 遷移前快照（可逆性；security review M1） ----------
-- 第 3 節的合併是**破壞性**的：多列併一列、合計 ≤ 0 的整組刪掉，回不去。
-- 雲端套用前先把整張 v1.3 的撥款流水原樣拷一份，出事才有得對、有得還原。
-- 放在獨立的 archive schema 而不是 public，有兩個理由：
--   (1) rls.sql 的「public 每張表都必須開 RLS 且有 policy」全表掃描不該被這張快照打紅；
--   (2) 新建的 schema 預設不給 PUBLIC USAGE，前端角色連 schema 都進不去，不必再逐表 revoke。
create schema if not exists archive;
-- 新建 schema 本來就不給 PUBLIC USAGE，這三行是「寫明意圖」而不是補洞：
-- 日後有人手滑 grant usage on schema archive to authenticated 時，rls.sql 的斷言才有對照物。
revoke all on schema archive from public;
revoke all on schema archive from anon;
revoke all on schema archive from authenticated;

create table archive.budget_allocation_v13 as
  select * from public.budget_allocation;

comment on table archive.budget_allocation_v13 is
  'v1.3 撥款流水（一列＝一次撥款、amount 可負）在 0027 合併前的原樣快照；只供人工比對／還原，前端無權。';

-- ---------- 2. members.monthly_topup（每月補入額） ----------
-- 只能改自己那列：members_update policy（0013 的 17）已經限定 user_id = auth.uid()，
-- 這裡只要把欄位級 UPDATE 授權補上（0022 起 members 是欄位級授權，不補就一路 42501）。
-- 上界一億：個人餘額是「補入額 × 月份數 ＋ Σ淨變動」，沒有上界的話前端塞一個接近 int 上限的值
-- 就能讓 month_summary 在乘法那步溢位炸掉（security review m2）。一億對記帳場景遠遠夠用。
alter table public.members
  add column monthly_topup int not null default 0
  constraint members_monthly_topup_range check (monthly_topup >= 0 and monthly_topup <= 100000000);

grant update (monthly_topup) on public.members to authenticated;

-- ---------- 3. budget_allocation 改「每分類每月一筆、正數、不可改不可刪」 ----------
-- 3a. 資料遷移：雲端 dev／prod 已經有 v1.3 的撥款流水（一列＝一次撥款，amount 可負＝退回）。
--     合併規則（ADR-0008 後果節）：同 (ledger_id, category_id, 月) 的多列合併成一列——
--       amount ＝ 該組合計、occurred_on ＝ 該組最小值、note ＝ 該組任一非空備註、
--       created_by ＝ 最早那列（保留最早那列、其餘刪掉，created_by 自然就是最早那筆的）；
--     合計 ≤ 0 的組合（撥了又全退）整組刪除——v1.4 不允許 amount ≤ 0。
--     排序一律用 (created_at, id)：created_at 並列時 id 決定先後，結果才是穩定的。
--     **必須先於 unique 與 amount > 0 這兩道**，否則既有資料會讓 alter 直接失敗。
--     地端 db reset 時這張表是空的（seed 在 migration 之後才跑），這段是 no-op；
--     **等價的合併邏輯另在 supabase/tests/budget.sql 的段 j 用 temp table 鏡像驗過，改這裡要同步改那裡。**
with grouped as (
  select b.ledger_id,
         b.category_id,
         date_trunc('month', b.occurred_on)::date as m,
         sum(b.amount)::int as total,
         min(b.occurred_on) as min_occurred,
         (array_remove(array_agg(nullif(btrim(b.note), '') order by b.created_at, b.id), null))[1] as keep_note,
         (array_agg(b.id order by b.created_at, b.id))[1] as keep_id
  from public.budget_allocation b
  group by b.ledger_id, b.category_id, date_trunc('month', b.occurred_on)::date
),
merged as (
  -- 同一句裡的兩個子語句看的是同一份快照，彼此的效果互不可見；
  -- 這裡 delete 與 update 的目標列不重疊（保留列只會被 update，其餘只會被 delete）。
  delete from public.budget_allocation b
  using grouped g
  where b.ledger_id = g.ledger_id
    and b.category_id = g.category_id
    and date_trunc('month', b.occurred_on)::date = g.m
    and (g.total <= 0 or b.id <> g.keep_id)
  returning b.id
)
update public.budget_allocation b
   set amount = g.total,
       occurred_on = g.min_occurred,
       note = coalesce(g.keep_note, '')
  from grouped g
 where b.id = g.keep_id
   and g.total > 0
   and (b.amount, b.occurred_on, b.note) is distinct from (g.total, g.min_occurred, coalesce(g.keep_note, ''));

-- 3b. 月份欄：由 occurred_on 推導的月初。
-- date_trunc(text, timestamp) 是 immutable（timestamptz 版才不是），所以先轉 timestamp 再 trunc。
alter table public.budget_allocation
  add column month date generated always as ((date_trunc('month', occurred_on::timestamp))::date) stored;

-- 3c. 每分類每月至多一筆。
alter table public.budget_allocation
  add constraint budget_allocation_one_per_category_month unique (ledger_id, category_id, month);

-- 3d. 金額必須 > 0（v1.4 沒有「退回」，0 與負數都無意義）。
alter table public.budget_allocation
  drop constraint budget_allocation_amount_nonzero;
alter table public.budget_allocation
  add constraint budget_allocation_amount_positive check (amount > 0);

-- 3e. 設定後不可改、不可刪：表權與 policy 兩道一起收。
-- （0024 的 grant 是 `select, delete` ＋ 欄位級 update，這裡把 update／delete 全數收回。）
revoke update, delete on public.budget_allocation from authenticated;
drop policy budget_allocation_update on public.budget_allocation;
drop policy budget_allocation_delete on public.budget_allocation;

-- ---------- 4. drop entries.funding 與 funding enum ----------
-- check `entries_funding_common_wallet_only` 與欄位級 insert／update 授權隨欄位一起消失。
alter table public.entries drop column funding;
drop type public.funding;

-- ---------- 5. upsert_entry 去 funding ----------
-- 0024 的活定義原樣複製，只拿掉 insert／update 兩處的 funding；
-- 其餘語意（settled 子表拒寫、子表全刪重建的守恆檢查、欄位 coalesce）一字不改。
-- 前端送多餘的 'funding' 鍵不會有任何效果（jsonb 多餘鍵本來就不影響）。
create or replace function public.upsert_entry(
  p_entry jsonb,
  p_splits jsonb default null,
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
  v_settled public.settled_state;
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

  -- 已結帳的帳目：分攤與細項都不接受重寫（ADR-0002 只允許改分類、備註、細項本身的內容，
  -- 但「整組刪掉重建」在 settled 狀態下會被 policy 擋成半套，所以這裡直接拒絕）。
  if v_id is not null then
    select e.settled_state into v_settled from public.entries e where e.id = v_id;
    if v_settled = 'settled' and (p_splits is not null or p_line_items is not null) then
      raise exception 'entry settled: child tables locked' using errcode = 'P0001',
        hint = '已結帳的帳目只能改分類與備註；金額有誤請開修正筆';
    end if;
  end if;

  if v_id is null then
    insert into public.entries (
      ledger_id, kind, scope, amount, category_id, occurred_on, note,
      created_by, payer_id, split_method, is_adjustment
    ) values (
      v_ledger,
      (p_entry ->> 'kind')::public.entry_kind,
      coalesce((p_entry ->> 'scope')::public.entry_scope, 'shared'),
      (p_entry ->> 'amount')::int,
      (p_entry ->> 'category_id')::uuid,
      (p_entry ->> 'occurred_on')::date,
      coalesce(p_entry ->> 'note', ''),
      v_me,
      nullif(p_entry ->> 'payer_id', '')::uuid,
      coalesce((p_entry ->> 'split_method')::public.split_method, 'common'),
      coalesce((p_entry ->> 'is_adjustment')::boolean, false)
    )
    returning * into v_entry;
  else
    update public.entries e set
      kind          = coalesce((p_entry ->> 'kind')::public.entry_kind, e.kind),
      scope         = coalesce((p_entry ->> 'scope')::public.entry_scope, e.scope),
      amount        = coalesce((p_entry ->> 'amount')::int, e.amount),
      category_id   = coalesce(nullif(p_entry ->> 'category_id', '')::uuid, e.category_id),
      occurred_on   = coalesce((p_entry ->> 'occurred_on')::date, e.occurred_on),
      note          = coalesce(p_entry ->> 'note', e.note),
      payer_id      = case when p_entry ? 'payer_id' then nullif(p_entry ->> 'payer_id', '')::uuid else e.payer_id end,
      split_method  = coalesce((p_entry ->> 'split_method')::public.split_method, e.split_method),
      is_adjustment = coalesce((p_entry ->> 'is_adjustment')::boolean, e.is_adjustment)
    where e.id = v_id
    returning * into v_entry;
    if not found then
      raise exception 'upsert_entry: entry not found or not visible' using errcode = 'P0001';
    end if;
  end if;

  -- null ＝ 不動那張子表；[] ＝ 清空；有內容 ＝ 全刪重建。
  if p_splits is not null then
    select count(*) into v_expected from public.entry_splits s where s.entry_id = v_entry.id;
    delete from public.entry_splits where entry_id = v_entry.id;
    get diagnostics v_deleted = row_count;
    if v_deleted <> v_expected then
      raise exception 'upsert_entry: could not replace splits (% of % rows deleted)', v_deleted, v_expected
        using errcode = '42501';
    end if;
    insert into public.entry_splits (entry_id, member_id, share)
    select v_entry.id, (x ->> 'member_id')::uuid, (x ->> 'share')::numeric
    from jsonb_array_elements(p_splits) x;
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

revoke execute on function public.upsert_entry(jsonb, jsonb, jsonb) from anon, public;
grant execute on function public.upsert_entry(jsonb, jsonb, jsonb) to authenticated;

-- ---------- 6. month_closes ----------
create table public.month_closes (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  -- 一律月初；spec 的「清帳 YYYY／MM」就是這一欄。
  month date not null
    constraint month_closes_month_is_first_day
    check (month = (date_trunc('month', month::timestamp))::date),
  closed_by uuid not null references public.members (id) on delete restrict,
  closed_at timestamptz not null default now(),
  -- {"month", "members":[{member_id, display_name, topup, net, ending}], "shared_delta"} 的快照。
  -- 已清帳月份以這份快照為準：之後改補入額也不會動到它（ADR-0008 決策 4）。
  details jsonb not null,
  created_at timestamptz not null default now(),
  -- 這道 unique 同時是 (ledger_id, month) 的索引，查「最後清帳月」與「該月清過沒」都走它，
  -- 所以**不另建** ledger_id+month 的普通索引（db review minor1）。
  constraint month_closes_one_per_month unique (ledger_id, month)
);
-- FK 子欄位的索引（沿用 0019 的慣例：on delete restrict 沒索引會全表掃）。
create index month_closes_closed_by_idx on public.month_closes (closed_by);

-- 跨帳本：照 0014／0024 的慣例用複合 FK（被參照的 (id, ledger_id) 唯一鍵已存在）。
alter table public.month_closes
  add constraint month_closes_closed_by_same_ledger
  foreign key (closed_by, ledger_id) references public.members (id, ledger_id) on delete restrict;

-- RLS：成員可讀，寫入完全沒有 policy——清帳只能經 close_month（security definer）落地，
-- 而且不可撤銷，所以連 delete 都不給。
alter table public.month_closes enable row level security;
create policy month_closes_select on public.month_closes
  for select to authenticated using (public.is_member(ledger_id));

-- 授權：default privileges 已關（0018／0021／0023），不顯式 grant 前端完全用不了。
grant select on public.month_closes to authenticated;

-- Realtime（冪等寫法同 0005）＋ replica identity full（同 0026：DELETE payload 要帶得出 ledger_id）。
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'month_closes'
  ) then
    alter publication supabase_realtime add table public.month_closes;
  end if;
end;
$$;
alter table public.month_closes replica identity full;

-- ---------- 7. 錢公式的唯一一份實作 ----------
-- code review T2／T3／T4：個人餘額的三段公式、加入月的判準、台北取月初，原本在
-- month_close_details 與 month_summary 各寫了一遍——兩邊哪天漂掉，畫面上的餘額與清帳明細
-- 就會對不起來，而且那是「錢」。以下把它們收成一份：
--   * taipei_month()／topup_for()：純函式，不碰任何表
--   * entry_member_effects：一列＝一筆帳目對一位成員個人餘額的影響

-- 7a. 台北時區取月初。timestamptz → 台北當地時間 → 該月月初。
-- 純計算、不讀任何表，所以 grant 給前端也洩不出東西（rls.sql 白名單旁有註記）。
-- stable 而非 immutable：時區定義本身可能被 tzdata 更新改掉。
create or replace function public.taipei_month(p_ts timestamptz)
returns date
language sql
stable
set search_path = public
as $$
  select (date_trunc('month', p_ts at time zone 'Asia/Taipei'))::date;
$$;
revoke all on function public.taipei_month(timestamptz) from public, anon;
grant execute on function public.taipei_month(timestamptz) to authenticated;

-- 7b. 某位成員在某個月「有沒有補入額」的唯一判準（spec：從加入帳本那個月起每月加一次）。
-- 同樣是純函式。
create or replace function public.topup_for(p_monthly_topup int, p_joined_at timestamptz, p_month date)
returns int
language sql
stable
set search_path = public
as $$
  select case when public.taipei_month(p_joined_at) <= p_month then p_monthly_topup else 0 end;
$$;
revoke all on function public.topup_for(int, timestamptz, date) from public, anon;
grant execute on function public.topup_for(int, timestamptz, date) to authenticated;

-- 7c. 一列＝一筆帳目對一位成員個人餘額的影響（spec v1.4「該月淨變動」的三段，逐字對應）：
--   * 私人筆 → 只影響 created_by 本人，收入 +amount、支出 −amount
--   * 未結算代墊（payer 非 null）→ 付款人 −全額
--   * 已結算共同支出 → 每位成員 −自己的整數份額
--   * 共同收入與共同錢包支出（payer is null）不產生任何列——它們只動共同餘額
-- 沖銷筆（負 amount）不必特別處理，自然流過同一條。
--
-- 份額取整用**最大餘數法**（spec 7e4465f）：每筆先全員 floor，差額依小數由大到小各補 1，
-- 同小數以 member_id 決定先後（與 initiate_settlement 同法）。逐筆 round() 會漏／溢一元：
-- 567 均分兩人 → round(283.5) 兩次都是 284，合計 568 ≠ 567。
--
-- 為什麼是 view 而不是函式：這份要同時給 month_close_details（security definer，算全體成員）
-- 與 month_summary（security invoker，只算呼叫者自己）用。security invoker 函式裡的權限檢查是以
-- **原呼叫者**身分做的，所以「不 grant 的內部 helper 函式」在 month_summary 裡一律
-- permission denied（已實測）。security_invoker view 兩邊都成立：
--   * month_summary（invoker）讀它 → 以呼叫者身分吃 RLS，範圍就是他本來查 entries／entry_splits 的範圍；
--   * month_close_details（definer）讀它 → 以 postgres 身分跑，看得到全部。
-- 因為是 security_invoker，grant select 給 authenticated 不會多開任何他本來查不到的資料。
-- **這個 flag 是安全邊界**：改成 definer 就會讓任何成員讀得到別人的私人筆
-- （rls.sql 有一條斷言直接盯 reloptions）。前端沒有理由直接讀這個 view——畫面數字一律走 month_summary。
create view public.entry_member_effects
with (security_invoker = true) as
  -- 私人筆：只動本人。
  select e.ledger_id,
         e.id as entry_id,
         e.created_by as member_id,
         e.occurred_on,
         (case when e.kind = 'income' then e.amount else -e.amount end)::bigint as delta
  from public.entries e
  where e.scope = 'private'
union all
  -- 未結算代墊：付款人先扛全額。
  select e.ledger_id, e.id, e.payer_id, e.occurred_on, (-e.amount)::bigint
  from public.entries e
  where e.scope = 'shared' and e.kind = 'expense'
    and e.payer_id is not null and e.settled_state <> 'settled'
union all
  -- 已結算共同支出：每位成員各扛自己的整數份額（付款人也只扛自己那份）。
  select e.ledger_id,
         e.id,
         s.member_id,
         e.occurred_on,
         -- partition 帶上 ledger_id（語意不變：entry_id 已經唯一）——
         -- 少了它，呼叫端的 `where ledger_id = ?` 沒辦法下推到 window 之前，
         -- 整張 entry_splits 會先全表算一次 window 才過濾（db review N1 附 EXPLAIN）。
         (-(floor(s.share)
            + case when row_number() over (partition by e.ledger_id, s.entry_id
                                           order by (s.share - floor(s.share)) desc, s.member_id)
                        <= (e.amount - sum(floor(s.share)) over (partition by e.ledger_id, s.entry_id))
                   then 1 else 0 end))::bigint
  from public.entries e
  join public.entry_splits s on s.entry_id = e.id
  where e.scope = 'shared' and e.kind = 'expense'
    and e.payer_id is not null and e.settled_state = 'settled';

grant select on public.entry_member_effects to authenticated;

comment on view public.entry_member_effects is
  '一列＝一筆帳目對一位成員個人餘額的影響（spec v1.4「該月淨變動」的唯一實作，份額用最大餘數法）。security_invoker：吃呼叫者的 RLS——改成 definer 會外洩別人的私人筆。';

-- ---------- 8. 清帳明細與可清條件 ----------
-- 8a. 明細（spec「清帳」節）。security definer：要算**每一位**成員的私人收支與份額，
-- 而私人筆的 RLS 只讓本人看得到，用 invoker 算出來的別人那列會是 0。
-- 內部 helper，不 grant 給任何前端角色——前端只能經 preview／close 間接拿到結果。
--
-- 成員 M 在月 m 的淨變動（帳目一律依 occurred_on 歸月，ADR-0008 決策 2）：
--   Σ(private, created_by = M：income +amount / expense −amount)
--   − Σ(shared expense, payer_id = M, settled_state <> 'settled'：全額)
--   − Σ(shared expense, payer_id is not null, settled_state = 'settled'：自己的整數份額)
-- 共同收入與共同錢包支出（payer_id is null）不進個人。沖銷筆（負 amount）自然流過同一條公式。
create or replace function public.month_close_details(p_ledger uuid, p_month date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with mem as (
  select m.id, m.display_name, m.monthly_topup, m.joined_at
  from public.members m
  where m.ledger_id = p_ledger
),
calc as (
  select m.id,
         m.display_name,
         m.joined_at,
         -- 補入額適用與否：唯一判準在 topup_for（month_summary 用同一支）。
         public.topup_for(m.monthly_topup, m.joined_at, p_month) as topup,
         -- 淨變動：唯一實作在 entry_member_effects（month_summary 用同一個 view）。
         coalesce((select sum(ef.delta)
                   from public.entry_member_effects ef
                   where ef.ledger_id = p_ledger
                     and ef.member_id = m.id
                     and date_trunc('month', ef.occurred_on)::date = p_month), 0)::bigint as net
  from mem m
),
sd as (
  -- 該月共同餘額變動（僅供對照）：Σ共同收入 − Σ共同錢包支出。
  select coalesce(sum(case when e.kind = 'income' then e.amount
                           when e.payer_id is null then -e.amount
                           else 0 end), 0)::bigint as shared_delta
  from public.entries e
  where e.ledger_id = p_ledger and e.scope = 'shared'
    and date_trunc('month', e.occurred_on)::date = p_month
)
select jsonb_build_object(
  'month', to_char(p_month, 'YYYY-MM-DD'),
  'members', coalesce((
    select jsonb_agg(jsonb_build_object(
             'member_id', c.id,
             'display_name', c.display_name,
             'topup', c.topup,
             -- 三個數字一律 bigint 輸出（與 month_summary.personal_balance 一致）：
             -- amount 是 int，但一個月加起來可以輕鬆越過 int 上界；轉 int 等於把
             -- 「算得出來」變成「整支 RPC 炸掉」，而清帳是不可撤銷的操作，最不該在這裡炸。
             -- jsonb 裝得下，Dart 的 int 是 64-bit（security review n6）。
             'net', c.net,
             'ending', c.topup::bigint + c.net)
           order by c.joined_at, c.id)
    from calc c), '[]'::jsonb),
  'shared_delta', (select shared_delta from sd)
);
$$;
revoke execute on function public.month_close_details(uuid, date) from anon, authenticated, public;

-- 8b. 可清條件（spec「清帳」節 (1)～(4)）。preview 與 close_month 共用這一段，訊息逐字相同。
-- 檢查順序刻意是：月初 → 月份已結束 → 已清過 → 順序 → 有無未結算拆帳。
-- 「已清過」必須排在「順序」之前：清過的月份一定不等於下一個可清月，
-- 排在後面的話重清同月會拿到 "must close … first"，而不是看得懂的 "already closed"。
-- 注意這一條刻意用「**該月有沒有紀錄**」判，而不是全庫通用的「月份 ≤ 最後清帳月」——
-- 它的職責只是「給人看得懂的訊息」，不是決定鎖不鎖／算不算餘額。真正的鎖定與餘額判準
-- 一律走 max（見 raise_if_month_closed 與 month_summary）；這裡用另一把尺不會有語意分岔，
-- 因為底下的順序檢查已經保證只有「下一個可清月」過得去（code review M2）。
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

  -- 下一個可清月：清過就是「上次 ＋ 1 月」，沒清過就是「最早有成員或有帳目的那個月」。
  select (max(mc.month) + interval '1 month')::date into v_next
  from public.month_closes mc where mc.ledger_id = p_ledger;
  if v_next is null then
    select least(
      (select min(public.taipei_month(m.joined_at))
         from public.members m where m.ledger_id = p_ledger),
      (select min(date_trunc('month', e.occurred_on)::date)
         from public.entries e where e.ledger_id = p_ledger)
    ) into v_next;
  end if;

  if v_next is null or v_next >= v_cur then
    raise exception 'close_month: nothing to close' using errcode = 'P0001';
  end if;
  if p_month <> v_next then
    raise exception 'close_month: must close % first', to_char(v_next, 'YYYY-MM')
      using errcode = 'P0001';
  end if;

  -- 判準逐字比照 initiate_settlement（0015）——**含 `exists entry_splits`**：
  -- 沒有分攤列的拆帳筆結算根本撿不到，清帳若還擋它就會卡成死結（spec 7e4465f、security review m1）。
  if exists (
    select 1 from public.entries e
    where e.ledger_id = p_ledger
      and e.scope = 'shared' and e.kind = 'expense'
      and e.payer_id is not null and e.split_method <> 'common'
      and e.settled_state <> 'settled'
      and exists (select 1 from public.entry_splits s where s.entry_id = e.id)
      and date_trunc('month', e.occurred_on)::date = p_month
  ) then
    raise exception 'close_month: unsettled entries in month' using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function public.month_close_guard(uuid, date) from anon, authenticated, public;

-- 8c. 預覽：可清條件不過就 raise 對應訊息，過了回和 close_month 一模一樣的明細。
create or replace function public.month_close_preview(p_ledger uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_loose int;
begin
  if auth.uid() is null then
    raise exception 'month_close_preview: not authenticated' using errcode = '28000';
  end if;
  if public.my_member_id(p_ledger) is null then
    raise exception 'month_close_preview: not a member' using errcode = '42501';
  end if;

  perform public.month_close_guard(p_ledger, p_month);

  -- 可清條件第 6 條刻意放行「沒有分攤列的拆帳筆」（它結算撿不到，擋了那個月永遠清不掉），
  -- 但那種筆會由付款人**全額**承擔，金額可能很難看。清帳不可撤銷，所以預覽要先講一聲。
  -- warnings 只出現在預覽：close_month 落地的 details 是**事實快照**，不放當下的提醒
  -- （提醒會隨資料變，快照不該變）。
  select count(*) into v_loose
  from public.entries e
  where e.ledger_id = p_ledger
    and e.scope = 'shared' and e.kind = 'expense'
    and e.payer_id is not null and e.split_method <> 'common'
    and not exists (select 1 from public.entry_splits s where s.entry_id = e.id)
    and date_trunc('month', e.occurred_on)::date = p_month;

  -- 結構化而非中文句子：文案屬於前端（要配合畫面、要能翻譯、要能改字），
  -- DB 只回「是哪一類、有幾筆」。db-contract 有 code → 文案的對照表。
  return public.month_close_details(p_ledger, p_month)
       || jsonb_build_object('warnings',
            case when v_loose > 0
                 then jsonb_build_array(jsonb_build_object(
                        'code', 'unsplit_advances', 'count', v_loose))
                 else '[]'::jsonb end);
end;
$$;
revoke execute on function public.month_close_preview(uuid, date) from anon, public;
grant execute on function public.month_close_preview(uuid, date) to authenticated;

-- 8d. 執行：任一成員可清、不需多簽、不可撤銷（ADR-0008 決策 8）。
create or replace function public.close_month(p_ledger uuid, p_month date)
returns public.month_closes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid;
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

  -- 同一帳本序列化，兩個人同時按「清帳」不會各清一次（逐字比照 initiate_settlement，0015）。
  perform pg_advisory_xact_lock(hashtextextended(p_ledger::text, 0));

  perform public.month_close_guard(p_ledger, p_month);

  insert into public.month_closes (ledger_id, month, closed_by, details)
  values (p_ledger, p_month, v_me, public.month_close_details(p_ledger, p_month))
  returning * into v_row;

  return v_row;
end;
$$;
revoke execute on function public.close_month(uuid, date) from anon, public;
grant execute on function public.close_month(uuid, date) to authenticated;

-- ---------- 9. 已清帳月份鎖定 trigger ----------
-- spec（7e4465f）：occurred_on 落在**最後清帳月（含）以前**的帳目（含分攤、細項）與預算
-- 一律不可新增、修改、刪除。不是只鎖「有清帳紀錄的那幾個月」——補記到最早清帳月之前的月份，
-- 永遠不會是「下一個可清月」，那筆的影響就永久留在個人餘額裡清不掉（db review M3）。
--
-- trigger 依名稱字母序執行，所以一律用 `a_` 開頭：
--   entries 的 before delete 另有 entries_void_pending_settlement_del_trg（0010），
--   那支會把 pending 結算標 void——鎖月的檢查必須排在它之前。
create or replace function public.raise_if_month_closed(p_ledger uuid, p_month date)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_last date;
begin
  select max(mc.month) into v_last
  from public.month_closes mc where mc.ledger_id = p_ledger;

  if v_last is not null and p_month <= v_last then
    -- 訊息帶「被擋的那個月」，不是最後清帳月：使用者要看到的是自己動到的那筆屬於哪個月。
    raise exception 'month closed: %', to_char(p_month, 'YYYY-MM') using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function public.raise_if_month_closed(uuid, date) from anon, authenticated, public;

create or replace function public.entries_month_closed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public.raise_if_month_closed(OLD.ledger_id, date_trunc('month', OLD.occurred_on)::date);
    return OLD;
  end if;

  -- 新值那個月要擋（新增、或把日期改進鎖定範圍）。
  perform public.raise_if_month_closed(NEW.ledger_id, date_trunc('month', NEW.occurred_on)::date);
  -- 舊值那個月也要擋（改動鎖定範圍裡的帳目，包含把它搬出去）。
  if TG_OP = 'UPDATE' then
    perform public.raise_if_month_closed(OLD.ledger_id, date_trunc('month', OLD.occurred_on)::date);
  end if;
  return NEW;
end;
$$;
revoke execute on function public.entries_month_closed() from anon, authenticated, public;

create trigger a_entries_month_closed_trg
  before insert or update or delete on public.entries
  for each row execute function public.entries_month_closed();

-- 子表：查父 entry 的 occurred_on。upsert_entry 對 open 的帳目是「子表全刪重建」，
-- 所以父筆鎖了、子表這一路也必須擋（父筆已經被上面那支擋掉，這裡是直接寫子表的路徑）。
-- 父 entry 被 cascade 刪掉時查不到父列（那時 entries 那列已經不存在）→ 放行，
-- 但鎖定範圍內的帳目本來就刪不掉，這條路走不到。
create or replace function public.entry_children_month_closed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ledger uuid;
  v_on date;
begin
  if TG_OP <> 'INSERT' then
    select e.ledger_id, e.occurred_on into v_ledger, v_on
    from public.entries e where e.id = OLD.entry_id;
    if v_ledger is not null then
      perform public.raise_if_month_closed(v_ledger, date_trunc('month', v_on)::date);
    end if;
  end if;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;

  select e.ledger_id, e.occurred_on into v_ledger, v_on
  from public.entries e where e.id = NEW.entry_id;
  if v_ledger is not null then
    perform public.raise_if_month_closed(v_ledger, date_trunc('month', v_on)::date);
  end if;
  return NEW;
end;
$$;
revoke execute on function public.entry_children_month_closed() from anon, authenticated, public;

create trigger a_entry_splits_month_closed_trg
  before insert or update or delete on public.entry_splits
  for each row execute function public.entry_children_month_closed();

create trigger a_line_items_month_closed_trg
  before insert or update or delete on public.line_items
  for each row execute function public.entry_children_month_closed();

-- 預算：鎖定範圍內不得再設定，也不得被改／被刪（前端本來就沒有 UPDATE／DELETE 授權，
-- 但 service_role 之類繞過欄位授權的路徑還在，所以三個動詞都掛，update／delete 看 OLD 的月）。
-- 注意不能用 NEW.month／OLD.month——generated 欄位是在 BEFORE trigger **之後**才算出來的。
create or replace function public.budget_allocation_month_closed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP <> 'INSERT' then
    perform public.raise_if_month_closed(OLD.ledger_id, date_trunc('month', OLD.occurred_on)::date);
  end if;
  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  perform public.raise_if_month_closed(NEW.ledger_id, date_trunc('month', NEW.occurred_on)::date);
  return NEW;
end;
$$;
revoke execute on function public.budget_allocation_month_closed() from anon, authenticated, public;

create trigger a_budget_allocation_month_closed_trg
  before insert or update or delete on public.budget_allocation
  for each row execute function public.budget_allocation_month_closed();

-- ---------- 10. month_summary 依 v1.4 公式重寫 ----------
-- 輸出（v1.3 的 shared_available／envelope_total 兩鍵移除）：
--   { shared_balance, budget_total, spent_total, overspend_total,
--     categories: [{category_id, allocated, spent, remaining, over}],
--     me: {member_id, personal_balance, monthly_topup, month_net} }
--
--   shared_balance ＝ 共同期初 ＋ Σ共同收入 − Σ共同錢包支出（payer_id is null）；清帳不影響它。
--   allocated ＝ 該分類 p_until 所在月的那一筆預算（0 或 1 筆），**刻意不篩 occurred_on**：
--     預算是當月的影子紀錄，設定當下就對整個月生效。spent 則相反，逐筆累加所以有 occurred_on <= until。
--   spent ＝ 該分類該月**所有**共同支出（不分 payer，含代墊）。
--   personal_balance ＝ Σ（未清帳月份的補入額）＋ Σ（未清帳月份的淨變動），
--     N ＝ [加入月, least(until 所在月, 台北本月)] 之間**晚於最後清帳月**的月份數
--     （加入月晚於那個上界 → 0）。「未清帳」＝ 月份 > max(month_closes.month)，全庫同一個定義。
--   month_net ＝ 呼叫者在 until 所在月、截至 until 的淨變動（不管該月清了沒）。
--
-- p_until **不夾上界**（前端月份切換沒有上界，下個月的預算是合法的）；只有補入額的
-- 月份列舉夾在台北本月，否則 p_until 給 '9999-12-31' 會算出九萬個月的補入額。
-- p_until 為 null ＝ 問到本月底。
-- 仍是 security invoker：me 只算呼叫者自己，讀不到別人的私人筆；非成員被 RLS 濾成空。
create or replace function public.month_summary(p_ledger uuid, p_until date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  -- p_until 為 null ＝「問到本月底」。**只是預設值，不是上界**：
  -- 前端的月份切換沒有上界（下個月的預算是合法的、可以先設），問下個月就該拿到下個月的
  -- allocated／spent／categories／month_net。所以夾擠只套在下面 v_n_upper 那一個地方。
  v_until date := coalesce(
    p_until,
    (public.taipei_month(now()) + interval '1 month - 1 day')::date);
  -- 使用者要看的那個月——allocated／spent／categories／month_net 全都照這個月算。
  v_month date := (date_trunc('month', v_until::timestamp))::date;
  -- 補入額的月份列舉上界則**必須**夾在台北本月：補入額是「每個月實際補進來的錢」，
  -- 還沒到的月份不該先算給你。不夾的話 p_until 給 '9999-12-31' 會算出九萬個月的補入額
  -- （security review m4 原本要防的就是這個，但修復輪我把夾擠套到整支函式，
  --  連 v_month 都被夾住，於是「看下個月」會拿到本月的預算與已花——code review N1）。
  v_n_upper date := least(v_month, public.taipei_month(now()));
  -- 「已清帳」全庫只有一個定義：**月份 ≤ 最後清帳月**（db review N2）。
  -- 鎖月 trigger 用 `<= max`、個人餘額用 `> max`，同一把尺的兩面。
  -- 用「有沒有那一列」判會分岔：清帳只能按序推進，所以正常情況兩者等價，
  -- 但雲端人工救援刪掉中間某一列之後，被刪那個月就會偷偷回到個人餘額裡
  -- （鎖月照樣擋，於是餘額對不上又改不動）。
  v_last_close date := (select max(mc.month) from month_closes mc where mc.ledger_id = p_ledger);
begin
  return (
    with me as (
      select m.id, m.monthly_topup, m.joined_at
      from members m
      where m.ledger_id = p_ledger and m.user_id = auth.uid()
    ),
    sb as (
      select (select opening_balance_shared from ledgers where id = p_ledger)
           + coalesce(sum(case
               when kind = 'income' then amount
               when payer_id is null then -amount
               else 0 end), 0) as shared_balance
      from entries
      where ledger_id = p_ledger and scope = 'shared' and occurred_on <= v_until
    ),
    alloc as (
      select category_id, amount::int as allocated
      from budget_allocation
      where ledger_id = p_ledger and month = v_month
    ),
    spent as (
      -- 加總一律 bigint：單筆 amount 是 int，但一個月加起來越得過 int 上界，
      -- 屆時 month_summary 會回 integer out of range 而不是數字（順路發現 8）。
      select category_id, sum(amount)::bigint as spent
      from entries
      where ledger_id = p_ledger and kind = 'expense' and scope = 'shared'
        and date_trunc('month', occurred_on)::date = v_month
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
    -- 呼叫者的淨變動，依帳目所在月分組。三段公式的唯一實作在 entry_member_effects，
    -- month_close_details 聚合同一個 view——錢公式只此一份（code review T2）。
    net_by_month as (
      select date_trunc('month', ef.occurred_on)::date as m,
             sum(ef.delta)::bigint as net
      from entry_member_effects ef
      cross join me
      where ef.ledger_id = p_ledger
        and ef.member_id = me.id
        and ef.occurred_on <= v_until
      group by 1
    ),
    -- [加入月, until 所在月] 之間還沒清帳的月份（加入月晚於 until 月 → 一列都沒有）。
    -- 加入月走 taipei_month，補入額適不適用走 topup_for——與 month_close_details 同一支。
    open_months as (
      select gs::date as m,
             public.topup_for(me.monthly_topup, me.joined_at, gs::date)::bigint as topup
      from me
      cross join generate_series(
        public.taipei_month(me.joined_at)::timestamp,
        v_n_upper::timestamp,
        interval '1 month') gs
      where gs::date > coalesce(v_last_close, '-infinity'::date)
    )
    select jsonb_build_object(
      -- 加總全部 bigint（sb 本來就是 int + sum(int) ＝ bigint，這裡明寫出來）；
      -- allocated 留 int：它是單筆預算，本來就受 amount 的 int 欄位型別與 amount > 0 的 check 限制。
      'shared_balance', (select shared_balance from sb)::bigint,
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
      'me', (select jsonb_build_object(
          'member_id', me.id,
          -- 全程 bigint，**輸出也是 bigint**（不轉 int）：補入額有上界，但月份數與淨變動沒有，
          -- 轉 int 等於把「算得出來但塞不進 int」變成整支 RPC 炸掉。jsonb 裝得下，
          -- Dart 的 int 是 64-bit，前端照收（security review n5）。
          'personal_balance',
            (coalesce((select sum(om.topup) from open_months om), 0)
             + coalesce((select sum(nb.net) from net_by_month nb
                          where nb.m > coalesce(v_last_close, '-infinity'::date)), 0))::bigint,
          'monthly_topup', me.monthly_topup,
          'month_net', coalesce((select nb.net from net_by_month nb where nb.m = v_month), 0)::bigint)
         from me)
    )
  );
end;
$$;

-- 慣例（20260902001100 起）：函式 ACL 白名單——public/anon 全收回、只留 authenticated。
revoke all on function public.month_summary(uuid, date) from public, anon;
grant execute on function public.month_summary(uuid, date) to authenticated;
