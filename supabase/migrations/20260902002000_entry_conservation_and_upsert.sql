-- Migration 0020 — 守恆守雙側 ＋ upsert_entry（複審輪二 I）
--
-- 先前守恆只掛在 entry_splits：成員改 entries.amount 而不動分攤，
-- Σshare 就跟 amount 對不上，一路到發起結算才被擋。這裡補上 entries 側，
-- 並提供一個「同一交易寫完 entry ＋ 整組 splits ＋ line_items」的 RPC 當正式入口。

-- ---------- I(1)：entries 側的守恆（deferred） ----------
create or replace function public.entries_split_sum_check()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_count int;
  v_sum numeric;
begin
  if NEW.split_method = 'common' or NEW.scope = 'private' then
    return null;
  end if;
  select count(*), coalesce(sum(s.share), 0)
    into v_count, v_sum
  from public.entry_splits s where s.entry_id = NEW.id;
  if v_count = 0 then
    return null;                      -- 沒有分攤列＝共同錢包／尚未建立
  end if;
  if abs(v_sum - NEW.amount) >= 0.01 then
    raise exception 'entry %: splits (%) do not sum to amount (%)', NEW.id, v_sum, NEW.amount
      using errcode = 'P0001',
            hint = '改金額請連同分攤一起改（建議走 upsert_entry RPC，同一交易寫完）';
  end if;
  return null;
end;
$$;
revoke execute on function public.entries_split_sum_check() from anon, authenticated, public;

create constraint trigger entries_split_sum_check_trg
  after update on public.entries
  deferrable initially deferred
  for each row execute function public.entries_split_sum_check();

-- ---------- I(2)：帶分攤的寫入入口 ----------
-- security invoker：RLS 與欄位級授權照常生效，這支只提供「同一交易」的原子性。
-- 子表全刪重建；deferred 守恆在交易結束時才驗，所以中間的空窗不會誤擋。
create or replace function public.upsert_entry(
  p_entry jsonb,
  p_splits jsonb default '[]'::jsonb,
  p_line_items jsonb default '[]'::jsonb
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

  -- 子表全刪重建（settled 的 entry 會在這一步被 delete policy／lock trigger 擋下）。
  delete from public.entry_splits where entry_id = v_entry.id;
  insert into public.entry_splits (entry_id, member_id, share)
  select v_entry.id, (x ->> 'member_id')::uuid, (x ->> 'share')::numeric
  from jsonb_array_elements(coalesce(p_splits, '[]'::jsonb)) x;

  delete from public.line_items where entry_id = v_entry.id;
  insert into public.line_items (entry_id, name, amount, sort)
  select v_entry.id, x ->> 'name', nullif(x ->> 'amount', '')::int, coalesce((x ->> 'sort')::int, 0)
  from jsonb_array_elements(coalesce(p_line_items, '[]'::jsonb)) x;

  select * into v_entry from public.entries e where e.id = v_entry.id;
  return v_entry;
end;
$$;

revoke execute on function public.upsert_entry(jsonb, jsonb, jsonb) from anon, public;
grant execute on function public.upsert_entry(jsonb, jsonb, jsonb) to authenticated;
