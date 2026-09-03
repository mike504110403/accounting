-- Migration 0016 — 已結帳連日期一起鎖（review 21）
-- ADR-0002 只允許改分類、備註、細項；occurred_on 會把帳目搬到別的月份，
-- 統計與已完成的歷史結算會對不上，所以也要鎖。

create or replace function public.entries_lock_settled()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if OLD.settled_state <> 'settled' then
    return NEW;
  end if;
  if NEW.amount is distinct from OLD.amount then
    raise exception 'entry settled: amount locked, use an adjustment entry' using errcode = 'P0001';
  end if;
  if NEW.payer_id is distinct from OLD.payer_id then
    raise exception 'entry settled: payer locked' using errcode = 'P0001';
  end if;
  if NEW.split_method is distinct from OLD.split_method then
    raise exception 'entry settled: split_method locked' using errcode = 'P0001';
  end if;
  if NEW.scope is distinct from OLD.scope then
    raise exception 'entry settled: scope locked' using errcode = 'P0001';
  end if;
  if NEW.kind is distinct from OLD.kind then
    raise exception 'entry settled: kind locked' using errcode = 'P0001';
  end if;
  if NEW.occurred_on is distinct from OLD.occurred_on then
    raise exception 'entry settled: occurred_on locked' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.entries_lock_settled() from anon, authenticated, public;

-- settling 期間改日期一樣要打掉結算（日期影響月份歸屬與對帳）。
create or replace trigger entries_void_pending_settlement_trg
  after update of amount, payer_id, split_method, scope, kind, occurred_on on public.entries
  for each row
  when (
       old.amount       is distinct from new.amount
    or old.payer_id     is distinct from new.payer_id
    or old.split_method is distinct from new.split_method
    or old.scope        is distinct from new.scope
    or old.kind         is distinct from new.kind
    or old.occurred_on  is distinct from new.occurred_on
  )
  execute function public.entries_void_pending_settlement();
