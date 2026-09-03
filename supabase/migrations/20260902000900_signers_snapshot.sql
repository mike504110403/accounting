-- Migration 0009 — 需簽者快照 ＋ 結算狀態機 ＋ cancel_settlement（review BLOCKER 1／2／3、MINOR 8）
--
-- BLOCKER 2：需簽者原本是從 settlements.nets 現算的，而 nets 是可寫欄位。
-- 發起人只要把對方的淨額改成 0，需簽者名單當場變空，自己插一筆簽名就 settled。
-- 修法：發起當下把需簽者「快照」進 settlement_signers，之後只讀這張表，不再現算。

-- ---------- 需簽者快照表 ----------
create table public.settlement_signers (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (settlement_id, member_id)
);
create index settlement_signers_settlement_idx on public.settlement_signers (settlement_id);

alter table public.settlement_signers enable row level security;

-- 成員只可 select；寫入只有 security definer 的 RPC 做得到（沒有 insert/update/delete 授權）。
revoke all on public.settlement_signers from anon, authenticated, public;
grant select on public.settlement_signers to authenticated;

create policy settlement_signers_select on public.settlement_signers
  for select to authenticated
  using (exists (
    select 1 from public.settlements s
    where s.id = settlement_id and public.is_member(s.ledger_id)
  ));

-- ---------- 需簽者一律讀快照 ----------
create or replace function public.required_signers_internal(p_settlement uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select ss.member_id
  from public.settlement_signers ss
  where ss.settlement_id = p_settlement;
$$;
revoke execute on function public.required_signers_internal(uuid) from anon, authenticated, public;

-- MINOR 8：非該帳本成員不得窺探需簽者名單。
create or replace function public.required_signers(p_settlement uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ledger uuid;
begin
  if auth.uid() is null then
    raise exception 'required_signers: not authenticated' using errcode = '28000';
  end if;
  select s.ledger_id into v_ledger from public.settlements s where s.id = p_settlement;
  if v_ledger is null then
    raise exception 'required_signers: settlement not found' using errcode = 'P0001';
  end if;
  if public.my_member_id(v_ledger) is null then
    raise exception 'required_signers: not a member' using errcode = '42501';
  end if;
  return query
    select ss.member_id from public.settlement_signers ss where ss.settlement_id = p_settlement;
end;
$$;
revoke execute on function public.required_signers(uuid) from anon, public;
grant execute on function public.required_signers(uuid) to authenticated;

-- ---------- BLOCKER 3：settlements 狀態機 ＋ 身分欄位不可變 ----------
create or replace function public.settlements_status_machine()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW.ledger_id is distinct from OLD.ledger_id then
    raise exception 'settlement: ledger_id is immutable' using errcode = 'P0001';
  end if;
  if NEW.initiated_by is distinct from OLD.initiated_by then
    raise exception 'settlement: initiated_by is immutable' using errcode = 'P0001';
  end if;
  -- nets 是淨額的定案，落款後不得再動（BLOCKER 2 的第二道防線）。
  if NEW.nets is distinct from OLD.nets then
    raise exception 'settlement: nets is immutable' using errcode = 'P0001';
  end if;
  if NEW.status is distinct from OLD.status then
    if OLD.status <> 'pending' then
      raise exception 'settlement: status % is final', OLD.status using errcode = 'P0001';
    end if;
    if NEW.status not in ('settled', 'void') then
      raise exception 'settlement: illegal transition % -> %', OLD.status, NEW.status using errcode = 'P0001';
    end if;
  end if;
  return NEW;
end;
$$;
revoke execute on function public.settlements_status_machine() from anon, authenticated, public;

create trigger settlements_status_machine_trg
  before update on public.settlements
  for each row execute function public.settlements_status_machine();

-- ---------- 簽名只收快照名單內的人，且只在 pending 期間 ----------
create or replace function public.settlement_approvals_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_status public.settlement_status;
begin
  select s.status into v_status from public.settlements s where s.id = NEW.settlement_id;
  if v_status is null then
    raise exception 'settlement approval: settlement not found' using errcode = 'P0001';
  end if;
  if v_status <> 'pending' then
    raise exception 'settlement approval: settlement is not pending' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.settlement_signers ss
    where ss.settlement_id = NEW.settlement_id and ss.member_id = NEW.member_id
  ) then
    raise exception 'settlement approval: not a required signer' using errcode = '42501';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.settlement_approvals_guard() from anon, authenticated, public;

create trigger settlement_approvals_guard_trg
  before insert on public.settlement_approvals
  for each row execute function public.settlement_approvals_guard();

-- ---------- 取消結算（settlements 收成唯讀後，取消也要有入口） ----------
create or replace function public.cancel_settlement(id uuid)
returns public.settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement public.settlements;
  v_me uuid;
begin
  if auth.uid() is null then
    raise exception 'cancel_settlement: not authenticated' using errcode = '28000';
  end if;

  select * into v_settlement from public.settlements s where s.id = cancel_settlement.id;
  if not found then
    raise exception 'cancel_settlement: settlement not found' using errcode = 'P0001';
  end if;

  v_me := public.my_member_id(v_settlement.ledger_id);
  if v_me is null then
    raise exception 'cancel_settlement: not a member' using errcode = '42501';
  end if;

  if v_settlement.status <> 'pending' then
    raise exception 'cancel_settlement: settlement is not pending' using errcode = 'P0001';
  end if;

  -- 發起人或任一需簽者可取消。
  if v_settlement.initiated_by <> v_me
     and not exists (select 1 from public.settlement_signers ss
                     where ss.settlement_id = v_settlement.id and ss.member_id = v_me) then
    raise exception 'cancel_settlement: only the initiator or a required signer may cancel'
      using errcode = '42501';
  end if;

  update public.settlements set status = 'void' where settlements.id = v_settlement.id;
  update public.entries
    set settled_state = 'open'
    where entries.settled_state = 'settling'
      and entries.id in (
        select se.entry_id from public.settlement_entries se where se.settlement_id = v_settlement.id
      );

  select * into v_settlement from public.settlements s where s.id = cancel_settlement.id;
  return v_settlement;
end;
$$;

revoke execute on function public.cancel_settlement(uuid) from anon, public;
grant execute on function public.cancel_settlement(uuid) to authenticated;
