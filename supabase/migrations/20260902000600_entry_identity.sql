-- Migration 0006 — entry 身分欄位不可變（收掉「同帳本成員可把對方的 shared entry 改成自己的」這個洞）
--
-- 為什麼是 trigger 而不是 policy 的 with check：
-- RLS 的 with check 只看得到 NEW，看不到 OLD，沒辦法表達「改完必須等於原值」。
-- entries 的 update policy 仍保留原本的 with check（成員 且（shared 或 created_by = 自己）），
-- 這支 trigger 補上它表達不了的那一半。
create or replace function public.entries_immutable_identity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW.created_by is distinct from OLD.created_by then
    raise exception 'entry: created_by is immutable' using errcode = 'P0001';
  end if;
  if NEW.ledger_id is distinct from OLD.ledger_id then
    raise exception 'entry: ledger_id is immutable' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

create trigger entries_immutable_identity_trg
  before update of created_by, ledger_id on public.entries
  for each row execute function public.entries_immutable_identity();
