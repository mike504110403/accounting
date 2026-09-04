-- 0026：publication 表的 replica identity 必須是 full（DELETE 事件才帶得出 filter 欄）。
-- 名單從 pg_publication_tables 推導（db review m2）：日後 publication 加新表忘了設 full，
-- 這裡會直接紅，不會靜默回歸。
\echo '== replica_identity: supabase_realtime publication 全表皆 full =='
do $$
declare
  v_bad text;
begin
  select string_agg(c.relname, ', ') into v_bad
  from pg_publication_tables pt
  join pg_namespace n on n.nspname = pt.schemaname
  join pg_class c on c.relnamespace = n.oid and c.relname = pt.tablename
  where pt.pubname = 'supabase_realtime' and c.relreplident <> 'f';
  assert v_bad is null, format('這些 publication 表不是 replica identity full：%s', v_bad);
end;
$$;
\echo 'replica_identity 測試通過'
