-- Migration 0021 — upsert_entry 子表語意、守恆 trigger 重讀列、函式 default privileges（複審輪三 K／L／M）

-- ---------- M：新函式不再自動對前端開放 ----------
-- 表已在 0018 關掉，函式這邊補上；否則波 2 新增的函式又會自動 grant execute 給 anon/authenticated。
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public '
       || 'revoke execute on functions from anon, authenticated, public';
  execute 'alter default privileges for role supabase_admin in schema public '
       || 'revoke all on tables from anon, authenticated';
exception when others then
  raise notice '略過 supabase_admin 的 default privileges：%', sqlerrm;
end;
$$;

-- ---------- L：entries 側守恆改成「重讀當前列」 ----------
-- 原本直接用 NEW.amount：deferred trigger 是在事件當下把 NEW 存起來、到 commit 才跑，
-- 所以「同一交易先改壞再改回來」會拿著中途那個 NEW 去比對而誤擋。
-- 改成 commit 時重讀該列，與 entry_splits 側的作法一致。
create or replace function public.entries_split_sum_check()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_amount int;
  v_method public.split_method;
  v_scope public.entry_scope;
  v_count int;
  v_sum numeric;
begin
  select e.amount, e.split_method, e.scope
    into v_amount, v_method, v_scope
  from public.entries e where e.id = NEW.id;
  if not found then
    return null;                      -- 同交易內已被刪掉
  end if;
  if v_method = 'common' or v_scope = 'private' then
    return null;
  end if;
  select count(*), coalesce(sum(s.share), 0)
    into v_count, v_sum
  from public.entry_splits s where s.entry_id = NEW.id;
  if v_count = 0 then
    return null;                      -- 沒有分攤列＝共同錢包／尚未建立
  end if;
  if abs(v_sum - v_amount) >= 0.01 then
    raise exception 'entry %: splits (%) do not sum to amount (%)', NEW.id, v_sum, v_amount
      using errcode = 'P0001',
            hint = '改金額請連同分攤一起改（建議走 upsert_entry RPC，同一交易寫完）';
  end if;
  return null;
end;
$$;
revoke execute on function public.entries_split_sum_check() from anon, authenticated, public;

-- ---------- K：p_splits／p_line_items 的 null 與 [] 分家 ----------
-- 舊版兩者都預設 '[]'，於是「只改個備註」會把分攤與細項全部清掉。
-- 新語意：null（或省略）＝完全不動那張子表；[] ＝清空。
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

  -- null ＝ 不動；[] ＝ 清空；有內容 ＝ 全刪重建。
  if p_splits is not null then
    delete from public.entry_splits where entry_id = v_entry.id;
    insert into public.entry_splits (entry_id, member_id, share)
    select v_entry.id, (x ->> 'member_id')::uuid, (x ->> 'share')::numeric
    from jsonb_array_elements(p_splits) x;
  end if;

  if p_line_items is not null then
    delete from public.line_items where entry_id = v_entry.id;
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
