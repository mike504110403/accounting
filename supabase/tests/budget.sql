-- 預算撥款（budget_allocation）與資金來源（entries.funding）測試 — ADR-0007／spec v1.3。
-- 一段只驗一條規則，各自獨立 fixture，全部包在 begin/rollback 裡。
-- 身分模擬與 rls.sql 相同：request.jwt.claims + set local role authenticated。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set WIFE_M '20000000-0000-0000-0000-000000000002'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set CAT_FOOD '30000000-0000-0000-0000-000000000001'
\set CAT_INCOME '30000000-0000-0000-0000-000000000008'

\echo '== budget: a1. 成員能撥款（前端真實路徑：authenticated 直接 insert）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_row public.budget_allocation;
begin
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
          1200, current_date, '加碼買菜', '20000000-0000-0000-0000-000000000001')
  returning id into v_id;

  select * into v_row from public.budget_allocation b where b.id = v_id;
  assert v_row.id is not null, '成員撥款後應查得回來';
  assert v_row.amount = 1200, format('金額不對：%s', v_row.amount);
  assert v_row.note = '加碼買菜', '備註不對';
end;
$$;
rollback;

\echo '== budget: a2. 非成員 insert 被 RLS 擋（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
-- Mike 另開一本帳（老婆不是成員），把 id 與一個支出分類記下來。
do $$
declare
  v_l public.ledgers;
  v_cat uuid;
begin
  v_l := public.create_ledger('Mike 一個人的帳');
  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;
  perform set_config('app.other_ledger', v_l.id::text, true);
  perform set_config('app.other_cat', v_cat::text, true);
end;
$$;

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  assert (select count(*) from public.budget_allocation b
           where b.ledger_id = current_setting('app.other_ledger')::uuid) = 0,
    '老婆不該看得到別人帳本的撥款';
  -- 預期形狀寫死：RLS 的 insert policy 違反＝42501（insufficient_privilege），
  -- 別的錯誤（FK、trigger）不接受，會直接讓這段爆掉。
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values (current_setting('app.other_ledger')::uuid, current_setting('app.other_cat')::uuid,
            500, current_date, '20000000-0000-0000-0000-000000000002');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然撥得了款';
  assert v_err like '%row-level security%', format('錯誤訊息不對：%s', v_err);
  assert (select count(*) from public.budget_allocation b
           where b.ledger_id = current_setting('app.other_ledger')::uuid) = 0,
    '非成員的撥款竟然留下了資料';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== budget: a3. budget_allocation 四個動詞都有 policy（RLS 第二道門）=='
do $$
declare
  v_cmds text;
begin
  select string_agg(distinct cmd, ',' order by cmd) into v_cmds
  from pg_policies where schemaname = 'public' and tablename = 'budget_allocation';
  assert v_cmds = 'DELETE,INSERT,SELECT,UPDATE',
    format('budget_allocation 的 policy 動詞不齊：%s', v_cmds);
end;
$$;

\echo '== budget: b. 不能以別人的名義撥款（RLS with check，應失敗 42501）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_blocked boolean := false;
  v_err text;
begin
  -- 以 Mike 身分撥款，卻硬塞老婆的 member id → insert policy 的 with check 擋掉（比照 entries）。
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
            800, current_date, '20000000-0000-0000-0000-000000000002');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能以老婆的名義撥款';
  assert v_err like '%row-level security%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 反面：填自己的 member id 就進得去。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
          800, current_date, '20000000-0000-0000-0000-000000000001')
  returning id into v_id;
  assert (select b.created_by from public.budget_allocation b where b.id = v_id)
         = '20000000-0000-0000-0000-000000000001'::uuid, '自己撥的款 created_by 應是自己';
end;
$$;
rollback;

\echo '== budget: c1. 收入分類不能撥款（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000008',
            1000, current_date, '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '收入分類竟然撥得了款';
  assert v_err like '%expense%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== budget: c2. 別的帳本的分類不能撥款（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_cat uuid;
  v_blocked boolean := false;
  v_err text;
begin
  v_l := public.create_ledger('Mike 的第二本帳');
  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', v_cat,
            1000, current_date, '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能拿別的帳本的分類撥款';
  assert v_err like '%budget_allocation_category_same_ledger%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== budget: d. amount = 0 被擋、負數（退回）可入 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_id uuid;
begin
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
            0, current_date, '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'amount = 0 竟然入得了';
  assert v_err like '%budget_allocation_amount_nonzero%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 負數＝退回，必須進得去。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
          -700, current_date, '月底退回', '20000000-0000-0000-0000-000000000001')
  returning id into v_id;
  assert (select b.amount from public.budget_allocation b where b.id = v_id) = -700, '退回（負數）應可入';
end;
$$;
rollback;

\echo '== budget: e. 欄位級授權：update 只開三欄、insert 不給填 id／created_at（違反皆 42501）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_blocked boolean := false;
  v_err text;
begin
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
          1000, current_date, '20000000-0000-0000-0000-000000000001')
  returning id into v_id;

  -- 應失敗①：改 created_by（欄位級授權沒給這欄 → 42501）。
  begin
    update public.budget_allocation set created_by = '20000000-0000-0000-0000-000000000002' where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然改得了 created_by';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：改 ledger_id。
  v_blocked := false;
  begin
    update public.budget_allocation set ledger_id = gen_random_uuid() where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然改得了 ledger_id';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);

  -- 應失敗③：改 category_id（換分類＝換一筆撥款，請刪掉重開）。
  v_blocked := false;
  begin
    update public.budget_allocation set category_id = '30000000-0000-0000-0000-000000000002' where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然改得了 category_id';

  -- 應失敗④：insert 自己填 created_at（欄位級 INSERT 授權沒給這欄）。
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by, created_at)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
            100, current_date, '20000000-0000-0000-0000-000000000001', now() - interval '1 year');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然填得了 created_at';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 可以改的三欄。
  update public.budget_allocation set amount = 1500, note = '改金額', occurred_on = current_date - 1 where id = v_id;
  assert (select b.amount from public.budget_allocation b where b.id = v_id) = 1500, 'amount 應改得動';
  assert (select b.note from public.budget_allocation b where b.id = v_id) = '改金額', 'note 應改得動';
end;
$$;
rollback;

\echo '== budget: f. entries.funding 只有共同錢包的共同支出可選 budget =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_blocked boolean := false;
  v_err text;
begin
  -- 可以：共同錢包（payer_id is null）的共同支出。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method, funding)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 300,
          '30000000-0000-0000-0000-000000000001', current_date, '共同錢包買菜',
          '20000000-0000-0000-0000-000000000001', null, 'common', 'budget')
  returning id into v_id;
  assert (select e.funding from public.entries e where e.id = v_id) = 'budget', 'funding 應為 budget';

  -- 應失敗①：代墊（payer_id 是成員）。
  begin
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                                created_by, payer_id, split_method, funding)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 300,
            '30000000-0000-0000-0000-000000000001', current_date, '代墊也想吃預算',
            '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'equal', 'budget');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '代墊竟然能用預算';
  assert v_err like '%entries_funding_common_wallet_only%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：私人支出。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                                created_by, payer_id, split_method, funding)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 'private', 300,
            '30000000-0000-0000-0000-000000000001', current_date, '私人也想吃預算',
            '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'common', 'budget');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '私人支出竟然能用預算';
  assert v_err like '%entries_funding_common_wallet_only%', format('錯誤訊息不對：%s', v_err);

  -- 應失敗③：收入。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                                created_by, payer_id, split_method, funding)
    values ('10000000-0000-0000-0000-000000000001', 'income', 'shared', 300,
            '30000000-0000-0000-0000-000000000008', current_date, '收入也想吃預算',
            '20000000-0000-0000-0000-000000000001', null, 'common', 'budget');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '收入竟然能用預算';
  assert v_err like '%entries_funding_common_wallet_only%', format('錯誤訊息不對：%s', v_err);

  -- 預設是 balance。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 300,
          '30000000-0000-0000-0000-000000000001', current_date, '沒指定資金來源',
          '20000000-0000-0000-0000-000000000001', null, 'common')
  returning id into v_id;
  assert (select e.funding from public.entries e where e.id = v_id) = 'balance', 'funding 預設應為 balance';
end;
$$;
rollback;

\echo '== budget: g. upsert_entry 帶 funding（前端真實路徑：RPC → 撥款 → 查回來）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_entry public.entries;
  v_alloc uuid;
  v_blocked boolean := false;
  v_err text;
begin
  -- ① RPC 新增一筆用預算支付的共同錢包支出。
  v_entry := public.upsert_entry(jsonb_build_object(
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'kind', 'expense', 'scope', 'shared', 'amount', 900,
    'category_id', '30000000-0000-0000-0000-000000000001',
    'occurred_on', current_date, 'note', '共同錢包・預算支付',
    'funding', 'budget'));
  assert v_entry.funding = 'budget', format('upsert_entry 應寫入 funding=budget，實際 %s', v_entry.funding);

  -- ② 只改備註時 funding 不變。
  v_entry := public.upsert_entry(jsonb_build_object(
    'id', v_entry.id,
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'note', '只改備註'));
  assert v_entry.funding = 'budget', format('只改備註不該動到 funding，實際 %s', v_entry.funding);
  assert v_entry.note = '只改備註', 'note 應改到';

  -- ②b 把 payer_id 從 null 改成成員（改代墊）卻沒送 funding：舊的 budget 留著 → check 擋（23514）。
  begin
    v_entry := public.upsert_entry(jsonb_build_object(
      'id', v_entry.id,
      'ledger_id', '10000000-0000-0000-0000-000000000001',
      'payer_id', '20000000-0000-0000-0000-000000000001',
      'split_method', 'equal'));
    v_blocked := false;
  exception when check_violation then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '改成代墊卻沒改資金來源，竟然過得了';
  assert v_err like '%entries_funding_common_wallet_only%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- ②c 同一次呼叫補送 funding = balance 就成功（契約文件寫明的做法）。
  v_entry := public.upsert_entry(jsonb_build_object(
    'id', v_entry.id,
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'payer_id', '20000000-0000-0000-0000-000000000001',
    'split_method', 'equal',
    'funding', 'balance'));
  assert v_entry.funding = 'balance', format('補送 funding 後應為 balance，實際 %s', v_entry.funding);
  assert v_entry.payer_id = '20000000-0000-0000-0000-000000000001'::uuid, 'payer_id 應改成 Mike';

  -- ②d 改回共同錢包＋預算。
  v_entry := public.upsert_entry(jsonb_build_object(
    'id', v_entry.id,
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'payer_id', null, 'split_method', 'common', 'funding', 'budget'));
  assert v_entry.funding = 'budget', '改回共同錢包＋預算應成功';

  -- ③ 明確指定改回 balance（共同錢包的支出兩種資金來源都合法）。
  v_entry := public.upsert_entry(jsonb_build_object(
    'id', v_entry.id,
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'funding', 'balance'));
  assert v_entry.funding = 'balance', format('funding 應改成 balance，實際 %s', v_entry.funding);

  -- ③b 直接對 entries 寫 funding 也要通（B1：欄位級 INSERT／UPDATE 授權要含 funding）。
  update public.entries set funding = 'budget' where id = v_entry.id;
  assert (select e.funding from public.entries e where e.id = v_entry.id) = 'budget',
    'authenticated 應能直接 update entries.funding（欄位級授權）';

  -- ④ 同一條前端路徑接著撥款，並查回來。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
          2000, date_trunc('month', current_date)::date, '本月食品加碼',
          '20000000-0000-0000-0000-000000000001')
  returning id into v_alloc;
  assert (select b.created_by from public.budget_allocation b where b.id = v_alloc)
         = '20000000-0000-0000-0000-000000000001'::uuid, '撥款人應是呼叫者';
end;
$$;
rollback;

\echo '== budget: h. realtime publication 收錄 budget_allocation =='
do $$
begin
  assert exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'budget_allocation'),
    'budget_allocation 不在 supabase_realtime publication 裡';
end;
$$;

\echo '== budget: i. budgets 表與 categories.rollover 已移除 =='
do $$
begin
  assert not exists (select 1 from information_schema.tables
                     where table_schema = 'public' and table_name = 'budgets'),
    'budgets 表應該已經被移除（ADR-0007）';
  assert not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'categories' and column_name = 'rollover'),
    'categories.rollover 應該已經被移除（ADR-0007）';
end;
$$;

\echo 'budget.sql PASS'
