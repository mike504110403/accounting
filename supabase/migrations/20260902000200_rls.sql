-- Migration 0002 — RLS（認證授權；每張表都必須有 policy）
-- 原則：資料以帳本為界，成員才看得到；private entry 只有作者看得到（ADR-0003）。

-- ---------- 輔助函式 ----------
-- security definer：policy 內查 members 不受 members 自身 RLS 影響（避免遞迴）。
create or replace function public.is_member(p_ledger uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- 未登入一律不是成員（不 raise，否則 anon 的任何查詢都會炸而非回空集）。
  if auth.uid() is null then
    return false;
  end if;
  return exists (
    select 1 from public.members m
    where m.ledger_id = p_ledger and m.user_id = auth.uid()
  );
end;
$$;

-- 呼叫者在該帳本的 member id；非成員或未登入回 null。
create or replace function public.my_member_id(p_ledger uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    return null;
  end if;
  select m.id into v_id from public.members m
  where m.ledger_id = p_ledger and m.user_id = auth.uid();
  return v_id;
end;
$$;

revoke all on function public.is_member(uuid) from public;
revoke all on function public.my_member_id(uuid) from public;
grant execute on function public.is_member(uuid) to authenticated;
grant execute on function public.my_member_id(uuid) to authenticated;

-- ---------- 開 RLS ----------
alter table public.ledgers enable row level security;
alter table public.members enable row level security;
alter table public.categories enable row level security;
alter table public.entries enable row level security;
alter table public.entry_splits enable row level security;
alter table public.line_items enable row level security;
alter table public.settlements enable row level security;
alter table public.settlement_entries enable row level security;
alter table public.settlement_approvals enable row level security;
alter table public.budgets enable row level security;
alter table public.list_items enable row level security;

-- ---------- 授權（cloud 上不倚賴 auto expose） ----------
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.ledgers, public.members, public.categories, public.entries,
  public.entry_splits, public.line_items, public.settlements,
  public.settlement_entries, public.settlement_approvals,
  public.budgets, public.list_items
to authenticated;

-- ---------- ledgers ----------
create policy ledgers_select on public.ledgers
  for select to authenticated
  using (public.is_member(id));

create policy ledgers_update on public.ledgers
  for update to authenticated
  using (public.is_member(id))
  with check (public.is_member(id));

-- 任何登入者可建（正式路徑是 create_ledger RPC）。
create policy ledgers_insert on public.ledgers
  for insert to authenticated
  with check (auth.uid() is not null);

-- ---------- members ----------
create policy members_select on public.members
  for select to authenticated
  using (public.is_member(ledger_id));

-- 只能插自己，且限已是該帳本成員；加入新帳本一律走 join_ledger RPC（需邀請碼）。
create policy members_insert on public.members
  for insert to authenticated
  with check (user_id = auth.uid() and public.is_member(ledger_id));

-- 只能改自己那列（display_name、期初餘額）。
create policy members_update on public.members
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------- categories ----------
create policy categories_select on public.categories
  for select to authenticated using (public.is_member(ledger_id));
create policy categories_insert on public.categories
  for insert to authenticated with check (public.is_member(ledger_id));
create policy categories_update on public.categories
  for update to authenticated using (public.is_member(ledger_id)) with check (public.is_member(ledger_id));
create policy categories_delete on public.categories
  for delete to authenticated using (public.is_member(ledger_id));

-- ---------- budgets ----------
create policy budgets_select on public.budgets
  for select to authenticated using (public.is_member(ledger_id));
create policy budgets_insert on public.budgets
  for insert to authenticated with check (public.is_member(ledger_id));
create policy budgets_update on public.budgets
  for update to authenticated using (public.is_member(ledger_id)) with check (public.is_member(ledger_id));
create policy budgets_delete on public.budgets
  for delete to authenticated using (public.is_member(ledger_id));

-- ---------- list_items ----------
create policy list_items_select on public.list_items
  for select to authenticated using (public.is_member(ledger_id));
create policy list_items_insert on public.list_items
  for insert to authenticated with check (public.is_member(ledger_id));
create policy list_items_update on public.list_items
  for update to authenticated using (public.is_member(ledger_id)) with check (public.is_member(ledger_id));
create policy list_items_delete on public.list_items
  for delete to authenticated using (public.is_member(ledger_id));

-- ---------- settlements ----------
create policy settlements_select on public.settlements
  for select to authenticated using (public.is_member(ledger_id));
create policy settlements_insert on public.settlements
  for insert to authenticated with check (public.is_member(ledger_id));
create policy settlements_update on public.settlements
  for update to authenticated using (public.is_member(ledger_id)) with check (public.is_member(ledger_id));
create policy settlements_delete on public.settlements
  for delete to authenticated using (public.is_member(ledger_id));

-- ---------- settlement_entries（跟隨 settlement 的帳本） ----------
create policy settlement_entries_select on public.settlement_entries
  for select to authenticated
  using (exists (select 1 from public.settlements s where s.id = settlement_id and public.is_member(s.ledger_id)));
create policy settlement_entries_insert on public.settlement_entries
  for insert to authenticated
  with check (exists (select 1 from public.settlements s where s.id = settlement_id and public.is_member(s.ledger_id)));
create policy settlement_entries_update on public.settlement_entries
  for update to authenticated
  using (exists (select 1 from public.settlements s where s.id = settlement_id and public.is_member(s.ledger_id)))
  with check (exists (select 1 from public.settlements s where s.id = settlement_id and public.is_member(s.ledger_id)));
create policy settlement_entries_delete on public.settlement_entries
  for delete to authenticated
  using (exists (select 1 from public.settlements s where s.id = settlement_id and public.is_member(s.ledger_id)));

-- ---------- settlement_approvals（只能插自己的簽名） ----------
create policy settlement_approvals_select on public.settlement_approvals
  for select to authenticated
  using (exists (select 1 from public.settlements s where s.id = settlement_id and public.is_member(s.ledger_id)));
create policy settlement_approvals_insert on public.settlement_approvals
  for insert to authenticated
  with check (exists (
    select 1 from public.settlements s
    where s.id = settlement_id and member_id = public.my_member_id(s.ledger_id)
  ));

-- ---------- entries（ADR-0003 private 只有作者可見） ----------
create policy entries_select on public.entries
  for select to authenticated
  using (
    public.is_member(ledger_id)
    and (scope = 'shared' or created_by = public.my_member_id(ledger_id))
  );

create policy entries_insert on public.entries
  for insert to authenticated
  with check (
    public.is_member(ledger_id)
    and created_by = public.my_member_id(ledger_id)
  );

create policy entries_update on public.entries
  for update to authenticated
  using (
    public.is_member(ledger_id)
    and (scope = 'shared' or created_by = public.my_member_id(ledger_id))
  )
  with check (
    public.is_member(ledger_id)
    and (scope = 'shared' or created_by = public.my_member_id(ledger_id))
  );

create policy entries_delete on public.entries
  for delete to authenticated
  using (
    public.is_member(ledger_id)
    and (scope = 'shared' or created_by = public.my_member_id(ledger_id))
  );

-- ---------- entry_splits / line_items ----------
-- 可見性與寫入權都跟隨父 entry：條件與 entries 的 select/update policy 逐字相同
-- （不只倚賴 entries 自身 RLS 在子查詢裡生效，明寫一次比較不會被日後改動繞過）。
create policy entry_splits_select on public.entry_splits
  for select to authenticated
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
create policy entry_splits_insert on public.entry_splits
  for insert to authenticated
  with check (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
create policy entry_splits_update on public.entry_splits
  for update to authenticated
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ))
  with check (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
create policy entry_splits_delete on public.entry_splits
  for delete to authenticated
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));

create policy line_items_select on public.line_items
  for select to authenticated
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
create policy line_items_insert on public.line_items
  for insert to authenticated
  with check (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
create policy line_items_update on public.line_items
  for update to authenticated
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ))
  with check (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
create policy line_items_delete on public.line_items
  for delete to authenticated
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
  ));
