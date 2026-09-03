-- Migration 0008 — 授權收斂（review BLOCKER 1／3／7）
--
-- 三個發現：
--  (1) settlements／settlement_entries 對 authenticated 有 insert/update/delete，
--      成員可以直接寫一筆 status='settled' 的結算，完全繞過多簽。
--  (3) entries 是整表 update 權，成員可以直接把 settled_state 搬成 'settled'。
--  (7) Supabase 對 public schema 有 default privileges 授權給 anon/authenticated，
--      `revoke ... from public` 擋不住（PUBLIC 與具名角色是兩回事），內部函式一路裸奔。

-- ---------- anon 一律無權（全靠 RLS 擋是不夠的，權限層先關門） ----------
revoke all on
  public.ledgers, public.members, public.categories, public.entries,
  public.entry_splits, public.line_items, public.settlements,
  public.settlement_entries, public.settlement_approvals,
  public.budgets, public.list_items
from anon;

-- ---------- (1) settlements／settlement_entries：authenticated 只讀 ----------
-- 寫入一律走 RPC（initiate_settlement／approve_settlement／cancel_settlement）。
revoke insert, update, delete on public.settlements from authenticated;
revoke insert, update, delete on public.settlement_entries from authenticated;

drop policy if exists settlements_insert on public.settlements;
drop policy if exists settlements_update on public.settlements;
drop policy if exists settlements_delete on public.settlements;
drop policy if exists settlement_entries_insert on public.settlement_entries;
drop policy if exists settlement_entries_update on public.settlement_entries;
drop policy if exists settlement_entries_delete on public.settlement_entries;

-- ---------- (3) entries：欄位級 update 授權 ----------
-- settled_state／created_by／ledger_id 不在清單裡：狀態機只有 RPC 與 trigger 能推。
revoke update on public.entries from authenticated;
grant update (
  kind, scope, amount, category_id, occurred_on, note,
  payer_id, split_method, is_adjustment
) on public.entries to authenticated;

-- ---------- (7) 內部函式：明列角色 revoke ----------
-- trigger 函式不需要 EXECUTE 權限也會被 trigger 呼叫（以表 owner 身分執行），revoke 是安全的。
revoke execute on function public.gen_invite_code() from anon, authenticated, public;
revoke execute on function public.required_signers_internal(uuid) from anon, authenticated, public;
revoke execute on function public.void_settlements_for_entry(uuid) from anon, authenticated, public;
revoke execute on function public.entries_lock_settled() from anon, authenticated, public;
revoke execute on function public.entry_splits_lock_settled() from anon, authenticated, public;
revoke execute on function public.entries_void_pending_settlement() from anon, authenticated, public;
revoke execute on function public.entry_splits_void_pending_settlement() from anon, authenticated, public;
revoke execute on function public.settlement_finalize_on_approval() from anon, authenticated, public;
revoke execute on function public.entries_immutable_identity() from anon, authenticated, public;

-- 對外的函式也把 anon 拿掉（全部都要求 auth.uid()，anon 呼叫只會 raise，不如直接沒權限）。
revoke execute on function public.is_member(uuid) from anon, public;
revoke execute on function public.my_member_id(uuid) from anon, public;
revoke execute on function public.required_signers(uuid) from anon, public;
revoke execute on function public.create_ledger(text) from anon, public;
revoke execute on function public.join_ledger(text) from anon, public;
revoke execute on function public.initiate_settlement(uuid) from anon, public;
revoke execute on function public.approve_settlement(uuid) from anon, public;
revoke execute on function public.search_items(uuid, text) from anon, public;

-- ---------- (7) void_settlements_for_entry 補 auth 檢查 ----------
-- 權限已經關了，這是第二道：直接呼叫（不在 trigger 內）時必須有登入身分。
create or replace function public.void_settlements_for_entry(p_entry uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement uuid;
begin
  if pg_trigger_depth() = 0 and auth.uid() is null then
    raise exception 'void_settlements_for_entry: not authenticated' using errcode = '28000';
  end if;
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

revoke execute on function public.void_settlements_for_entry(uuid) from anon, authenticated, public;
