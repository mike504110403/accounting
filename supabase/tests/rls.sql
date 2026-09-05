-- RLS 測試：以 psql 直連地端 DB，用 request.jwt.claims 模擬兩個使用者。
-- 任何 assert 失敗即 raise，psql 以 ON_ERROR_STOP=1 非零退出。
--
-- v1.5（ADR-0009）：沒有私人筆、沒有分攤、沒有結算，同帳本成員對帳目全可見。
-- 本檔的職責因此收斂成兩件事：
--   (1) 授權掃描——anon 零權限、白名單以外的函式前端執行不動、欄位級授權沒有多開，
--       以及 v1.4 的表／欄／enum／函式**沒有殘留**；
--   (2) 剩下的可見性與寫入邊界——以自己的名義記帳、身分欄不可變、非成員什麼都看不到。
-- personal_topups 的 RLS 與鎖月在 topups.sql。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set CAT '30000000-0000-0000-0000-000000000001'

\echo '== rls: 前置檢查 每張表都有 policy =='
do $$
declare
  v_missing text;
begin
  select string_agg(c.relname, ', ')
    into v_missing
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and c.relrowsecurity
    and not exists (select 1 from pg_policy p where p.polrelid = c.oid);
  assert v_missing is null, format('這些表開了 RLS 卻沒有任何 policy（＝全擋）：%s', v_missing);

  select string_agg(c.relname, ', ')
    into v_missing
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  assert v_missing is null, format('這些表沒開 RLS：%s', v_missing);
end;
$$;

\echo '== rls: 前置檢查 只有白名單的 RPC 能被前端執行（review 7／M）=='
do $$
declare
  v_bad text;
  -- 白名單＝前端真的要呼叫的 RPC（v1.5）。
  -- is_member／my_member_id 也必須在內：RLS 的 policy 運算式是以「呼叫者」身分求值的，
  -- 把它們的 execute 收掉會讓所有 select 變成 permission denied for function is_member（已實測）。
  v_allowed constant text[] := array[
    'create_ledger', 'join_ledger', 'search_items', 'upsert_entry',
    'rotate_invite_code', 'is_member', 'my_member_id', 'month_summary',
    -- 清帳：只有預覽與執行進白名單；month_close_details／month_close_guard／
    -- month_close_income_amount／raise_if_month_closed 是內部 helper，一律不給前端。
    'close_month', 'month_close_preview',
    -- taipei_month 是**純函式**：不讀任何表、只做日期換算，給前端執行洩不出任何資料。
    -- 它在白名單裡是因為 month_summary（security invoker）要呼叫得動——
    -- invoker 函式裡的權限檢查是以原呼叫者身分做的。
    'taipei_month'];
begin
  -- 掃 public 底下「全部」函式，不是只掃我列得出來的那幾支。
  select string_agg(format('%s→%s', p.proname, coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC')), ', ')
    into v_bad
  from pg_proc p
  cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.pronamespace = 'public'::regnamespace
    and a.privilege_type = 'EXECUTE'
    and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))
    and not (p.proname = any (v_allowed) and a.grantee::regrole::text = 'authenticated');
  assert v_bad is null, format('這些函式不該能被前端角色執行：%s', v_bad);

  -- 反面：白名單這幾支必須真的還給得動（不然前端整個掛掉）。
  assert (select count(distinct p.proname)
          from pg_proc p
          cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
          where p.pronamespace = 'public'::regnamespace
            and a.privilege_type = 'EXECUTE'
            and a.grantee::regrole::text = 'authenticated') = array_length(v_allowed, 1),
    '白名單的 RPC 應該全部都授權給 authenticated';
end;
$$;

\echo '== rls: 前置檢查 default privileges 不再自動開放給前端或 PUBLIC（review N／U／V）=='
do $$
declare
  v_bad text;
begin
  -- 只驗 postgres（migration 的執行者）發的那份；
  -- supabase_admin 那份在地端改不動（見 0018／0021 註解），雲端 push 後要再跑一次這支當 smoke test。
  select string_agg(format('%s→%s', d.defaclobjtype, coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC')), ', ')
    into v_bad
  from pg_default_acl d
  join pg_namespace n on n.oid = d.defaclnamespace
  cross join lateral aclexplode(d.defaclacl) a
  where n.nspname = 'public'
    and pg_get_userbyid(d.defaclrole) = 'postgres'
    and d.defaclobjtype in ('r', 'f', 'S')
    -- grantee = 0 就是 PUBLIC（review U）。
    and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'));
  assert v_bad is null,
    format('public 的 default privileges 仍會自動開放：%s（新增的表／函式會自動帶權限）', v_bad);

  -- review U：函式的**內建**預設是 EXECUTE TO PUBLIC，跟表不一樣。
  -- 如果 pg_default_acl 根本沒有 'f' 這一列，代表沒人 revoke 過，新函式一建出來全世界都能執行——
  -- 上面那段會因為「查不到列」而空跑通過，所以這裡另外要求那一列必須存在。
  assert exists (
    select 1 from pg_default_acl d
    join pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname = 'public'
      and pg_get_userbyid(d.defaclrole) = 'postgres'
      and d.defaclobjtype = 'f'
  ), 'public 沒有函式的 default privileges 設定：新建的函式會沿用 Postgres 內建的 EXECUTE TO PUBLIC';
end;
$$;

\echo '== rls: 前置檢查 public 不准放 matview、view 一律 security_invoker（security review n1）=='
do $$
declare
  v_matviews text;
  v_bad text;
begin
  -- matview 沒有 security_invoker 這個選項（它的內容是實體化好的、與呼叫者無關），
  -- 所以它在 public 就是「一份繞過 RLS 的資料副本」——直接禁止。
  select string_agg(c.relname, ', ') into v_matviews
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'm';
  assert v_matviews is null,
    format('public 不該有 materialized view（沒有 security_invoker，內容是繞過 RLS 的副本）：%s', v_matviews);

  -- 一般 view 預設是 security **definer**（以 view 擁有者身分讀底層表 → 完全繞過 RLS）。
  -- v1.5 目前一個 view 都沒有（entry_member_effects 已 drop），但這條掃描要留著：
  -- 日後新增 view 忘了帶旗標會直接紅。
  select string_agg(format('%s(%s)', c.relname, coalesce(array_to_string(c.reloptions, ','), '無 reloptions')), ', ')
    into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    and not (coalesce(c.reloptions, '{}') @> array['security_invoker=true']);
  assert v_bad is null,
    format('這些 view 沒帶 security_invoker=true（會以擁有者身分繞過 RLS）：%s', v_bad);
end;
$$;

\echo '== rls: 前置檢查 v1.4 的結算／分攤／私人筆完全沒有殘留（ADR-0009）=='
do $$
declare
  v_bad text;
begin
  -- 表與 view。
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('settlements', 'settlement_entries', 'settlement_approvals',
                      'settlement_signers', 'entry_splits', 'entry_member_effects', 'budgets');
  assert v_bad is null, format('這些 v1.4 的物件應該已經 drop：%s', v_bad);

  -- information_schema 的角度再驗一次（前端看得到的是這個視角）。
  select string_agg(t.table_name, ', ') into v_bad
  from information_schema.tables t
  where t.table_schema = 'public'
    and t.table_name in ('settlements', 'settlement_entries', 'settlement_approvals',
                         'settlement_signers', 'entry_splits');
  assert v_bad is null, format('information_schema 仍看得到這些表：%s', v_bad);

  -- 函式：Drop 清單**逐一**點名（不是抽查），少 drop 一支就會在這裡紅。
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('initiate_settlement', 'approve_settlement', 'cancel_settlement',
                      'required_signers', 'required_signers_internal',
                      'void_settlements_for_entry', 'topup_for',
                      'entries_lock_settled', 'entries_force_open_on_insert',
                      'entries_before_delete', 'entries_void_pending_settlement',
                      'entry_splits_void_pending_settlement',
                      'entry_splits_lock_settled', 'entry_splits_lock_settled_delete',
                      'entry_splits_same_ledger', 'settlement_entries_same_ledger',
                      'settlements_status_machine', 'settlement_approvals_guard',
                      'settlement_finalize_on_approval',
                      'entry_splits_sum_check', 'entries_split_sum_check');
  assert v_bad is null, format('這些 v1.4 的函式應該已經 drop：%s', v_bad);

  -- 舊 overload：`close_month(uuid, date)` 與新的三參數版是**不同函式**，
  -- 不 drop 的話 PostgREST 送兩個參數會拿到 `function is not unique`。
  assert not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = 'close_month'
      and pg_get_function_identity_arguments(p.oid) = 'p_ledger uuid, p_month date'
  ), 'close_month 的舊兩參數簽名應該已經 drop（否則兩參數呼叫會 not unique）';
  assert not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = 'upsert_entry'
      and pg_get_function_identity_arguments(p.oid) = 'p_entry jsonb, p_splits jsonb, p_line_items jsonb'
  ), 'upsert_entry 的舊三參數簽名應該已經 drop';

  -- 保留清單：這四支 trigger 與 v1.5 無關，被誤 drop 一樣要紅。
  select string_agg(x, ', ') into v_bad
  from unnest(array['entries_immutable_identity_trg', 'members_immutable_identity_trg',
                    'list_items_same_ledger_trg', 'budget_allocation_expense_category_trg']) x
  where not exists (select 1 from pg_trigger t where t.tgname = x and not t.tgisinternal);
  assert v_bad is null, format('這些 trigger 應該保留卻不見了：%s', v_bad);

  -- 結算／分攤的 trigger 一支都不該剩（entries 上的逐名 drop ＋ 其餘隨表消失）。
  select string_agg(t.tgname, ', ') into v_bad
  from pg_trigger t
  where not t.tgisinternal
    and t.tgname in ('entries_lock_settled_trg', 'entries_void_pending_settlement_trg',
                     'entries_void_pending_settlement_del_trg', 'entries_force_open_on_insert_trg',
                     'entries_split_sum_check_trg', 'a_entry_splits_month_closed_trg');
  assert v_bad is null, format('這些 trigger 應該已經 drop：%s', v_bad);

  -- 補釘 6(c)：create_ledger／join_ledger 的定義裡不該還留著 default_ratio。
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('create_ledger', 'join_ledger')
    and pg_get_functiondef(p.oid) like '%default_ratio%';
  assert v_bad is null, format('這些 RPC 的定義裡還在寫 default_ratio：%s', v_bad);

  -- upsert_entry 只剩兩參數版（三參數版留著會讓 upsert_entry(a, b) 變成 ambiguous）。
  select string_agg(pg_get_function_identity_arguments(p.oid), ' ／ ') into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname = 'upsert_entry';
  assert v_bad = 'p_entry jsonb, p_line_items jsonb',
    format('upsert_entry 的簽名不對：%s', coalesce(v_bad, '（不存在）'));

  -- close_month 只剩三參數版。
  select string_agg(pg_get_function_identity_arguments(p.oid), ' ／ ') into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname = 'close_month';
  assert v_bad = 'p_ledger uuid, p_month date, p_record_income boolean',
    format('close_month 的簽名不對：%s', coalesce(v_bad, '（不存在）'));

  -- enum。
  select string_agg(t.typname, ', ') into v_bad
  from pg_type t
  where t.typnamespace = 'public'::regnamespace
    and t.typname in ('entry_scope', 'split_method', 'settled_state', 'settlement_status', 'funding');
  assert v_bad is null, format('這些 enum 應該已經 drop：%s', v_bad);

  -- 欄位。
  select string_agg(format('%s.%s', c.table_name, c.column_name), ', ') into v_bad
  from information_schema.columns c
  where c.table_schema = 'public'
    and ((c.table_name = 'entries' and c.column_name in ('scope', 'split_method', 'settled_state', 'funding'))
      or (c.table_name = 'ledgers' and c.column_name in ('default_ratio', 'opening_balance_shared'))
      or (c.table_name = 'members' and c.column_name in ('monthly_topup', 'opening_balance_personal')));
  assert v_bad is null, format('這些欄位應該已經 drop：%s', v_bad);

  -- entries 的新 check（收入不得有付款人）確實存在。
  assert exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'entries' and con.conname = 'entries_income_no_payer'
  ), 'entries_income_no_payer 這道 check 不存在';

  -- archive 的 v1.3 快照刻意保留（遷移可逆性的憑據），前端照舊碰不到。
  assert exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'archive' and c.relname = 'budget_allocation_v13'
  ), 'archive.budget_allocation_v13 不該被 v1.5 一起清掉';
end;
$$;

\echo '== rls: 前置檢查 realtime publication 恰好五張表（含 personal_topups）=='
do $$
declare
  v_tables text;
begin
  select string_agg(pt.tablename, ', ' order by pt.tablename) into v_tables
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public';
  assert v_tables = 'budget_allocation, entries, list_items, month_closes, personal_topups',
    format('publication 的表不對：%s', coalesce(v_tables, '（一張都沒有）'));
  assert (select count(*) from pg_publication_tables
           where pubname = 'supabase_realtime') = 5,
    'publication 應該恰好五張表';
end;
$$;

\echo '== rls: 前置檢查 entries 的 INSERT／UPDATE 都是欄位級授權（review 3／A）=='
do $$
declare
  v_cols text;
begin
  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'entries'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'INSERT';
  -- id／created_at 不給前端填；created_by 可以 insert（要標記錄人）。
  assert v_cols = 'amount, category_id, created_by, is_adjustment, kind, ledger_id, note, occurred_on, payer_id',
    format('entries 的 INSERT 欄位不對：%s', coalesce(v_cols, '（一欄都沒有）'));

  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'entries'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE';
  -- created_by／ledger_id 是身分欄，連授權都不給（trigger 是第二道）。
  assert v_cols = 'amount, category_id, is_adjustment, kind, note, occurred_on, payer_id',
    format('entries 的 UPDATE 欄位不對：%s', coalesce(v_cols, '（一欄都沒有）'));
end;
$$;

\echo '== rls: 前置檢查 budget_allocation 的 INSERT 是欄位級授權、UPDATE／DELETE 全收回（ADR-0008）=='
do $$
declare
  v_cols text;
  v_verbs text;
begin
  -- 預算影子紀錄設定後不可改不可刪。
  -- 表層級只剩 SELECT（INSERT 是欄位級的，不會出現在 table_privileges）。
  select string_agg(distinct tp.privilege_type, ', ' order by tp.privilege_type) into v_verbs
  from information_schema.table_privileges tp
  where tp.table_schema = 'public' and tp.table_name = 'budget_allocation'
    and tp.grantee = 'authenticated';
  assert v_verbs = 'SELECT',
    format('budget_allocation 表層級對前端應只剩 SELECT，實際 %s', coalesce(v_verbs, '（完全沒有）'));

  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'budget_allocation'
    and cp.grantee = 'authenticated' and cp.privilege_type in ('UPDATE', 'DELETE');
  assert v_cols is null,
    format('budget_allocation 不該剩任何 UPDATE／DELETE 授權：%s', v_cols);

  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'budget_allocation'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'INSERT';
  assert v_cols = 'amount, category_id, created_by, ledger_id, note, occurred_on',
    format('budget_allocation 的 INSERT 欄位不對：%s', coalesce(v_cols, '（一欄都沒有）'));
end;
$$;

\echo '== rls: 前置檢查 personal_topups 的授權恰好是 select／insert／delete（沒有 UPDATE）=='
do $$
declare
  v_verbs text;
begin
  -- 表層級只剩 SELECT／DELETE（INSERT 是欄位級的，不會出現在 table_privileges）。
  select string_agg(distinct tp.privilege_type, ', ' order by tp.privilege_type) into v_verbs
  from information_schema.table_privileges tp
  where tp.table_schema = 'public' and tp.table_name = 'personal_topups'
    and tp.grantee = 'authenticated';
  assert v_verbs = 'DELETE, SELECT',
    format('personal_topups 表層級應只剩 SELECT／DELETE，實際 %s', coalesce(v_verbs, '（完全沒有）'));

  -- INSERT 走欄位級（比照 entries／budget_allocation）：id 與 created_at 不給前端填。
  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_verbs
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'personal_topups'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'INSERT';
  assert v_verbs = 'amount, created_by, ledger_id, member_id, note, occurred_on',
    format('personal_topups 的 INSERT 欄位不對：%s', coalesce(v_verbs, '（一欄都沒有）'));

  -- 補入要改就刪了重記：連半欄 UPDATE 都不給（欄位級授權也要一起掃）。
  assert not exists (
    select 1 from information_schema.column_privileges cp
    where cp.table_schema = 'public' and cp.table_name = 'personal_topups'
      and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE'
  ), 'personal_topups 不該有任何 UPDATE 授權';
  assert has_table_privilege('authenticated', 'public.personal_topups', 'update') = false,
    'has_table_privilege 說 authenticated 可以 update personal_topups';
  assert not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'personal_topups' and cmd = 'UPDATE'
  ), 'personal_topups 不該有 UPDATE policy';

  -- anon 一欄都不給。
  assert not exists (
    select 1 from information_schema.table_privileges tp
    where tp.table_schema = 'public' and tp.table_name = 'personal_topups' and tp.grantee = 'anon'
  ), 'anon 不該對 personal_topups 有任何權限';
end;
$$;

\echo '== rls: 前置檢查 ledgers／members 也是欄位級 UPDATE（review R）=='
do $$
declare
  v_cols text;
begin
  -- ledgers：v1.5 drop 掉 default_ratio 與 opening_balance_shared 之後只剩改名。
  -- invite_code 不得可寫（輪替走 rotate_invite_code，否則成員可自選邀請碼）。
  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'ledgers'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE';
  assert v_cols = 'name', format('ledgers 的可寫欄位應只有 name，實際：%s', coalesce(v_cols, '（一欄都沒有）'));

  -- members：v1.5 drop 掉 monthly_topup／opening_balance_personal 之後只剩暱稱。
  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'members'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE';
  assert v_cols = 'display_name',
    format('members 的可寫欄位應只有 display_name，實際：%s', coalesce(v_cols, '（一欄都沒有）'));
end;
$$;

\echo '== rls: 前置檢查 前端角色不得有 TRUNCATE／REFERENCES／TRIGGER（review B）=='
do $$
declare
  v_bad text;
begin
  -- TRUNCATE 不受 RLS 約束，拿到就等於可以清空整張表。
  select string_agg(format('%s.%s→%s', tp.table_name, tp.privilege_type, tp.grantee), ', ')
    into v_bad
  from information_schema.table_privileges tp
  where tp.table_schema = 'public'
    and tp.grantee in ('anon', 'authenticated')
    and tp.privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER');
  assert v_bad is null, format('前端角色不該有這些權限：%s', v_bad);

  -- anon 一律無權。
  select string_agg(format('%s→%s', tp.table_name, tp.privilege_type), ', ') into v_bad
  from information_schema.table_privileges tp
  where tp.table_schema = 'public' and tp.grantee = 'anon';
  assert v_bad is null, format('anon 不該對 public 的表有任何權限：%s', v_bad);

  -- month_closes 只讀（清帳只能經 close_month 落地，而且不可撤銷）。
  select string_agg(format('%s→%s', tp.table_name, tp.privilege_type), ', ') into v_bad
  from information_schema.table_privileges tp
  where tp.table_schema = 'public' and tp.grantee = 'authenticated'
    and tp.table_name = 'month_closes' and tp.privilege_type <> 'SELECT';
  assert v_bad is null, format('month_closes 對前端應該只有 SELECT：%s', v_bad);

  -- ledgers 不得有 INSERT（review J：建帳本只走 create_ledger）。
  assert not exists (
    select 1 from information_schema.table_privileges tp
    where tp.table_schema = 'public' and tp.table_name = 'ledgers'
      and tp.grantee = 'authenticated' and tp.privilege_type = 'INSERT'
  ), 'ledgers 不該給 authenticated INSERT';
  assert not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename = 'ledgers' and policyname = 'ledgers_insert'),
    'ledgers_insert policy 已是死路，應該刪掉';

  -- review W：加入帳本只走 join_ledger／create_ledger，members 不該有 INSERT。
  assert not exists (
    select 1 from information_schema.table_privileges tp
    where tp.table_schema = 'public' and tp.table_name = 'members'
      and tp.grantee = 'authenticated' and tp.privilege_type = 'INSERT'
  ), 'members 不該給 authenticated INSERT（加入帳本只走 RPC）';
  assert not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename = 'members' and policyname = 'members_insert'),
    'members_insert policy 已是死路，應該刪掉';
end;
$$;

\echo '== rls: 成員可讀每一張表 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  assert auth.uid() = '11111111-1111-1111-1111-111111111111'::uuid, 'auth.uid() 沒吃到 jwt claims';
  assert (select count(*) from public.ledgers) = 1, 'ledgers 讀不到';
  assert (select count(*) from public.members) = 2, 'members 讀不到';
  assert (select count(*) from public.categories) = 9, 'categories 讀不到';
  assert (select count(*) from public.entries) = 8, format('mike 應看到 8 筆 entries，實際 %s', (select count(*) from public.entries));
  assert (select count(*) from public.line_items) = 5, 'line_items 讀不到';
  assert (select count(*) from public.budget_allocation) = 5, 'budget_allocation 讀不到';
  assert (select count(*) from public.personal_topups) = 5, 'personal_topups 讀不到';
  assert (select count(*) from public.list_items) = 7, 'list_items 讀不到';
  -- 種子沒清過帳，重點是「查得動、不報錯」。
  assert (select count(*) from public.month_closes) = 0, 'month_closes 讀不到';
end;
$$;
rollback;

\echo '== rls: 同帳本成員對帳目全可見（v1.5 沒有私人筆）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_rows int;
begin
  -- ADR-0009 決策 1：可見性回到「同帳本成員全部可見」，兩人看到的筆數一樣。
  assert (select count(*) from public.entries) = 8,
    format('老婆應看到 8 筆 entries，實際 %s', (select count(*) from public.entries));
  -- e-3「全聯買菜」是 mike 建的、mike 先付的筆——老婆照樣看得到、也編輯得動。
  assert exists (select 1 from public.entries e
                 where e.id = '40000000-0000-0000-0000-000000000003'
                   and e.created_by = '20000000-0000-0000-0000-000000000001'),
    '老婆應看得到 mike 建的帳目';
  assert (select count(*) from public.line_items) = 5, '細項也應該全可見';

  update public.entries set note = '老婆補註' where id = '40000000-0000-0000-0000-000000000003';
  get diagnostics v_rows = row_count;
  assert v_rows = 1, '同帳本成員應該改得動彼此的帳目（v1.5 沒有 settled 鎖）';

  -- 未清月的非沖銷筆可刪（v1.5 沒有 settled 鎖，只剩鎖月）。
  delete from public.entries where id = '40000000-0000-0000-0000-000000000003';
  get diagnostics v_rows = row_count;
  assert v_rows = 1, '未清月的帳目應該刪得掉';
end;
$$;
rollback;

\echo '== rls: 老婆不能以 mike 的名義新增 entry（應失敗） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 100,
            '30000000-0000-0000-0000-000000000001', current_date, '冒名',
            '20000000-0000-0000-0000-000000000001');
  exception when others then
    v_blocked := true;
    v_err := sqlerrm;
  end;
  assert v_blocked, '老婆竟然能插入 created_by = mike 的 entry';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== rls: 老婆用自己的 member id 新增 entry 可以過 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 100,
          '30000000-0000-0000-0000-000000000001', current_date, '自己的一筆',
          '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002');
  assert (select count(*) from public.entries) = 9, '老婆新增後應看到 9 筆';
end;
$$;
rollback;

\echo '== rls: entries 的身分欄前端寫不動（created_by／ledger_id，應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：把別人的帳目據為己有。
  v_blocked := false;
  begin
    update public.entries set created_by = '20000000-0000-0000-0000-000000000002'
      where id = '40000000-0000-0000-0000-000000000003';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'created_by 竟然改得動';
  -- 兩道防線都算通過：欄位級授權（沒給）或不可變 trigger（授權若被放寬時的第二道）。
  assert v_err like '%created_by is immutable%' or v_err like '%permission denied%',
    format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：把帳目搬到別的帳本。
  v_blocked := false;
  begin
    update public.entries set ledger_id = gen_random_uuid()
      where id = '40000000-0000-0000-0000-000000000003';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'ledger_id 竟然改得動';
  assert v_err like '%ledger_id is immutable%' or v_err like '%permission denied%',
    format('錯誤訊息不對：%s', v_err);

  -- 對照組：授權清單內的欄位照常寫得動。
  update public.entries set note = '照樣改得動', amount = 3600
    where id = '40000000-0000-0000-0000-000000000003';
  assert (select amount from public.entries e where e.id = '40000000-0000-0000-0000-000000000003') = 3600,
    '授權清單內的欄位應該還是寫得動';
end;
$$;
rollback;

\echo '== rls: 成員不能把自己搬到別的帳本／換成別人（應失敗，review 17）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
  v_rows int;
begin
  -- 應失敗①：換帳本。
  v_blocked := false;
  begin
    update public.members set ledger_id = gen_random_uuid()
      where id = '20000000-0000-0000-0000-000000000002';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '成員竟然能把自己搬到別的帳本';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：換成別人的 user_id。
  v_blocked := false;
  begin
    update public.members set user_id = '11111111-1111-1111-1111-111111111111'
      where id = '20000000-0000-0000-0000-000000000002';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '成員竟然能改 user_id';

  -- 應失敗③：改別人那列（RLS 過濾，影響 0 列）。
  update public.members set display_name = '被改名'
    where id = '20000000-0000-0000-0000-000000000001';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, '成員竟然改得動別人那列';

  -- 對照組：改自己的暱稱可以（v1.5 之後 members 只剩這一欄可寫）。
  update public.members set display_name = '老婆大人'
    where id = '20000000-0000-0000-0000-000000000002';
  get diagnostics v_rows = row_count;
  assert v_rows = 1, '成員應該改得動自己的暱稱';
end;
$$;
rollback;

\echo '== rls: 不能 TRUNCATE、不能建帳本（應失敗，review B／J）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：TRUNCATE（不受 RLS，拿到就能清空整表）。
  v_blocked := false;
  begin
    truncate public.entries cascade;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能 TRUNCATE entries';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：TRUNCATE 補入表（同理，補入是錢）。
  v_blocked := false;
  begin
    truncate public.personal_topups;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能 TRUNCATE personal_topups';

  -- 應失敗③：直接建帳本（只能走 create_ledger）。
  v_blocked := false;
  begin
    insert into public.ledgers (name) values ('偷建的帳本');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接建帳本';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗④：直接寫清帳紀錄（清帳只能走 close_month，而且不可撤銷）。
  v_blocked := false;
  begin
    insert into public.month_closes (ledger_id, month, closed_by, details)
    values ('10000000-0000-0000-0000-000000000001',
            (date_trunc('month', current_date) - interval '1 month')::date,
            '20000000-0000-0000-0000-000000000002', '{}'::jsonb);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接寫 month_closes';
end;
$$;
rollback;

\echo '== rls: 邀請碼只能用 rotate_invite_code 換，不能自選（應失敗，review R）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_old text;
  v_l public.ledgers;
begin
  select invite_code into v_old from public.ledgers where id = '10000000-0000-0000-0000-000000000001';

  -- 應失敗：直接把邀請碼改成自己記得住的字串（等於自選密碼）。
  begin
    update public.ledgers set invite_code = 'AAAAAAAAAA'
      where id = '10000000-0000-0000-0000-000000000001';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '成員竟然能自選邀請碼';
  raise notice '  預期的失敗：%', v_err;

  -- 對照組：走 RPC 換邀請碼可以，而且真的換掉了。
  v_l := public.rotate_invite_code('10000000-0000-0000-0000-000000000001');
  assert v_l.invite_code <> v_old, '邀請碼應該被換掉';
  assert v_l.invite_code ~ '^[A-Z0-9]{10}$', format('新邀請碼格式不對：%s', v_l.invite_code);

  -- 對照組：帳本名稱照樣改得動。
  update public.ledgers set name = '我們的家（改名）'
    where id = '10000000-0000-0000-0000-000000000001';
  assert (select name from public.ledgers where id = '10000000-0000-0000-0000-000000000001') = '我們的家（改名）',
    '帳本名稱應該改得動';
end;
$$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 應失敗：非成員不能換別人帳本的邀請碼。
  begin
    perform public.rotate_invite_code('10000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然能換別人帳本的邀請碼';
  assert v_err like '%not a member%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== rls: 非成員（隨機使用者）什麼都看不到 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  assert (select count(*) from public.ledgers) = 0, '非成員竟然看得到帳本';
  assert (select count(*) from public.entries) = 0, '非成員竟然看得到帳目';
  assert (select count(*) from public.members) = 0, '非成員竟然看得到成員';
  assert (select count(*) from public.line_items) = 0, '非成員竟然看得到細項';
  assert (select count(*) from public.list_items) = 0, '非成員竟然看得到清單';
  assert (select count(*) from public.personal_topups) = 0, '非成員竟然看得到別人的補入';
  assert (select count(*) from public.month_closes) = 0, '非成員竟然看得到清帳紀錄';
end;
$$;
rollback;

\echo '== rls: 非成員不能把自己塞進別人的帳本（應失敗） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 老婆想以 mike 的 user_id 建立成員列。
  begin
    insert into public.members (ledger_id, user_id, display_name)
    values ('10000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '冒名');
  exception when others then
    v_blocked := true;
    v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能插入別人的 member 列';
  raise notice '  預期的失敗：%', v_err;

  -- review W 之後連「插自己」都不行了，加入帳本一律走 join_ledger。
  v_blocked := false;
  begin
    insert into public.members (ledger_id, user_id, display_name)
    values (gen_random_uuid(), '22222222-2222-2222-2222-222222222222', '自己');
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然還能直接 insert members（應該只剩 join_ledger／create_ledger 這條路）';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== rls: anon 完全讀不到 =='
begin;
select set_config('request.jwt.claims', '', true) as _claims \gset
set local role anon;
do $$
declare
  v_rows int;
  v_denied boolean := false;
begin
  begin
    select count(*) into v_rows from public.entries;
  exception when insufficient_privilege then
    v_denied := true;
    v_rows := 0;
  end;
  assert v_denied or v_rows = 0, format('anon 竟然讀得到 %s 筆帳目', v_rows);

  v_denied := false;
  begin
    select count(*) into v_rows from public.personal_topups;
  exception when insufficient_privilege then
    v_denied := true;
    v_rows := 0;
  end;
  assert v_denied or v_rows = 0, format('anon 竟然讀得到 %s 筆補入', v_rows);

  assert auth.uid() is null, 'anon 不該有 auth.uid()';
end;
$$;
rollback;

\echo '== rls: search_items 受 RLS，v1.5 下同帳本互相搜得到 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  -- 「全聯買菜」是 mike 建的筆，v1.5 沒有私人筆，老婆搜得到（v1.4 時私人筆會被濾掉）。
  assert exists (select 1 from public.search_items('10000000-0000-0000-0000-000000000001', '全聯買菜')),
    '老婆應搜得到 mike 建的帳目';
  -- 「雞蛋」：種子裡 e-3 與 e-5 各一筆細項，共 2 筆。
  assert (select count(*) from public.search_items('10000000-0000-0000-0000-000000000001', '雞蛋')) = 2,
    format('雞蛋應有 2 筆細項，實際 %s',
           (select count(*) from public.search_items('10000000-0000-0000-0000-000000000001', '雞蛋')));
  assert exists (select 1 from public.search_items('10000000-0000-0000-0000-000000000001', '牛奶')),
    '應搜得到細項與清單';
end;
$$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  -- 非成員搜不到任何東西（search_items 是 security invoker，吃呼叫者的 RLS）。
  assert not exists (select 1 from public.search_items('10000000-0000-0000-0000-000000000001', '雞蛋')),
    '非成員竟然搜得到別人帳本的東西';
end;
$$;
rollback;

\echo 'rls.sql PASS'
