-- 預算影子紀錄（budget_allocation）測試 — ADR-0008／spec v1.4。
-- v1.4 起：每分類每月至多一筆、金額 > 0、建立後不可改不可刪（v1.5 沒有動這一組規則）。
-- 「已花」的口徑在 v1.5 改成「該分類該月全部支出、不分誰付」，那條在 month_summary.sql 驗。
-- 一段只驗一條規則，各自獨立 fixture，全部包在 begin/rollback 裡。
-- 身分模擬與 rls.sql 相同：request.jwt.claims + set local role authenticated。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set WIFE_M '20000000-0000-0000-0000-000000000002'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set CAT_FOOD '30000000-0000-0000-0000-000000000001'
\set CAT_INCOME '30000000-0000-0000-0000-000000000008'
-- 種子在「本月」已經給食品／日常用品／交通各設了一筆預算，
-- 每分類每月只能一筆，所以要新增的段落一律用種子沒碰過的「住房」「娛樂」。
\set CAT_HOUSE '30000000-0000-0000-0000-000000000004'
\set CAT_PLAY '30000000-0000-0000-0000-000000000007'
\set CAT_TRAFFIC '30000000-0000-0000-0000-000000000006'

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
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
          1200, current_date, '本月住房', '20000000-0000-0000-0000-000000000001')
  returning id into v_id;

  select * into v_row from public.budget_allocation b where b.id = v_id;
  assert v_row.id is not null, '成員撥款後應查得回來';
  assert v_row.amount = 1200, format('金額不對：%s', v_row.amount);
  assert v_row.note = '本月住房', '備註不對';
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

\echo '== budget: a3. budget_allocation 只剩 SELECT／INSERT 兩個 policy（v1.4 收回改刪）=='
do $$
declare
  v_cmds text;
begin
  select string_agg(distinct cmd, ',' order by cmd) into v_cmds
  from pg_policies where schemaname = 'public' and tablename = 'budget_allocation';
  assert v_cmds = 'INSERT,SELECT',
    format('budget_allocation 的 policy 動詞應只剩 INSERT／SELECT：%s', v_cmds);
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
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
            800, current_date, '20000000-0000-0000-0000-000000000002');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能以老婆的名義撥款';
  assert v_err like '%row-level security%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 反面：填自己的 member id 就進得去。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
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

\echo '== budget: d. amount <= 0 被擋（0 與負數各一條；v1.4 起沒有退回）=='
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
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
            0, current_date, '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'amount = 0 竟然入得了';
  assert v_err like '%budget_allocation_amount_positive%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- v1.4：撥款不再是流水、沒有「退回」，負數一律擋掉（ADR-0008 決策 6）。
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
            -700, current_date, '想退回', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '負數（退回）竟然還入得了';
  assert v_err like '%budget_allocation_amount_positive%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== budget: e. 設定後不可改不可刪（UPDATE／DELETE 皆 42501），insert 仍不給填 created_at =='
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
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
          1000, current_date, '20000000-0000-0000-0000-000000000001')
  returning id into v_id;

  -- 應失敗①：改金額（v1.4 起整張表對前端沒有 UPDATE 授權）。
  begin
    update public.budget_allocation set amount = 1500 where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然改得動已設定的預算';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：改備註（同樣一欄都沒開）。
  v_blocked := false;
  begin
    update public.budget_allocation set note = '改備註' where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然改得動備註';

  -- 應失敗③：刪掉重設（不可退回）。
  v_blocked := false;
  begin
    delete from public.budget_allocation where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然刪得掉已設定的預算';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
  assert (select count(*) from public.budget_allocation b where b.id = v_id) = 1, '那筆預算應該還在';

  -- 應失敗④：insert 自己填 created_at（欄位級 INSERT 授權沒給這欄）。
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by, created_at)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000007',
            100, current_date, '20000000-0000-0000-0000-000000000001', now() - interval '1 year');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然填得了 created_at';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
end;
$$;
rollback;

\echo '== budget: f. 每分類每月至多一筆（第二筆 23505），不同月可以 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_month date := date_trunc('month', current_date)::date;
  v_blocked boolean := false;
  v_err text;
  v_state text;
begin
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
          9000, v_month, '本月住房', '20000000-0000-0000-0000-000000000001')
  returning id into v_id;
  assert (select b.month from public.budget_allocation b where b.id = v_id) = v_month,
    'month 欄應由 occurred_on 推導成月初';

  -- 同分類同月第二筆（日期不同也不行）→ unique violation。
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
            500, v_month + 10, '再加碼', '20000000-0000-0000-0000-000000000001');
  exception when unique_violation then
    v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked, '同分類同月竟然設得了第二筆預算';
  assert v_state = '23505', format('SQLSTATE 應是 23505，實際 %s', v_state);
  raise notice '  預期的失敗：%', v_err;

  -- 不同月可以（同分類、下個月）。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004',
          9000, (v_month + interval '1 month')::date, '下月住房', '20000000-0000-0000-0000-000000000001')
  returning id into v_id;
  assert (select b.month from public.budget_allocation b where b.id = v_id)
         = (v_month + interval '1 month')::date, '下個月那筆的 month 不對';

  -- 同月不同分類也可以。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000007',
          1200, v_month, '本月娛樂', '20000000-0000-0000-0000-000000000001');
end;
$$;
rollback;

\echo '== budget: g. v1.3 的 funding 與 v1.4 的 scope／split_method 都已 drop；upsert_entry 忽略多餘的鍵 =='
do $$
begin
  assert not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'entries'
                       and column_name in ('funding', 'scope', 'split_method', 'settled_state')),
    'entries 不該再有 funding／scope／split_method／settled_state（ADR-0008／0009）';
  assert not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                     where n.nspname = 'public' and t.typname = 'funding'),
    'funding enum 應該已經被移除（ADR-0008）';
  assert not exists (select 1 from pg_constraint
                     where conname = 'entries_funding_common_wallet_only'),
    'entries_funding_common_wallet_only 應該隨欄位一起消失';
  assert not exists (select 1 from information_schema.column_privileges cp
                     where cp.table_schema = 'public' and cp.table_name = 'entries'
                       and cp.column_name in ('funding', 'scope', 'split_method')),
    '這些欄位的欄位級授權應該隨欄位一起消失';
end;
$$;

begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_entry public.entries;
begin
  -- 舊版前端還會送 funding／scope／split_method 這些鍵：
  -- jsonb 的多餘鍵本來就不影響，不該炸也不該留下任何痕跡。
  v_entry := public.upsert_entry(jsonb_build_object(
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'kind', 'expense', 'scope', 'shared', 'amount', 900,
    'category_id', '30000000-0000-0000-0000-000000000001',
    'occurred_on', current_date, 'note', '共同錢包支出',
    'split_method', 'equal', 'funding', 'budget'));
  assert v_entry.id is not null, 'upsert_entry 帶多餘的鍵不該失敗';
  assert v_entry.amount = 900 and v_entry.note = '共同錢包支出', '其餘欄位應照寫';
  assert v_entry.payer_id is null, '沒帶 payer_id 時是共同錢包';

  -- 改成成員先付：payer_id 照寫，多餘的鍵照樣沒有作用。
  v_entry := public.upsert_entry(jsonb_build_object(
    'id', v_entry.id,
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'payer_id', '20000000-0000-0000-0000-000000000001',
    'split_method', 'equal',
    'funding', 'budget'));
  assert v_entry.payer_id = '20000000-0000-0000-0000-000000000001'::uuid, 'payer_id 應改成 Mike';
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

\echo '== budget: j1. 遷移前快照：archive.budget_allocation_v13 存在且前端完全碰不到 =='
do $$
begin
  assert exists (select 1 from information_schema.tables
                 where table_schema = 'archive' and table_name = 'budget_allocation_v13'),
    'archive.budget_allocation_v13 應該存在（0027 的遷移前快照）';
  -- 快照放 archive 而不是 public：public 每張表都要開 RLS（rls.sql 全表掃描），
  -- 而快照沒有 RLS 也不該有——所以改用「前端連 schema 都進不去」這道。
  assert not exists (select 1 from information_schema.role_table_grants
                     where table_schema = 'archive'
                       and grantee in ('anon', 'authenticated')),
    '前端角色不該對 archive schema 的表有任何權限';
  -- 表權限之外，schema 的 USAGE 本身也要是關的：沒有 USAGE 就連表名都解析不到，
  -- 日後有人手滑 grant 了表權限，這條會先攔下來。
  assert not has_schema_privilege('anon', 'archive', 'usage'),
    'anon 不該有 archive schema 的 USAGE';
  assert not has_schema_privilege('authenticated', 'archive', 'usage'),
    'authenticated 不該有 archive schema 的 USAGE';
end;
$$;

begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_n int;
begin
  begin
    select count(*) into v_n from archive.budget_allocation_v13;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然讀得到遷移前快照';
  assert v_err like '%permission denied for schema archive%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== budget: j2. 合併規則鏡像（v1.3 撥款流水 → v1.4 每分類每月一筆）=='
-- ⚠️ 這一段是 20260904000200_rules_v14.sql 第 3a 節那句合併 SQL 的**鏡像**：
--    地端 db reset 時 budget_allocation 是空的（seed 在 migration 之後才跑），
--    真正的那句在地端永遠是 no-op，等於沒被測到。這裡用 temp table 造出雲端才有的形狀來驗。
--    **改 migration 的合併 SQL 就要同步改這一段，反之亦然。**
begin;
create temp table ba_mirror (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null,
  category_id uuid not null,
  amount int not null,
  occurred_on date not null,
  note text not null default '',
  created_by uuid not null,
  created_at timestamptz not null default now()
) on commit drop;

insert into ba_mirror (id, ledger_id, category_id, amount, occurred_on, note, created_by, created_at) values
  -- ① 同分類同月三筆：撥 5,000 → 加碼 2,000 → 退回 1,000，合計 6,000（最早那筆備註是空的）
  ('50000000-0000-0000-0000-000000000001', :'LEDGER', :'CAT_FOOD',  5000, date '2026-03-04', '',     :'MIKE_M', '2026-03-04 10:00+08'),
  ('50000000-0000-0000-0000-000000000002', :'LEDGER', :'CAT_FOOD',  2000, date '2026-03-02', '加碼', :'WIFE_M', '2026-03-05 10:00+08'),
  ('50000000-0000-0000-0000-000000000003', :'LEDGER', :'CAT_FOOD', -1000, date '2026-03-20', '退回', :'WIFE_M', '2026-03-06 10:00+08'),
  -- ② 撥了又全退 → 合計 0 → 整組刪除
  ('50000000-0000-0000-0000-000000000004', :'LEDGER', :'CAT_HOUSE', 1000, date '2026-03-01', '撥',   :'MIKE_M', '2026-03-01 10:00+08'),
  ('50000000-0000-0000-0000-000000000005', :'LEDGER', :'CAT_HOUSE',-1000, date '2026-03-09', '全退', :'MIKE_M', '2026-03-09 10:00+08'),
  -- ③ 合計為負 → 也整組刪除
  ('50000000-0000-0000-0000-000000000006', :'LEDGER', :'CAT_PLAY',   500, date '2026-03-01', '撥',   :'MIKE_M', '2026-03-01 10:00+08'),
  ('50000000-0000-0000-0000-000000000007', :'LEDGER', :'CAT_PLAY',  -800, date '2026-03-05', '超退', :'MIKE_M', '2026-03-05 10:00+08'),
  -- ④ 單筆、不同月 → 原封不動
  ('50000000-0000-0000-0000-000000000008', :'LEDGER', :'CAT_FOOD',  4000, date '2026-02-03', '上月', :'WIFE_M', '2026-02-03 10:00+08'),
  -- ⑤ created_at 完全並列 → 由 id 決定先後（結果必須穩定）
  ('50000000-0000-0000-0000-00000000000b', :'LEDGER', :'CAT_TRAFFIC', 300, date '2026-03-08', 'B 先建', :'WIFE_M', '2026-03-07 10:00+08'),
  ('50000000-0000-0000-0000-00000000000a', :'LEDGER', :'CAT_TRAFFIC', 700, date '2026-03-06', 'A 先建', :'MIKE_M', '2026-03-07 10:00+08');

-- ↓↓↓ 以下這句與 migration 第 3a 節逐字相同，只有表名不同 ↓↓↓
with grouped as (
  select b.ledger_id,
         b.category_id,
         date_trunc('month', b.occurred_on)::date as m,
         sum(b.amount)::int as total,
         min(b.occurred_on) as min_occurred,
         (array_remove(array_agg(nullif(btrim(b.note), '') order by b.created_at, b.id), null))[1] as keep_note,
         (array_agg(b.id order by b.created_at, b.id))[1] as keep_id
  from ba_mirror b
  group by b.ledger_id, b.category_id, date_trunc('month', b.occurred_on)::date
),
merged as (
  delete from ba_mirror b
  using grouped g
  where b.ledger_id = g.ledger_id
    and b.category_id = g.category_id
    and date_trunc('month', b.occurred_on)::date = g.m
    and (g.total <= 0 or b.id <> g.keep_id)
  returning b.id
)
update ba_mirror b
   set amount = g.total,
       occurred_on = g.min_occurred,
       note = coalesce(g.keep_note, '')
  from grouped g
 where b.id = g.keep_id
   and g.total > 0
   and (b.amount, b.occurred_on, b.note) is distinct from (g.total, g.min_occurred, coalesce(g.keep_note, ''));
-- ↑↑↑ 鏡像結束 ↑↑↑

do $$
declare r ba_mirror;
begin
  assert (select count(*) from ba_mirror) = 3,
    format('合併後應剩 3 列（食品 3 月、食品 2 月、交通 3 月），實際 %s', (select count(*) from ba_mirror));

  -- ① 含負數但合計仍 > 0：合併成一列，欄位各取各的規則
  select * into r from ba_mirror where id = '50000000-0000-0000-0000-000000000001';
  assert r.amount = 6000, format('①合計應 6,000（5,000＋2,000−1,000），實際 %s', r.amount);
  assert r.occurred_on = date '2026-03-02', format('①occurred_on 應取該組最小，實際 %s', r.occurred_on);
  assert r.note = '加碼', format('①note 應取最早的非空備註，實際 %s', r.note);
  assert r.created_by = '20000000-0000-0000-0000-000000000001'::uuid, format('①created_by 應是最早那列的，實際 %s', r.created_by);

  -- ②③ 合計 ≤ 0 整組刪除
  assert not exists (select 1 from ba_mirror where category_id = '30000000-0000-0000-0000-000000000004'::uuid),
    '②合計 0 的組合應整組刪除';
  assert not exists (select 1 from ba_mirror where category_id = '30000000-0000-0000-0000-000000000007'::uuid),
    '③合計為負的組合應整組刪除';

  -- ④ 單筆不同月：原封不動
  select * into r from ba_mirror where id = '50000000-0000-0000-0000-000000000008';
  assert r.amount = 4000 and r.note = '上月' and r.occurred_on = date '2026-02-03',
    format('④單筆應原封不動：%s', r);

  -- ⑤ created_at 並列 → id 小的勝出（結果穩定，不隨掃描順序漂）
  select * into r from ba_mirror where category_id = '30000000-0000-0000-0000-000000000006'::uuid;
  assert r.id = '50000000-0000-0000-0000-00000000000a', format('⑤並列時應由 id 決定保留哪列，實際 %s', r.id);
  assert r.amount = 1000, format('⑤合計應 1,000，實際 %s', r.amount);
  assert r.note = 'A 先建', format('⑤note 應取 (created_at, id) 排序第一個非空，實際 %s', r.note);
  assert r.created_by = '20000000-0000-0000-0000-000000000001'::uuid, format('⑤created_by 應是 id 小的那列，實際 %s', r.created_by);

  -- 合併後 v1.4 的兩道約束在真表上加得起來（migration 的實際順序）
  assert not exists (select 1 from ba_mirror where amount <= 0), '合併後不該剩下 amount <= 0';
  assert not exists (
    select 1 from ba_mirror group by ledger_id, category_id, date_trunc('month', occurred_on)
    having count(*) > 1), '合併後不該剩下同分類同月多筆';
end;
$$;
rollback;

\echo 'budget.sql PASS'
