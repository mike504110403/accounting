-- Migration 0005 — Realtime（spec「Realtime 訂閱 settlements / entries，app 開著即時更新」）
-- publication 上的表仍受 RLS 約束，私人筆不會外流。
-- 冪等：對已經在 publication 裡的表再 add 會報錯，所以先查再加。
do $$
declare
  v_table text;
begin
  foreach v_table in array array['entries', 'settlements', 'list_items'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end;
$$;
