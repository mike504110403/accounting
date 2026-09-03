-- Migration 0012 — 慣例與訊息（review MINOR 9）
-- 註：pg_trgm 的 schema 與 realtime 冪等已在 0001／0005 直接改好（複審輪二 D 裁定准改舊檔），此處不再重複。

-- ---------- settled 鎖定錯誤訊息依欄位分別說明 ----------
-- 前端要能照訊息告訴使用者「是哪一項被鎖住」，訊息一律保留 'entry settled: ' 前綴。
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
  return NEW;
end;
$$;
revoke execute on function public.entries_lock_settled() from anon, authenticated, public;
