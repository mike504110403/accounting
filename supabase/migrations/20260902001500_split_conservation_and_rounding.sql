-- Migration 0015 — 分攤守恆 constraint trigger ＋ 淨額最大餘數法 ＋ 併發鎖（review 13／14／20，併 6）

-- ---------- 14：分攤加總 = 主筆金額（deferred，允許同交易先 insert entry 再 insert splits） ----------
-- 只在「該 entry 目前至少有一列分攤」時檢查：
-- 清空分攤（改成共同錢包／common）與「先建 entry、之後才建分攤」這兩條路都要能走。
create or replace function public.entry_splits_sum_check()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_entry uuid;
  v_amount int;
  v_method public.split_method;
  v_scope public.entry_scope;
  v_count int;
  v_sum numeric;
begin
  if TG_OP = 'DELETE' then
    v_entry := OLD.entry_id;
  else
    v_entry := NEW.entry_id;
  end if;

  select e.amount, e.split_method, e.scope
    into v_amount, v_method, v_scope
  from public.entries e where e.id = v_entry;
  if not found then
    return null;                      -- 父 entry 已被刪（cascade），不必檢查
  end if;
  if v_method = 'common' or v_scope = 'private' then
    return null;                      -- 不分攤的筆別
  end if;

  select count(*), coalesce(sum(s.share), 0)
    into v_count, v_sum
  from public.entry_splits s where s.entry_id = v_entry;
  if v_count = 0 then
    return null;                      -- 還沒建／已清空
  end if;

  if abs(v_sum - v_amount) >= 0.01 then
    raise exception 'entry %: splits (%) do not sum to amount (%)', v_entry, v_sum, v_amount
      using errcode = 'P0001';
  end if;
  return null;
end;
$$;
revoke execute on function public.entry_splits_sum_check() from anon, authenticated, public;

create constraint trigger entry_splits_sum_check_trg
  after insert or update or delete on public.entry_splits
  deferrable initially deferred
  for each row execute function public.entry_splits_sum_check();

-- ---------- 13＋20：發起結算加交易鎖，淨額改最大餘數法 ----------
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
  v_settlement public.settlements;
begin
  if v_uid is null then
    raise exception 'initiate_settlement: not authenticated' using errcode = '28000';
  end if;

  v_me := public.my_member_id(ledger);
  if v_me is null then
    raise exception 'initiate_settlement: not a member' using errcode = '42501';
  end if;

  -- 13：同一帳本序列化，兩個人同時按「結算」不會各建一筆。
  -- （另有 partial unique index settlements_one_pending_per_ledger_idx 當資料層保證。）
  perform pg_advisory_xact_lock(hashtextextended(ledger::text, 0));

  if exists (select 1 from public.settlements s where s.ledger_id = ledger and s.status = 'pending') then
    raise exception 'initiate_settlement: a pending settlement already exists' using errcode = 'P0001';
  end if;

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

  select e.id into v_bad
  from public.entries e
  where e.id = any (v_entry_ids)
    and abs(coalesce((select sum(s.share) from public.entry_splits s where s.entry_id = e.id), 0) - e.amount) >= 0.01
  limit 1;
  if v_bad is not null then
    raise exception 'entry %: splits do not sum to amount', v_bad using errcode = 'P0001';
  end if;

  -- 20：最大餘數法。全員先 floor，差額依小數部分由大到小各補 1（同小數以 member_id 決定順序）。
  -- 這樣 Σnets 恆為 0；先前用 round() 會出現 9.5/9.5/−19 這種 Σ = −1 的情形。
  select coalesce(jsonb_object_agg(r.mid::text, (r.fl + case when r.rn <= r.remainder then 1 else 0 end)), '{}'::jsonb)
    into v_nets
  from (
    select f.mid,
           f.fl,
           row_number() over (order by f.frac desc, f.mid) as rn,
           (0 - sum(f.fl) over ())::int as remainder
    from (
      select b.mid,
             floor(b.exact)::int as fl,
             b.exact - floor(b.exact) as frac
      from (
        select m.id as mid,
               (coalesce(p.paid, 0) - coalesce(o.owed, 0))::numeric as exact
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
      ) b
    ) f
  ) r;

  if not exists (select 1 from jsonb_each_text(v_nets) kv where kv.value::int <> 0) then
    raise exception 'initiate_settlement: nothing to settle' using errcode = 'P0001';
  end if;

  -- 守恆：最大餘數法保證 Σ = 0，這裡是「算錯就不要落地」的最後一道。
  select coalesce(sum(kv.value::int), 0) into v_net_sum from jsonb_each_text(v_nets) kv;
  if v_net_sum <> 0 then
    raise exception 'initiate_settlement: nets do not balance (sum = %)', v_net_sum using errcode = 'P0001';
  end if;

  insert into public.settlements (ledger_id, initiated_by, nets, status)
  values (ledger, v_me, v_nets, 'pending')
  returning * into v_settlement;

  insert into public.settlement_entries (settlement_id, entry_id)
  select v_settlement.id, x from unnest(v_entry_ids) x;

  insert into public.settlement_signers (settlement_id, member_id)
  select v_settlement.id, (kv.key)::uuid
  from jsonb_each_text(v_nets) kv
  where kv.value::int <> 0
    and (kv.key)::uuid <> v_me;

  update public.entries set settled_state = 'settling' where id = any (v_entry_ids);

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
