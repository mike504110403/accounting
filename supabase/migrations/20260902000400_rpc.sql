-- Migration 0004 — RPC（前端唯一寫入結算／建帳本的入口）
-- 全部 security definer（search_path 固定 public）＋開頭檢查 auth.uid()；search_items 例外走 invoker 以吃 RLS。

-- ---------- 建帳本（首次登入用） ----------
create or replace function public.create_ledger(name text)
returns public.ledgers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ledger public.ledgers;
  v_member public.members;
  v_display text;
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

  insert into public.ledgers (name) values (btrim(name)) returning * into v_ledger;

  insert into public.members (ledger_id, user_id, display_name)
  values (v_ledger.id, v_uid, coalesce(v_display, '我'))
  returning * into v_member;

  update public.ledgers
    set default_ratio = jsonb_build_object(v_member.id::text, 100)
    where id = v_ledger.id
    returning * into v_ledger;

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

-- ---------- 以邀請碼加入 ----------
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
  v_ratio jsonb;
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

  -- 新成員加入後 default_ratio 重算成均分（原比例已不完整）。
  select jsonb_object_agg(
           t.id::text,
           t.base + case when t.rn <= 100 - t.base * t.cnt then 1 else 0 end
         )
    into v_ratio
  from (
    select m.id,
           row_number() over (order by m.joined_at, m.id) as rn,
           count(*) over () as cnt,
           (100 / count(*) over ())::int as base
    from public.members m
    where m.ledger_id = v_ledger.id
  ) t;

  update public.ledgers set default_ratio = coalesce(v_ratio, '{}'::jsonb)
    where id = v_ledger.id
    returning * into v_ledger;

  return v_ledger;
end;
$$;

-- ---------- 發起結算 ----------
-- 涵蓋：shared、expense、open、payer 非共同錢包、split_method <> common。
-- nets = Σ付出 − Σ分攤，四捨五入整數（ADR-0005）。發起人視同已簽（required_signers 已排除）。
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
  v_nets jsonb;
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

  select coalesce(array_agg(e.id), '{}'::uuid[])
    into v_entry_ids
  from public.entries e
  where e.ledger_id = ledger
    and e.scope = 'shared'
    and e.kind = 'expense'
    and e.settled_state = 'open'
    and e.payer_id is not null
    and e.split_method <> 'common';

  if coalesce(array_length(v_entry_ids, 1), 0) = 0 then
    raise exception 'initiate_settlement: no settleable entries' using errcode = 'P0001';
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

  insert into public.settlements (ledger_id, initiated_by, nets, status)
  values (ledger, v_me, v_nets, 'pending')
  returning * into v_settlement;

  insert into public.settlement_entries (settlement_id, entry_id)
  select v_settlement.id, x from unnest(v_entry_ids) x;

  update public.entries set settled_state = 'settling' where id = any (v_entry_ids);

  -- 沒人需要簽（只有發起人淨額非零）→ 當場落地。
  if not exists (select 1 from public.required_signers_internal(v_settlement.id)) then
    update public.settlements set status = 'settled', settled_at = now() where id = v_settlement.id;
    update public.entries set settled_state = 'settled' where id = any (v_entry_ids);
  end if;

  select * into v_settlement from public.settlements s where s.id = v_settlement.id;
  return v_settlement;
end;
$$;

-- ---------- 簽核（到齊由 trigger 落地） ----------
create or replace function public.approve_settlement(id uuid)
returns public.settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_settlement public.settlements;
  v_me uuid;
begin
  if v_uid is null then
    raise exception 'approve_settlement: not authenticated' using errcode = '28000';
  end if;

  select * into v_settlement from public.settlements s where s.id = approve_settlement.id;
  if not found then
    raise exception 'approve_settlement: settlement not found' using errcode = 'P0001';
  end if;

  v_me := public.my_member_id(v_settlement.ledger_id);
  if v_me is null then
    raise exception 'approve_settlement: not a member' using errcode = '42501';
  end if;

  if v_settlement.status <> 'pending' then
    raise exception 'approve_settlement: settlement is not pending' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.required_signers_internal(v_settlement.id) rs where rs = v_me) then
    raise exception 'approve_settlement: not a required signer' using errcode = '42501';
  end if;

  insert into public.settlement_approvals (settlement_id, member_id)
  values (v_settlement.id, v_me)
  on conflict (settlement_id, member_id) do nothing;

  select * into v_settlement from public.settlements s where s.id = approve_settlement.id;
  return v_settlement;
end;
$$;

-- ---------- 搜尋（security invoker：直接吃 RLS，私人筆別人搜不到） ----------
create or replace function public.search_items(ledger uuid, q text)
returns table (
  kind text,
  id uuid,
  entry_id uuid,
  name text,
  amount int,
  occurred_on date,
  category_id uuid,
  note text
)
language plpgsql
stable
security invoker
set search_path = public
as $$
#variable_conflict use_column
declare
  v_q text;
begin
  if auth.uid() is null then
    raise exception 'search_items: not authenticated' using errcode = '28000';
  end if;
  if q is null or btrim(q) = '' then
    return;
  end if;
  v_q := '%' || btrim(q) || '%';

  return query
    select 'line_item'::text, li.id, li.entry_id, li.name, li.amount, e.occurred_on, e.category_id, e.note
      from public.line_items li
      join public.entries e on e.id = li.entry_id
     where e.ledger_id = search_items.ledger and li.name ilike v_q
    union all
    select 'entry'::text, e.id, e.id, e.note, e.amount, e.occurred_on, e.category_id, e.note
      from public.entries e
     where e.ledger_id = search_items.ledger and e.note ilike v_q
    union all
    select 'list_item'::text, l.id, l.entry_id, l.title, l.estimated, l.due_on, l.category_id, coalesce(l.store, '')
      from public.list_items l
     where l.ledger_id = search_items.ledger and l.title ilike v_q
    order by 6 desc nulls last, 4 asc;
end;
$$;

-- ---------- 授權 ----------
revoke all on function public.create_ledger(text) from public;
revoke all on function public.join_ledger(text) from public;
revoke all on function public.initiate_settlement(uuid) from public;
revoke all on function public.approve_settlement(uuid) from public;
revoke all on function public.required_signers(uuid) from public;
revoke all on function public.search_items(uuid, text) from public;
revoke all on function public.gen_invite_code() from public;

grant execute on function public.create_ledger(text) to authenticated;
grant execute on function public.join_ledger(text) to authenticated;
grant execute on function public.initiate_settlement(uuid) to authenticated;
grant execute on function public.approve_settlement(uuid) to authenticated;
grant execute on function public.required_signers(uuid) to authenticated;
grant execute on function public.search_items(uuid, text) to authenticated;
