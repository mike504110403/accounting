-- Migration 0003 — trigger（ADR-0002：settled 鎖金額、settling 期間改動 void、多簽到齊落 settled）

-- 需簽者＝nets 非零成員 − 發起人（ADR-0002）。
-- 定義放 0003 是因為 0003 的多簽 trigger 要用；0004 只補授權與契約說明。
create or replace function public.required_signers(p_settlement uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'required_signers: not authenticated' using errcode = '28000';
  end if;
  return query
    select (kv.key)::uuid
    from public.settlements s
    cross join lateral jsonb_each_text(s.nets) kv
    where s.id = p_settlement
      and kv.value::int <> 0
      and (kv.key)::uuid <> s.initiated_by;
end;
$$;

-- trigger 內部要用（此時無 auth.uid()），另備一支不檢查登入的內部版。
create or replace function public.required_signers_internal(p_settlement uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select (kv.key)::uuid
  from public.settlements s
  cross join lateral jsonb_each_text(s.nets) kv
  where s.id = p_settlement
    and kv.value::int <> 0
    and (kv.key)::uuid <> s.initiated_by;
$$;

revoke all on function public.required_signers_internal(uuid) from public;

-- ---------- 1. settled 鎖住金額／payer／split／scope／kind ----------
create or replace function public.entries_lock_settled()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if OLD.settled_state = 'settled' and (
       NEW.amount is distinct from OLD.amount
    or NEW.payer_id is distinct from OLD.payer_id
    or NEW.split_method is distinct from OLD.split_method
    or NEW.scope is distinct from OLD.scope
    or NEW.kind is distinct from OLD.kind
  ) then
    raise exception 'entry settled: amount locked' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

create trigger entries_lock_settled_trg
  before update on public.entries
  for each row execute function public.entries_lock_settled();

-- settled 的 entry 也不許改分攤（ADR-0002「split 鎖住」）。
-- 只擋 insert/update：cascade 刪除父 entry 時只會走 delete，不受影響。
create or replace function public.entry_splits_lock_settled()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (select 1 from public.entries e where e.id = NEW.entry_id and e.settled_state = 'settled') then
    raise exception 'entry settled: split locked' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

create trigger entry_splits_lock_settled_trg
  before insert or update on public.entry_splits
  for each row execute function public.entry_splits_lock_settled();

-- ---------- 2. settling 期間任何改動 → settlement void、涵蓋 entries 回 open ----------
create or replace function public.void_settlements_for_entry(p_entry uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement uuid;
begin
  for v_settlement in
    select se.settlement_id
    from public.settlement_entries se
    join public.settlements s on s.id = se.settlement_id
    where se.entry_id = p_entry and s.status = 'pending'
  loop
    update public.settlements set status = 'void' where id = v_settlement;
    update public.entries
      set settled_state = 'open'
      where settled_state = 'settling'
        and id in (select entry_id from public.settlement_entries where settlement_id = v_settlement);
  end loop;
end;
$$;

revoke all on function public.void_settlements_for_entry(uuid) from public;

create or replace function public.entries_void_pending_settlement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.settled_state = 'settling' then
    perform public.void_settlements_for_entry(OLD.id);
  end if;
  return null;
end;
$$;

-- 欄位限定：只有實質欄位被寫才 void。
-- settled_state 不在清單裡，所以 void（settling→open）與多簽落地（settling→settled）
-- 這兩條系統自己的搬狀態路徑不會回頭觸發自己，不需要 session 旗標守衛。
create trigger entries_void_pending_settlement_trg
  after update of amount, payer_id, split_method, scope, kind or delete on public.entries
  for each row execute function public.entries_void_pending_settlement();

create or replace function public.entry_splits_void_pending_settlement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry uuid;
  v_state public.settled_state;
begin
  if TG_OP = 'DELETE' then
    v_entry := OLD.entry_id;
  else
    v_entry := NEW.entry_id;
  end if;
  select e.settled_state into v_state from public.entries e where e.id = v_entry;
  if v_state = 'settling' then
    perform public.void_settlements_for_entry(v_entry);
  end if;
  return null;
end;
$$;

-- 同理欄位限定：分攤的實質欄位是 share 與 member_id。
create trigger entry_splits_void_pending_settlement_trg
  after insert or delete or update of share, member_id on public.entry_splits
  for each row execute function public.entry_splits_void_pending_settlement();

-- ---------- 3. 簽名到齊 → settlement settled、涵蓋 entries settled ----------
create or replace function public.settlement_finalize_on_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status public.settlement_status;
  v_missing int;
begin
  select s.status into v_status from public.settlements s where s.id = NEW.settlement_id;
  if v_status is distinct from 'pending' then
    return null;
  end if;

  select count(*) into v_missing
  from public.required_signers_internal(NEW.settlement_id) rs
  where not exists (
    select 1 from public.settlement_approvals a
    where a.settlement_id = NEW.settlement_id and a.member_id = rs
  );

  if v_missing > 0 then
    return null;
  end if;

  -- 只改 settled_state，不碰 void trigger 監看的欄位。
  update public.settlements
    set status = 'settled', settled_at = now()
    where id = NEW.settlement_id;
  update public.entries
    set settled_state = 'settled'
    where settled_state = 'settling'
      and id in (select entry_id from public.settlement_entries where settlement_id = NEW.settlement_id);
  return null;
end;
$$;

create trigger settlement_finalize_on_approval_trg
  after insert on public.settlement_approvals
  for each row execute function public.settlement_finalize_on_approval();
