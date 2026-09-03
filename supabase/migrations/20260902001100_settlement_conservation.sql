-- Migration 0011 — 結算守恆與需簽者快照（review MAJOR 6、BLOCKER 2 的寫入端）
--
-- MAJOR 6：涵蓋條件只看 split_method <> 'common'，沒檢查真的有分攤列。
-- 一筆 equal 但沒有 entry_splits 的代墊會整筆算進「付出」卻沒有任何人「分攤」，
-- nets 直接不守恆（實測 Σnets = 10001）。
create or replace function public.initiate_settlement(ledger uuid)
returns public.settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me uuid;
  v_entry_ids uuid[];
  v_bad uuid;
  v_nets jsonb;
  v_net_sum bigint;
  v_member_count int;
  v_settlement public.settlements;
begin
  if v_uid is null then
    raise exception 'initiate_settlement: not authenticated' using errcode = '28000';
  end if;

  v_me := public.my_member_id(ledger);
  if v_me is null then
    raise exception 'initiate_settlement: not a member' using errcode = '42501';
  end if;

  if exists (select 1 from public.settlements s where s.ledger_id = ledger and s.status = 'pending') then
    raise exception 'initiate_settlement: a pending settlement already exists' using errcode = 'P0001';
  end if;

  -- 涵蓋：shared、expense、open、payer 非共同錢包、split <> common，且**真的有分攤列**。
  select coalesce(array_agg(e.id), '{}'::uuid[])
    into v_entry_ids
  from public.entries e
  where e.ledger_id = ledger
    and e.scope = 'shared'
    and e.kind = 'expense'
    and e.settled_state = 'open'
    and e.payer_id is not null
    and e.split_method <> 'common'
    and exists (select 1 from public.entry_splits s where s.entry_id = e.id);

  if coalesce(array_length(v_entry_ids, 1), 0) = 0 then
    raise exception 'initiate_settlement: no settleable entries' using errcode = 'P0001';
  end if;

  -- 逐筆守恆：Σshare 必須等於主筆金額（容差 0.01，分攤是 numeric(12,2)）。
  select e.id into v_bad
  from public.entries e
  where e.id = any (v_entry_ids)
    and abs(coalesce((select sum(s.share) from public.entry_splits s where s.entry_id = e.id), 0) - e.amount) >= 0.01
  limit 1;
  if v_bad is not null then
    raise exception 'entry %: splits do not sum to amount', v_bad using errcode = 'P0001';
  end if;

  select coalesce(jsonb_object_agg(t.member_id::text, t.net), '{}'::jsonb)
    into v_nets
  from (
    select m.id as member_id,
           round(coalesce(p.paid, 0) - coalesce(o.owed, 0))::int as net
    from public.members m
    left join (
      select e.payer_id as mid, sum(e.amount)::numeric as paid
      from public.entries e where e.id = any (v_entry_ids) group by e.payer_id
    ) p on p.mid = m.id
    left join (
      select s.member_id as mid, sum(s.share) as owed
      from public.entry_splits s where s.entry_id = any (v_entry_ids) group by s.member_id
    ) o on o.mid = m.id
    where m.ledger_id = ledger
  ) t;

  if not exists (select 1 from jsonb_each_text(v_nets) kv where kv.value::int <> 0) then
    raise exception 'initiate_settlement: nothing to settle' using errcode = 'P0001';
  end if;

  -- 整體守恆：Σnets 理論上為 0，四捨五入每人最多差 1 元。
  select coalesce(sum(kv.value::int), 0) into v_net_sum from jsonb_each_text(v_nets) kv;
  select count(*) into v_member_count from public.members m where m.ledger_id = ledger;
  if abs(v_net_sum) > v_member_count then
    raise exception 'initiate_settlement: nets do not balance (sum = %)', v_net_sum using errcode = 'P0001';
  end if;

  insert into public.settlements (ledger_id, initiated_by, nets, status)
  values (ledger, v_me, v_nets, 'pending')
  returning * into v_settlement;

  insert into public.settlement_entries (settlement_id, entry_id)
  select v_settlement.id, x from unnest(v_entry_ids) x;

  -- BLOCKER 2：需簽者在此刻定案並快照，之後只讀這張表（nets 也已設為不可變）。
  insert into public.settlement_signers (settlement_id, member_id)
  select v_settlement.id, (kv.key)::uuid
  from jsonb_each_text(v_nets) kv
  where kv.value::int <> 0
    and (kv.key)::uuid <> v_me;

  update public.entries set settled_state = 'settling' where id = any (v_entry_ids);

  -- 沒人需要簽（只有發起人淨額非零）→ 當場落地。
  if not exists (select 1 from public.settlement_signers ss where ss.settlement_id = v_settlement.id) then
    update public.settlements set status = 'settled', settled_at = now() where id = v_settlement.id;
    update public.entries set settled_state = 'settled' where id = any (v_entry_ids);
  end if;

  select * into v_settlement from public.settlements s where s.id = v_settlement.id;
  return v_settlement;
end;
$$;

revoke execute on function public.initiate_settlement(uuid) from anon, public;
grant execute on function public.initiate_settlement(uuid) to authenticated;
