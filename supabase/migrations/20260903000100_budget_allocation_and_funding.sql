-- Migration 0024 — 帳務規則 v1.3（ADR-0007）：手動撥款信封、支出資金來源、拿掉 budgets／rollover
--
-- spec v1.3「餘額與預算」：預算只有共同一套，撥款純手動（可負＝退回），信封只看當月、不跨月；
-- 只有「付款人＝共同錢包」的共同支出可以用預算付，代墊與私人一律走餘額。
-- 餘額、信封剩餘、超支全都是**推導值**（ADR-0007 後果節）：DB 不算餘額、不建 view，前端推導。

-- ---------- 1. 資金來源 enum 與 entries.funding ----------
create type public.funding as enum ('balance', 'budget');

alter table public.entries
  add column funding public.funding not null default 'balance';

-- 只有共同錢包（payer_id is null）的共同支出可選預算。
alter table public.entries
  add constraint entries_funding_common_wallet_only
  check (funding = 'balance' or (payer_id is null and scope = 'shared' and kind = 'expense'));

-- entries 是欄位級授權（0018 的 55-63），新欄位不會自動可寫；
-- 漏了這兩行，upsert_entry（security invoker）帶 funding 就是一路 42501。
grant insert (funding) on public.entries to authenticated;
grant update (funding) on public.entries to authenticated;

-- 註：funding **不**加進 entries_lock_settled（0016）與 void trigger（0007／0016）的欄位清單。
-- 理由：會進結算的只有代墊（payer_id 不是 null），而上面的 check 已經強制那種帳目只能是 balance，
-- 所以 settled／settling 的帳目根本不可能有 funding 可改（改成 budget 會先撞 check）。
-- 把它列進鎖定清單只會多一條永遠不會觸發的規則。

-- ---------- 2. upsert_entry 帶 funding ----------
-- 整支重貼（0022 版逐字保留，只加 funding 的 insert／update 兩行）：
-- 函式一律 create or replace，最後一次定義才是現行版本。
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
      created_by, payer_id, split_method, is_adjustment, funding
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
      coalesce((p_entry ->> 'is_adjustment')::boolean, false),
      coalesce((p_entry ->> 'funding')::public.funding, 'balance')
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
      is_adjustment = coalesce((p_entry ->> 'is_adjustment')::boolean, e.is_adjustment),
      funding       = coalesce((p_entry ->> 'funding')::public.funding, e.funding)
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

-- ---------- 3. budget_allocation（手動撥款流水） ----------
-- 一列＝一次撥款；amount 可負（退回）。信封剩餘由前端按月加總推導，DB 不存餘額。
create table public.budget_allocation (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  category_id uuid not null references public.categories (id) on delete restrict,
  -- 0 沒有意義（既不是撥款也不是退回），直接擋掉。
  amount int not null constraint budget_allocation_amount_nonzero check (amount <> 0),
  occurred_on date not null,
  note text not null default '',
  created_by uuid not null references public.members (id) on delete restrict,
  created_at timestamptz not null default now()
);
create index budget_allocation_ledger_occurred_idx on public.budget_allocation (ledger_id, occurred_on);

-- FK 子欄位的索引（沿用 0019 的慣例：on delete restrict 沒索引會全表掃）。
create index budget_allocation_category_idx on public.budget_allocation (category_id);
create index budget_allocation_created_by_idx on public.budget_allocation (created_by);

-- 跨帳本：照 0014 的常態慣例用複合 FK（被參照的 (id, ledger_id) 唯一鍵已存在），
-- 單欄 FK 保留不動（複合比較嚴，兩者並存不衝突）。
alter table public.budget_allocation
  add constraint budget_allocation_category_same_ledger
  foreign key (category_id, ledger_id) references public.categories (id, ledger_id) on delete restrict;
alter table public.budget_allocation
  add constraint budget_allocation_created_by_same_ledger
  foreign key (created_by, ledger_id) references public.members (id, ledger_id) on delete restrict;

-- FK 表達不了的那一條：只有支出分類能撥款（收入分類沒有信封）。
create or replace function public.budget_allocation_expense_category()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_kind public.entry_kind;
begin
  -- 查不到分類（不存在／別的帳本／RLS 看不到）就交給複合 FK 與 RLS 去擋，
  -- 這支只負責「分類種類」這一條，訊息才不會互相蓋掉。
  select c.kind into v_kind from public.categories c where c.id = NEW.category_id;
  if v_kind is not null and v_kind <> 'expense' then
    raise exception 'budget allocation: category must be an expense category' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.budget_allocation_expense_category() from anon, authenticated, public;

create trigger budget_allocation_expense_category_trg
  before insert or update of category_id on public.budget_allocation
  for each row execute function public.budget_allocation_expense_category();

-- RLS：以帳本成員為界（撥款是共同的，成員都能加減）。
alter table public.budget_allocation enable row level security;

create policy budget_allocation_select on public.budget_allocation
  for select to authenticated using (public.is_member(ledger_id));
-- insert 的 with check 比照 entries（0002 的 entries_insert）：不能以別人的名義撥款。
create policy budget_allocation_insert on public.budget_allocation
  for insert to authenticated
  with check (
    public.is_member(ledger_id)
    and created_by = public.my_member_id(ledger_id)
  );
create policy budget_allocation_update on public.budget_allocation
  for update to authenticated using (public.is_member(ledger_id)) with check (public.is_member(ledger_id));
create policy budget_allocation_delete on public.budget_allocation
  for delete to authenticated using (public.is_member(ledger_id));

-- 授權：default privileges 已關（0018／0021），新表不顯式 grant 前端完全用不了。
-- update 只開三欄：ledger_id／category_id／created_by 改了就是換一筆撥款，請刪掉重開
-- （這三欄前端完全沒有 UPDATE 授權，寫了就是 permission denied，不另設不可變 trigger）。
-- insert 也走欄位級（比照 entries 的 0018）：id 與 created_at 不給前端填。
grant select, delete on public.budget_allocation to authenticated;
grant insert (ledger_id, category_id, amount, occurred_on, note, created_by)
  on public.budget_allocation to authenticated;
grant update (amount, occurred_on, note) on public.budget_allocation to authenticated;

-- Realtime（冪等寫法同 0005）。
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'budget_allocation'
  ) then
    alter publication supabase_realtime add table public.budget_allocation;
  end if;
end;
$$;

-- ---------- 4. 移除 v1.2 的上限式預算與 rollover ----------
-- budgets 的 policy／grant／constraint 隨表一起消失。
drop table public.budgets;
-- 信封只看當月、月底一律退回（ADR-0007 決策 5），分類不再需要 rollover。
alter table public.categories drop column rollover;
