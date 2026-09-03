-- Migration 0018 — 授權全面收斂（複審輪二 A／B／C／J）
--
-- B：Supabase 對 public schema 的 default privileges 是 GRANT ALL，
--    所以 authenticated 手上一直有 TRUNCATE／REFERENCES／TRIGGER。
--    **TRUNCATE 不受 RLS**——實測可以把整張 entries 清空。
--    先全部收回，再逐表逐動詞發，並把 default privileges 也關掉，
--    免得波 2 新增的表又自動帶 ALL。
-- A：欄位級授權先前只收了 UPDATE，INSERT 仍是整表權，
--    可以直接 insert 一筆 settled_state='settled' 的假已結帳（之後改不了也刪不掉）。
-- J：ledgers_insert policy 是死路（建帳本只走 create_ledger），一併收掉。

-- ---------- 全部收回 ----------
revoke all on all tables in schema public from anon, authenticated;

-- 以後新增的表不再自動帶 ALL（postgres 與 supabase_admin 各發過一份 default ACL）。
alter default privileges in schema public revoke all on tables from anon, authenticated;
-- 註：Supabase 在 public 上有兩份 default ACL，postgres 發的與 supabase_admin 發的。
-- 這行只動得了 postgres 那份。supabase_admin 那份改不動，實測原因：
--   Supabase 映像檔裡的 postgres role 不是 superuser（pg_user.usesuper = f），
--   也不是 supabase_admin 的成員（pg_has_role → f），
--   所以語句會 raise「permission denied to change default privileges」(SQLSTATE 42501)，
--   被下面的 exception 接住印成 notice——而 supabase db reset 不會把 notice 顯示出來，
--   所以看起來像「沒事發生」。
-- 影響有限：它只作用在「由 supabase_admin 建立的表」，而我們的 migration 都以 postgres 身分建表。
-- 雲端 push 之後請再跑一次 rls.sql 的前置掃描當 smoke test 確認。
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon, authenticated';
exception when others then
  raise notice '略過 supabase_admin 的 default privileges：%', sqlerrm;
end;
$$;

-- ---------- 逐表逐動詞發回 ----------
-- 只讀：結算相關四張表，寫入一律走 RPC。
grant select on
  public.settlements, public.settlement_entries,
  public.settlement_approvals, public.settlement_signers
to authenticated;

-- ledgers：可讀可改（改名、default_ratio、共同期初），不可新增（走 create_ledger）、不可刪。
grant select, update on public.ledgers to authenticated;

-- members：可讀、可插自己（policy 再限一次）、可改自己那列；不可刪。
grant select, insert, update on public.members to authenticated;

-- 一般資料表：成員全權。
grant select, insert, update, delete on
  public.categories, public.entry_splits, public.line_items,
  public.budgets, public.list_items
to authenticated;

-- entries：select／delete 整表，insert／update 只給可寫欄位。
-- settled_state、created_at、id 一律不給：狀態機只有 RPC 與 trigger 推得動。
grant select, delete on public.entries to authenticated;
grant insert (
  ledger_id, kind, scope, amount, category_id, occurred_on, note,
  created_by, payer_id, split_method, is_adjustment
) on public.entries to authenticated;
grant update (
  kind, scope, amount, category_id, occurred_on, note,
  payer_id, split_method, is_adjustment
) on public.entries to authenticated;

-- ---------- J：建帳本只走 RPC ----------
drop policy if exists ledgers_insert on public.ledgers;

-- ---------- A：新帳目一律 open（雙保險） ----------
-- 欄位級授權已經讓前端連 settled_state 都填不了，這支 trigger 是給
-- service_role／definer 之類繞過欄位授權的路徑用的。
create or replace function public.entries_force_open_on_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  NEW.settled_state := 'open';
  return NEW;
end;
$$;
revoke execute on function public.entries_force_open_on_insert() from anon, authenticated, public;

create trigger entries_force_open_on_insert_trg
  before insert on public.entries
  for each row execute function public.entries_force_open_on_insert();

-- 第三道：RLS 的 with check（訊息比權限錯誤友善）。
alter policy entries_insert on public.entries
  with check (
    public.is_member(ledger_id)
    and created_by = public.my_member_id(ledger_id)
    and settled_state = 'open'
  );
