-- Migration 0023 — sequences 授權與 members INSERT 收回（複審輪三 V／W）

-- ---------- V：sequences 比照 tables／functions ----------
-- 目前 schema 全部用 uuid，沒有任何 sequence，所以這是為波 2 預先關門：
-- Supabase 的預設會讓每個新 sequence 自動帶 USAGE/SELECT/UPDATE 給 anon 與 authenticated，
-- 而 sequence 的 UPDATE 等於可以任意改 nextval。
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public '
       || 'revoke all on sequences from anon, authenticated';
exception when others then
  raise notice '略過 supabase_admin 的 sequence default privileges：%', sqlerrm;
end;
$$;

-- ---------- W：加入帳本只走 RPC ----------
-- members 的 insert policy 原本限「只能插自己、且限已在的帳本」，實務上是死路
-- （已經是成員了還插什麼），真正的加入路徑是 join_ledger／create_ledger（security definer）。
revoke insert on public.members from authenticated;
drop policy if exists members_insert on public.members;
