-- personal_topups（ADR-0009 決策 2）的公開面測試：RLS、授權、check、鎖月。
-- 一律以 `set local role authenticated` ＋ request.jwt.claims 模擬前端呼叫者，
-- 不用 postgres 身分寫入（那會繞過 RLS，測了等於沒測）。
--
-- 注意：psql 不會在 dollar-quoted 區塊內代換 :'VAR'，所以 DO 區塊裡的 UUID 一律寫死。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'

\echo '== topups: t01. 表結構——month 是 generated、amount > 0 的 check 名、複合 FK 綁同帳本 =='
do $$
declare
  v_gen text;
  v_missing text;
begin
  select c.is_generated into v_gen
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'personal_topups' and c.column_name = 'month';
  assert v_gen = 'ALWAYS', format('personal_topups.month 應該是 generated 欄位，實際 %s', coalesce(v_gen, '（不存在）'));

  select string_agg(x, ', ') into v_missing
  from unnest(array['personal_topups_amount_positive',
                    'personal_topups_member_same_ledger',
                    'personal_topups_created_by_same_ledger']) x
  where not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'personal_topups' and con.conname = x);
  assert v_missing is null, format('personal_topups 少了這些 constraint：%s', v_missing);

  -- 索引：帳本＋期間（realtime／列表）、成員（FK 與清帳明細），
  -- 以及熱查詢的三欄形狀「這本帳、這個人、這個月」（month_summary 與 month_close_details 都是它）。
  select string_agg(x, ', ') into v_missing
  from unnest(array['personal_topups_ledger_occurred_idx', 'personal_topups_member_idx',
                    'personal_topups_ledger_member_month_idx']) x
  where not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = x);
  assert v_missing is null, format('personal_topups 少了這些索引：%s', v_missing);
end;
$$;

\echo '== topups: t02. 成員記自己的補入（前端真實路徑：authenticated 直接 insert）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_month date;
begin
  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          1500, current_date, '加碼', '20000000-0000-0000-0000-000000000001')
  returning id, month into v_id, v_month;

  assert v_month = (date_trunc('month', current_date))::date,
    format('month 應由 occurred_on 推導成月初，實際 %s', v_month);
  -- 兩人都看得到彼此的補入（spec：預算頁每位成員一列）。
  assert (select count(*) from public.personal_topups) = 6, '新增後應看得到 6 筆補入';
  assert (select note from public.personal_topups where id = v_id) = '加碼', '寫進去的備註不見了';
end;
$$;
rollback;

\echo '== topups: t02b. INSERT 是欄位級——id 與 created_at 前端填不了（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- created_at 是「這筆補入是哪一刻記的」的唯一來源，不能讓前端自己填。
  v_blocked := false;
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by, created_at)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            100, current_date, '20000000-0000-0000-0000-000000000001', now() - interval '1 year');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然填得了 created_at';
  raise notice '  預期的失敗：%', v_err;

  v_blocked := false;
  begin
    insert into public.personal_topups (id, ledger_id, member_id, amount, occurred_on, created_by)
    values (gen_random_uuid(), '10000000-0000-0000-0000-000000000001',
            '20000000-0000-0000-0000-000000000001', 100, current_date,
            '20000000-0000-0000-0000-000000000001');
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然填得了 id';

  -- month 是 generated 欄，連授權都談不上。
  v_blocked := false;
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by, month)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            100, current_date, '20000000-0000-0000-0000-000000000001', current_date);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'month 是 generated 欄，不該寫得進去';
end;
$$;
rollback;

\echo '== topups: t03. 只能補自己的：他人 member_id 被 RLS 擋（42501）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_state text;
begin
  -- 應失敗①：以自己的名義補到老婆頭上。
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
            999, current_date, '幫老婆補', '20000000-0000-0000-0000-000000000001');
  exception when others then
    v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked, 'Mike 竟然能補到老婆頭上';
  assert v_state = '42501', format('應是 42501（RLS with check），實際 %s：%s', v_state, v_err);
  raise notice '  預期的失敗：% (%)', v_err, v_state;

  -- 應失敗②：member_id 是自己，但 created_by 掛別人（不能以別人的名義記帳）。
  v_blocked := false;
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            999, current_date, '冒名', '20000000-0000-0000-0000-000000000002');
  exception when others then
    v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked, 'created_by 竟然可以掛別人';
  assert v_state = '42501', format('應是 42501，實際 %s：%s', v_state, v_err);
end;
$$;
rollback;

\echo '== topups: t04. 非成員完全寫不進去（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  assert (select count(*) from public.personal_topups) = 0, '非成員竟然看得到別人的補入';
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            500, current_date, '外人', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然寫得進別人帳本的補入';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== topups: t05. amount <= 0 被 check personal_topups_amount_positive 擋 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_amount int;
  v_blocked boolean;
  v_err text;
  v_state text;
begin
  foreach v_amount in array array[0, -100] loop
    v_blocked := false;
    begin
      insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
      values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
              v_amount, current_date, '不該過', '20000000-0000-0000-0000-000000000001');
    exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
    end;
    assert v_blocked, format('amount = %s 竟然寫得進去', v_amount);
    assert v_state = '23514', format('應是 check violation 23514，實際 %s', v_state);
    assert v_err like '%personal_topups_amount_positive%',
      format('錯誤訊息應點名 personal_topups_amount_positive，實際：%s', v_err);
    raise notice '  預期的失敗（amount=%）：%', v_amount, v_err;
  end loop;
end;
$$;
rollback;

\echo '== topups: t06. 補入不能改，只能刪了重記（UPDATE 一律 42501）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_state text;
  v_id uuid;
begin
  select t.id into v_id from public.personal_topups t
  where t.member_id = '20000000-0000-0000-0000-000000000001'
    and t.month = (date_trunc('month', current_date))::date
  order by t.occurred_on limit 1;
  assert v_id is not null, '前置條件不成立：Mike 本月應有補入';

  begin
    update public.personal_topups set amount = 1 where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked, '補入竟然改得動（應該連 UPDATE 授權都沒有）';
  assert v_state = '42501', format('應是 permission denied 42501，實際 %s：%s', v_state, v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== topups: t07. 未清月可刪自己的、刪不掉別人的 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_rows int;
  v_id uuid;
begin
  -- 刪自己的：成功。
  select t.id into v_id from public.personal_topups t
  where t.member_id = '20000000-0000-0000-0000-000000000001'
    and t.month = (date_trunc('month', current_date))::date
  order by t.occurred_on limit 1;
  delete from public.personal_topups where id = v_id;
  get diagnostics v_rows = row_count;
  assert v_rows = 1, '成員應該刪得掉自己未清月的補入';

  -- 刪別人的：RLS 過濾成 0 列（不是報錯，是看不到）。
  delete from public.personal_topups
  where member_id = '20000000-0000-0000-0000-000000000002';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, '成員竟然刪得掉別人的補入';
  assert (select count(*) from public.personal_topups
           where member_id = '20000000-0000-0000-0000-000000000002') = 2,
    '老婆的兩筆補入應該原封不動';
end;
$$;
rollback;

\echo '== topups: t08. 跨帳本引用一律擋（member_id 屬於別的帳本）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_other public.ledgers;
  v_blocked boolean := false;
  v_err text;
begin
  -- 另開一本帳（Mike 是唯一成員），拿它的 ledger_id 配種子帳本的 member_id。
  v_other := public.create_ledger('另一本帳');
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
    values (v_other.id, '20000000-0000-0000-0000-000000000001',
            100, current_date, '跨帳本', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能把別的帳本的成員寫進這本帳的補入';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== topups: t09. 已清帳月份鎖定：insert／update／delete 一律 month closed: YYYY-MM =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_blocked boolean;
  v_err text;
  v_id uuid;
begin
  -- 先把上月清掉（不記共同收入，這條測的是鎖月不是收入）。
  perform public.close_month('10000000-0000-0000-0000-000000000001', v_last, false);

  -- 應失敗①：補記一筆到已清月。
  v_blocked := false;
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            500, v_last + 3, '補記已清月', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然還能補記補入';
  -- 訊息與帳目／細項／預算完全同格式：`month closed: YYYY-MM`，帶的是被擋那筆所屬的月。
  assert v_err = format('month closed: %s', to_char(v_last, 'YYYY-MM')), format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：刪掉已清月的補入。
  select t.id into v_id from public.personal_topups t
  where t.member_id = '20000000-0000-0000-0000-000000000001' and t.month = v_last;
  assert v_id is not null, '前置條件不成立：Mike 上月應有補入';
  v_blocked := false;
  begin
    delete from public.personal_topups where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月的補入竟然刪得掉';
  assert v_err = format('month closed: %s', to_char(v_last, 'YYYY-MM')), format('錯誤訊息不對：%s', v_err);

  -- 對照組：本月（未清）照樣寫得進去。
  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, note, created_by)
  values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          500, date_trunc('month', current_date)::date + 2, '本月照樣可以',
          '20000000-0000-0000-0000-000000000001');
end;
$$;
rollback;

\echo '== topups: t10. 鎖月連 UPDATE 也擋（繞過欄位授權的路徑，例如 service_role）=='
begin;
do $$
declare
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_blocked boolean := false;
  v_err text;
  v_id uuid;
begin
  -- 這一段刻意用 postgres 身分跑：前端根本沒有 UPDATE 授權（t06 已驗），
  -- 但 service_role／人工救援會繞過授權層，鎖月 trigger 必須是最後一道。
  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text, true);
  perform public.close_month('10000000-0000-0000-0000-000000000001', v_last, false);

  select t.id into v_id from public.personal_topups t
  where t.member_id = '20000000-0000-0000-0000-000000000001' and t.month = v_last;
  begin
    update public.personal_topups set amount = 1 where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月的補入竟然被 UPDATE 改掉了';
  assert v_err = format('month closed: %s', to_char(v_last, 'YYYY-MM')), format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 把補入搬出鎖定範圍也要擋（trigger 同時看 OLD 與 NEW 的月）。
  v_blocked := false;
  begin
    update public.personal_topups set occurred_on = current_date where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能把已清月的補入搬到本月';
end;
$$;
rollback;

\echo '== topups: t11. 鎖月訊息與帳目／細項／預算完全同格式（同一支 raise_if_month_closed）=='
begin;
do $$
declare
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_expect text := format('month closed: %s', to_char(v_last, 'YYYY-MM'));
  v_cat uuid := '30000000-0000-0000-0000-000000000001';
  v_err text;
  v_got text[] := '{}';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text, true);
  perform public.close_month('10000000-0000-0000-0000-000000000001', v_last, false);

  -- 四張表各撞一次，訊息必須一字不差地相同——前端只要一條 startsWith('month closed:') 就對映得完。
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 1, v_cat, v_last + 1, 'x',
            '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
  exception when others then v_got := v_got || sqlerrm; end;

  begin
    insert into public.line_items (entry_id, name, amount, sort)
    values ('40000000-0000-0000-0000-000000000007', 'x', 1, 0);
  exception when others then v_got := v_got || sqlerrm; end;

  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000007', 1, v_last + 1,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_got := v_got || sqlerrm; end;

  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 1, v_last + 1,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_got := v_got || sqlerrm; end;

  assert array_length(v_got, 1) = 4, format('四張表都該被擋，實際只擋到 %s 張', coalesce(array_length(v_got, 1), 0));
  foreach v_err in array v_got loop
    assert v_err = v_expect, format('鎖月訊息不一致：%s（預期 %s）', v_err, v_expect);
  end loop;
  raise notice '  四張表的鎖月訊息一致：%', v_expect;
end;
$$;
rollback;

\echo 'topups.sql PASS'
