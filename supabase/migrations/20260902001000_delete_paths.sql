-- Migration 0010 — 刪除路徑（review BLOCKER 4、MAJOR 5）
--
-- BLOCKER 4：void 的 delete trigger 原本掛 after delete，
-- 但 settlement_entries 的 FK cascade 也是 after delete，實際執行時連結列已經先被清掉，
-- void_settlements_for_entry 找不到任何 pending settlement → 結算卡在 pending、其餘 entries 永遠停在 settling。
-- 修法：改成 before delete（早於 cascade），函式回傳 OLD。
-- MAJOR 5：已結帳的 entry 金額鎖住卻刪得掉，等於繞過鎖定。before delete 一併擋。

create or replace function public.entries_before_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement uuid;
begin
  -- MAJOR 5：settled 不可刪，金額有誤請開修正筆（ADR-0002）。
  if OLD.settled_state = 'settled' then
    raise exception 'entry settled: delete blocked, use an adjustment entry' using errcode = 'P0001';
  end if;

  -- BLOCKER 4：此時 settlement_entries 尚未被 cascade 清掉，查得到 pending settlement。
  -- 這裡不能直接呼叫 void_settlements_for_entry：它會把涵蓋的 entries 一律打回 open，
  -- 包含「正在被刪的這一列」，於是 delete 會撞上
  -- 'tuple to be deleted was already modified by an operation triggered by the current command'。
  -- 所以同樣的搬狀態邏輯在這裡重寫一次，唯一差別是排除 OLD.id。
  if OLD.settled_state = 'settling' then
    for v_settlement in
      select se.settlement_id
      from public.settlement_entries se
      join public.settlements s on s.id = se.settlement_id
      where se.entry_id = OLD.id and s.status = 'pending'
    loop
      update public.settlements set status = 'void' where id = v_settlement;
      update public.entries
        set settled_state = 'open'
        where settled_state = 'settling'
          and id <> OLD.id
          and id in (select entry_id from public.settlement_entries where settlement_id = v_settlement);
    end loop;
  end if;

  return OLD;
end;
$$;
revoke execute on function public.entries_before_delete() from anon, authenticated, public;

-- 取代 0007 建的 after delete 版本（create or replace trigger，不用 drop）。
create or replace trigger entries_void_pending_settlement_del_trg
  before delete on public.entries
  for each row execute function public.entries_before_delete();

-- MAJOR 5：entry_splits 的 settled 鎖補 delete 分支。
-- 父 entry 被刪時 cascade 也會走到這裡，但那時 entries 那列已經不存在（同交易稍早刪掉），
-- exists 查不到 → 放行；只有「直接刪分攤」才擋得到。
-- 而且 settled 的 entry 現在根本刪不掉，cascade 帶 settled 分攤的情境不會發生。
create or replace function public.entry_splits_lock_settled_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (select 1 from public.entries e where e.id = OLD.entry_id and e.settled_state = 'settled') then
    raise exception 'entry settled: split locked' using errcode = 'P0001';
  end if;
  return OLD;
end;
$$;
revoke execute on function public.entry_splits_lock_settled_delete() from anon, authenticated, public;

create trigger entry_splits_lock_settled_del_trg
  before delete on public.entry_splits
  for each row execute function public.entry_splits_lock_settled_delete();
