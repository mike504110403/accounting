-- RLS 測試：以 psql 直連地端 DB，用 request.jwt.claims 模擬兩個使用者。
-- 任何 assert 失敗即 raise，psql 以 ON_ERROR_STOP=1 非零退出。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set CAT '30000000-0000-0000-0000-000000000001'
\set PRIVATE_ENTRY '40000000-0000-0000-0000-000000000008'

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
  -- 白名單＝波 2 真的要呼叫的 RPC。
  -- is_member／my_member_id 也必須在內：RLS 的 policy 運算式是以「呼叫者」身分求值的，
  -- 把它們的 execute 收掉會讓所有 select 變成 permission denied for function is_member（已實測）。
  v_allowed constant text[] := array[
    'create_ledger', 'join_ledger', 'initiate_settlement', 'approve_settlement',
    'cancel_settlement', 'required_signers', 'search_items', 'upsert_entry',
    'rotate_invite_code', 'is_member', 'my_member_id'];
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
    format('public 的 default privileges 仍會自動開放：%s（波 2 新增的表／函式會自動帶權限）', v_bad);

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

\echo '== rls: 前置檢查 entries 的 INSERT／UPDATE 都是欄位級授權（review 3／A）=='
do $$
declare
  v_verb text;
  v_cols text;
  v_leaked text;
  v_forbidden text[];
begin
  foreach v_verb in array array['INSERT', 'UPDATE'] loop
    select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
    from information_schema.column_privileges cp
    where cp.table_schema = 'public' and cp.table_name = 'entries'
      and cp.grantee = 'authenticated' and cp.privilege_type = v_verb;
    assert v_cols is not null, format('entries 的 %s 應是欄位級授權，現在一欄都沒有', v_verb);

    -- settled_state 兩種動詞都不能給；created_by 可以 insert（要標記錄人）但不能 update。
    if v_verb = 'INSERT' then
      v_forbidden := array['settled_state', 'id', 'created_at'];
    else
      v_forbidden := array['settled_state', 'created_by', 'ledger_id', 'id', 'created_at'];
    end if;
    select string_agg(x, ', ') into v_leaked
    from unnest(v_forbidden) x
    where x = any (string_to_array(v_cols, ', '));
    assert v_leaked is null,
      format('entries 這些欄位不該給 authenticated %s：%s', v_verb, v_leaked);
  end loop;
end;
$$;

\echo '== rls: 前置檢查 ledgers／members 也是欄位級 UPDATE（review R）=='
do $$
declare
  v_cols text;
  v_leaked text;
begin
  -- ledgers：invite_code 不得可寫（輪替走 rotate_invite_code，否則成員可自選邀請碼）。
  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'ledgers'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE';
  assert v_cols = 'default_ratio, name, opening_balance_shared',
    format('ledgers 的可寫欄位應只有 name／default_ratio／opening_balance_shared，實際：%s', v_cols);

  -- members：只開暱稱與個人期初。
  select string_agg(cp.column_name, ', ' order by cp.column_name) into v_cols
  from information_schema.column_privileges cp
  where cp.table_schema = 'public' and cp.table_name = 'members'
    and cp.grantee = 'authenticated' and cp.privilege_type = 'UPDATE';
  assert v_cols = 'display_name, opening_balance_personal',
    format('members 的可寫欄位應只有 display_name／opening_balance_personal，實際：%s', v_cols);
end;
$$;

\echo '== rls: 前置檢查 前端角色不得有 TRUNCATE／REFERENCES／TRIGGER（review B）=='
do $$
declare
  v_bad text;
begin
  -- TRUNCATE 不受 RLS 約束，拿到就等於可以清空整張表。
  select string_agg(format('%s.%s→%s(%s)', tp.table_name, tp.privilege_type, tp.grantee, tp.privilege_type), ', ')
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

  -- 結算四張表只讀（review 1／C）。
  select string_agg(format('%s→%s', tp.table_name, tp.privilege_type), ', ') into v_bad
  from information_schema.table_privileges tp
  where tp.table_schema = 'public' and tp.grantee = 'authenticated'
    and tp.table_name in ('settlements', 'settlement_entries', 'settlement_approvals', 'settlement_signers')
    and tp.privilege_type <> 'SELECT';
  assert v_bad is null, format('結算相關的表對前端應該只有 SELECT：%s', v_bad);

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
  assert (select count(*) from public.entries) = 10, format('mike 應看到 10 筆 entries，實際 %s', (select count(*) from public.entries));
  assert (select count(*) from public.entry_splits) = 10, 'entry_splits 讀不到';
  assert (select count(*) from public.line_items) = 8, 'line_items 讀不到';
  assert (select count(*) from public.budgets) = 6, 'budgets 讀不到';
  assert (select count(*) from public.list_items) = 7, 'list_items 讀不到';
  -- 這三張種子沒資料，重點是「查得動、不報錯」。
  assert (select count(*) from public.settlements) = 0, 'settlements 讀不到';
  assert (select count(*) from public.settlement_entries) = 0, 'settlement_entries 讀不到';
  assert (select count(*) from public.settlement_approvals) = 0, 'settlement_approvals 讀不到';
  assert (select count(*) from public.settlement_signers) = 0, 'settlement_signers 讀不到';
end;
$$;
rollback;

\echo '== rls: 老婆看不到 mike 的 private entry =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_rows int;
begin
  -- 10 筆裡有 2 筆是 mike 的 private（接案、Steam）。
  assert (select count(*) from public.entries) = 8,
    format('老婆應只看到 8 筆 entries，實際 %s', (select count(*) from public.entries));
  assert not exists (select 1 from public.entries e where e.id = '40000000-0000-0000-0000-000000000008'),
    '老婆竟然看得到 mike 的私人支出';
  assert not exists (select 1 from public.entries e where e.scope = 'private'),
    '老婆竟然看得到私人筆';
  -- 私人筆對老婆而言不存在，改不到也刪不掉（RLS 過濾，影響 0 列）。
  update public.entries set note = 'hacked' where id = '40000000-0000-0000-0000-000000000008';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, '老婆竟然改得動 mike 的私人筆';
  delete from public.entries where id = '40000000-0000-0000-0000-000000000008';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, '老婆竟然刪得掉 mike 的私人筆';
  -- 私人筆的細項與分攤也跟著看不見。
  assert not exists (
    select 1 from public.line_items li where li.entry_id = '40000000-0000-0000-0000-000000000008'
  ), '老婆竟然看得到 mike 私人筆的細項';
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
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, split_method)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 100,
            '30000000-0000-0000-0000-000000000001', current_date, '冒名', 
            '20000000-0000-0000-0000-000000000001', 'common');
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
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 100,
          '30000000-0000-0000-0000-000000000001', current_date, '自己的一筆',
          '20000000-0000-0000-0000-000000000002', 'common');
  assert (select count(*) from public.entries) = 9, '老婆新增後應看到 9 筆';
end;
$$;
rollback;

\echo '== rls: 老婆不能把 mike 的 shared entry 改成自己的／私人的（應失敗） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_rows int;
begin
  -- e-5「全聯買菜」是 mike 建的 shared entry，老婆看得到也編輯得動（共同帳目）。
  assert exists (select 1 from public.entries e
                 where e.id = '40000000-0000-0000-0000-000000000005'
                   and e.created_by = '20000000-0000-0000-0000-000000000001'),
    '前置條件不成立：e-5 應是 mike 建的 shared entry';

  -- 應失敗①：整筆據為己有＋改成私人（created_by 不可變）。
  begin
    update public.entries
      set created_by = '20000000-0000-0000-0000-000000000002', scope = 'private',
          payer_id = '20000000-0000-0000-0000-000000000002', split_method = 'common'
      where id = '40000000-0000-0000-0000-000000000005';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '老婆竟然能把 mike 的 shared entry 據為己有';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：只改 created_by（不動 scope）也一樣擋。
  v_blocked := false;
  begin
    update public.entries set created_by = '20000000-0000-0000-0000-000000000002'
      where id = '40000000-0000-0000-0000-000000000005';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'created_by 竟然改得動';
  -- 兩道防線都算通過：欄位級授權（review 3 後）或不可變 trigger（授權若被放寬時的第二道）。
  assert v_err like '%created_by is immutable%' or v_err like '%permission denied%',
    format('錯誤訊息不對：%s', v_err);

  -- 應失敗③：把別人的 shared entry 改成 private（with check 擋：改完自己就不該還看得到）。
  v_blocked := false;
  begin
    update public.entries set scope = 'private' where id = '40000000-0000-0000-0000-000000000005';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '老婆竟然能把 mike 的 shared entry 改成 private';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗④：ledger_id 不可變（不能把帳目搬到別的帳本）。
  v_blocked := false;
  begin
    update public.entries set ledger_id = gen_random_uuid()
      where id = '40000000-0000-0000-0000-000000000006';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'ledger_id 竟然改得動';
  assert v_err like '%ledger_id is immutable%' or v_err like '%permission denied%',
    format('錯誤訊息不對：%s', v_err);

  -- 對照組：共同帳目該編輯的部分照樣編輯得動（不是把整張表鎖死）。
  update public.entries set note = '全聯買菜（老婆補註）', amount = 600
    where id = '40000000-0000-0000-0000-000000000005';
  get diagnostics v_rows = row_count;
  assert v_rows = 1, '老婆應該還是能改共同帳目的金額與備註';
  assert (select created_by from public.entries e where e.id = '40000000-0000-0000-0000-000000000005')
         = '20000000-0000-0000-0000-000000000001'::uuid, 'created_by 應維持原值';
end;
$$;
rollback;

\echo '== rls: settlements／settlement_entries／settlement_signers 前端只讀（應失敗，review 1／2）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：直接寫一筆 status='settled' 的結算（修前可行，等於完全繞過多簽）。
  v_blocked := false;
  begin
    insert into public.settlements (ledger_id, initiated_by, nets, status)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
            '{}'::jsonb, 'settled');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接 insert settlements';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：直接改結算狀態。
  v_blocked := false;
  begin
    update public.settlements set status = 'settled';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接 update settlements';

  -- 應失敗③：直接刪結算。
  v_blocked := false;
  begin
    delete from public.settlements;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接 delete settlements';

  -- 應失敗④：直接寫 settlement_entries（自己挑要結哪幾筆）。
  v_blocked := false;
  begin
    insert into public.settlement_entries (settlement_id, entry_id)
    values (gen_random_uuid(), '40000000-0000-0000-0000-000000000005');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接 insert settlement_entries';

  -- 應失敗⑤：直接寫需簽者快照（自己把自己從名單移除）。
  v_blocked := false;
  begin
    insert into public.settlement_signers (settlement_id, member_id)
    values (gen_random_uuid(), '20000000-0000-0000-0000-000000000002');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接 insert settlement_signers';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== rls: entries 的 settled_state／created_by／ledger_id 前端寫不動（應失敗，review 3）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：直接把自己的帳目標成已結帳（修前可行，完全不需要任何結算）。
  v_blocked := false;
  begin
    update public.entries set settled_state = 'settled' where id = '40000000-0000-0000-0000-000000000005';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接把 entry 改成 settled';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：欄位級授權連 created_by／ledger_id 都沒給（不必等 trigger 就被擋）。
  v_blocked := false;
  begin
    update public.entries set created_by = '20000000-0000-0000-0000-000000000002'
      where id = '40000000-0000-0000-0000-000000000005';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能寫 created_by 欄位';

  -- 對照組：授權清單內的欄位照常寫得動。
  update public.entries set note = '照樣改得動', amount = 601
    where id = '40000000-0000-0000-0000-000000000005';
  assert (select amount from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = 601,
    '授權清單內的欄位應該還是寫得動';
end;
$$;
rollback;

\echo '== rls: 非成員不能窺探需簽者名單（應失敗，review 8）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  perform set_config('app.test_settlement', v_s.id::text, true);
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  begin
    perform public.required_signers(current_setting('app.test_settlement', true)::uuid);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然查得到需簽者名單';
  assert v_err like '%not a member%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== rls: 簽名只能走 approve_settlement RPC（應失敗，review 17）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  perform set_config('app.test_settlement', v_s.id::text, true);
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid := current_setting('app.test_settlement', true)::uuid;
  v_blocked boolean := false;
  v_err text;
  v_s public.settlements;
begin
  -- 應失敗：連「插自己的簽名」都收回了，只能走 RPC。
  begin
    insert into public.settlement_approvals (settlement_id, member_id)
    values (v_id, '20000000-0000-0000-0000-000000000002');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然還能直接 insert settlement_approvals';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 對照組：RPC 路徑照常可用。
  v_s := public.approve_settlement(v_id);
  assert v_s.status = 'settled', 'RPC 簽核應該正常運作';
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

  -- 對照組：改自己的暱稱與期初餘額可以。
  update public.members set display_name = '老婆大人', opening_balance_personal = 31000
    where id = '20000000-0000-0000-0000-000000000002';
  get diagnostics v_rows = row_count;
  assert v_rows = 1, '成員應該改得動自己那列';
end;
$$;
rollback;

\echo '== rls: 不能插出假的已結帳、不能 TRUNCATE、不能建帳本（應失敗，review A／B／J）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：直接 insert 一筆 settled_state='settled' 的假已結帳。
  -- 修前可行，而且建出來之後金額改不了（lock trigger）也刪不掉（delete policy），等於永久髒資料。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                                created_by, split_method, settled_state)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 5000,
            '30000000-0000-0000-0000-000000000001', current_date, '假已結帳',
            '20000000-0000-0000-0000-000000000002', 'common', 'settled');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能插出 settled_state=settled 的假已結帳';
  raise notice '  預期的失敗：%', v_err;

  -- 對照組：不指定 settled_state 的正常新增照樣可以，且一定是 open。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 5000,
          '30000000-0000-0000-0000-000000000001', current_date, '正常新增',
          '20000000-0000-0000-0000-000000000002', 'common');
  assert (select settled_state from public.entries e where e.note = '正常新增') = 'open',
    '新增的帳目一定要是 open';

  -- 應失敗②：TRUNCATE（不受 RLS，拿到就能清空整表）。
  v_blocked := false;
  begin
    truncate public.entries cascade;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能 TRUNCATE entries';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗③：直接建帳本（只能走 create_ledger）。
  v_blocked := false;
  begin
    insert into public.ledgers (name) values ('偷建的帳本');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能直接建帳本';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗④：改／刪別人的簽名（review C）。
  v_blocked := false;
  begin
    delete from public.settlement_approvals;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然能刪簽名';
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

  -- 應失敗①：直接把邀請碼改成自己記得住的字串（等於自選密碼）。
  begin
    update public.ledgers set invite_code = 'AAAAAAAAAA'
      where id = '10000000-0000-0000-0000-000000000001';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '成員竟然能自選邀請碼';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：改別人的期初餘額（欄位有開，但 policy 限自己那列）。
  v_blocked := false;
  begin
    update public.members set opening_balance_personal = 0
      where id = '20000000-0000-0000-0000-000000000001';
    if not found then v_blocked := true; v_err := 'RLS 過濾，影響 0 列'; end if;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '成員竟然改得動別人的期初餘額';

  -- 對照組：走 RPC 換邀請碼可以，而且真的換掉了。
  v_l := public.rotate_invite_code('10000000-0000-0000-0000-000000000001');
  assert v_l.invite_code <> v_old, '邀請碼應該被換掉';
  assert v_l.invite_code ~ '^[A-Z0-9]{10}$', format('新邀請碼格式不對：%s', v_l.invite_code);

  -- 對照組：帳本名稱與 default_ratio 照樣改得動。
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
  assert auth.uid() is null, 'anon 不該有 auth.uid()';
end;
$$;
rollback;

\echo '== rls: search_items 受 RLS（老婆搜不到 mike 私人筆的字） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  assert exists (select 1 from public.search_items('10000000-0000-0000-0000-000000000001', 'Steam')),
    'mike 應搜得到自己的私人筆';
  assert (select count(*) from public.search_items('10000000-0000-0000-0000-000000000001', '雞蛋')) = 3,
    format('雞蛋應有 3 筆細項，實際 %s', (select count(*) from public.search_items('10000000-0000-0000-0000-000000000001', '雞蛋')));
end;
$$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  assert not exists (select 1 from public.search_items('10000000-0000-0000-0000-000000000001', 'Steam')),
    '老婆竟然搜得到 mike 的私人筆';
  assert exists (select 1 from public.search_items('10000000-0000-0000-0000-000000000001', '牛奶')),
    '老婆應搜得到共同筆的細項與清單';
end;
$$;
rollback;

\echo 'rls.sql PASS'
