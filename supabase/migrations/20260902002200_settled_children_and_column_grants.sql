-- Migration 0022 — upsert_entry 對已結帳的子表態度、ledgers／members 欄位級授權（複審輪三 Q／R）

-- ---------- R：ledgers／members 也改欄位級 UPDATE ----------
-- ledgers：只開帳本設定會用到的三欄。invite_code 不給寫——輪替走 rotate_invite_code，
-- 否則任何成員都能把邀請碼改成自己記得住的字串（等於自選密碼）。
revoke update on public.ledgers from authenticated;
grant update (name, default_ratio, opening_balance_shared) on public.ledgers to authenticated;

-- members：只開暱稱與個人期初餘額。
revoke update on public.members from authenticated;
grant update (display_name, opening_balance_personal) on public.members to authenticated;

create or replace function public.rotate_invite_code(ledger uuid)
returns public.ledgers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ledger public.ledgers;
  v_try int := 0;
begin
  if auth.uid() is null then
    raise exception 'rotate_invite_code: not authenticated' using errcode = '28000';
  end if;
  if public.my_member_id(ledger) is null then
    raise exception 'rotate_invite_code: not a member' using errcode = '42501';
  end if;

  loop
    v_try := v_try + 1;
    begin
      update public.ledgers l
        set invite_code = public.gen_invite_code()
        where l.id = rotate_invite_code.ledger
        returning * into v_ledger;
      exit;
    exception when unique_violation then
      if v_try >= 5 then
        raise exception 'rotate_invite_code: could not allocate an invite code' using errcode = 'P0001';
      end if;
    end;
  end loop;

  if v_ledger.id is null then
    raise exception 'rotate_invite_code: ledger not found' using errcode = 'P0001';
  end if;
  return v_ledger;
end;
$$;
revoke execute on function public.rotate_invite_code(uuid) from anon, public;
grant execute on function public.rotate_invite_code(uuid) to authenticated;

-- ---------- Q：upsert_entry 對已結帳的帳目不能半套 ----------
-- 兩個問題：
--  (1) settled 的帳目若帶了 p_splits／p_line_items，分攤會被 delete policy 靜默過濾（0 列）而保住，
--      細項卻真的被刪掉——一半成功一半失敗，而且沒有任何錯誤訊息。
--  (2) 就算不是 settled，只要 RLS 把某些子表列過濾掉，全刪重建也會悄悄掉資料。
-- 修法：開頭就讀 settled_state，settled 且要動子表就直接 raise；
--      刪除後比對 row_count 與刪除前的筆數，對不上就 raise，不留半套狀態。
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
