-- month_summary RPC 測試 — 20260903000200；語義對照 lib/domain/balance_math.dart。
-- fixture 一律開新帳本（不吃 seed 的既有收支），手算基準沿用 budget_page_test.dart：
--   期初共同 10,000；食品 撥5,000/花3,000、餐飲 撥1,000/花1,500
--   → shared_balance＝10,000−3,000−1,500−567(代墊)＝4,933、envelope_total 2,000、
--     overspend_total 500、shared_available 2,933。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'

\echo '== month_summary: m1. 共同餘額／信封／超支／可用餘額（手算基準）＋個人餘額 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_m uuid;
  v_cat1 uuid;
  v_cat2 uuid;
  v_sum jsonb;
  v_food jsonb;
  v_dining jsonb;
begin
  v_l := public.create_ledger('月摘要測試帳本');
  select id into v_m from public.members where ledger_id = v_l.id;
  select id into v_cat1 from public.categories
   where ledger_id = v_l.id and kind = 'expense' order by sort limit 1;
  select id into v_cat2 from public.categories
   where ledger_id = v_l.id and kind = 'expense' order by sort offset 1 limit 1;

  update public.ledgers set opening_balance_shared = 10000 where id = v_l.id;
  update public.members set opening_balance_personal = 50000 where id = v_m;

  -- 撥款：cat1 5,000、cat2 1,000。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by) values
    (v_l.id, v_cat1, 5000, date_trunc('month', current_date)::date, v_m),
    (v_l.id, v_cat2, 1000, date_trunc('month', current_date)::date, v_m);

  -- 預算支出（共同錢包、funding=budget）：cat1 3,000、cat2 1,500。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, created_by, split_method, funding) values
    (v_l.id, 'expense', 'shared', 3000, v_cat1, current_date, v_m, 'common', 'budget'),
    (v_l.id, 'expense', 'shared', 1500, v_cat2, current_date, v_m, 'common', 'budget');

  -- 個人側：私人收入 8,000、私人支出 350、代墊共同支出 567（全額扣個人、不動共同）。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, created_by, payer_id, split_method) values
    (v_l.id, 'income',  'private', 8000, v_cat1, current_date, v_m, v_m, 'common'),
    (v_l.id, 'expense', 'private',  350, v_cat1, current_date, v_m, v_m, 'common'),
    (v_l.id, 'expense', 'shared',   567, v_cat1, current_date, v_m, v_m, 'equal');

  v_sum := public.month_summary(v_l.id,
             (date_trunc('month', current_date) + interval '1 month - 1 day')::date);

  assert (v_sum->>'shared_balance')::int = 10000 - 3000 - 1500,
    format('shared_balance 不對（代墊 567 不該扣共同）：%s', v_sum->>'shared_balance');
  assert (v_sum->>'envelope_total')::int = 2000, format('envelope_total 不對：%s', v_sum->>'envelope_total');
  assert (v_sum->>'overspend_total')::int = 500, format('overspend_total 不對：%s', v_sum->>'overspend_total');
  assert (v_sum->>'shared_available')::int = 5500 - 2000,
    format('shared_available 不對：%s', v_sum->>'shared_available');

  select c into v_food from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = v_cat1;
  assert (v_food->>'allocated')::int = 5000 and (v_food->>'spent')::int = 3000
     and (v_food->>'remaining')::int = 2000 and (v_food->>'over')::int = 0,
    format('cat1 信封列不對：%s', v_food);

  select c into v_dining from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = v_cat2;
  assert (v_dining->>'allocated')::int = 1000 and (v_dining->>'spent')::int = 1500
     and (v_dining->>'remaining')::int = 0 and (v_dining->>'over')::int = 500,
    format('cat2 信封列不對：%s', v_dining);

  -- 個人餘額：期初 50,000 ＋ 8,000 − 350 − 567（代墊全額）＝ 57,083；只回呼叫者自己。
  assert (v_sum->'me'->>'member_id')::uuid = v_m, format('me.member_id 不對：%s', v_sum->'me');
  assert (v_sum->'me'->>'personal_balance')::int = 50000 + 8000 - 350 - 567,
    format('personal_balance 不對：%s', v_sum->'me'->>'personal_balance');
end;
$$;
rollback;

\echo '== month_summary: m2. security invoker——非成員呼叫看不到任何數字 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
-- Mike 另開一本帳（老婆不是成員）。
do $$
declare
  v_l public.ledgers;
begin
  v_l := public.create_ledger('Mike 一個人的帳');
  perform set_config('app.other_ledger', v_l.id::text, true);
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_sum jsonb;
begin
  v_sum := public.month_summary(current_setting('app.other_ledger')::uuid, current_date);
  -- RLS 濾掉一切：期初讀不到（null）、信封空、me 為 null——不外洩任何數字。
  assert v_sum->>'shared_balance' is null, format('非成員竟看得到 shared_balance：%s', v_sum);
  assert coalesce(jsonb_array_length(v_sum->'categories'), 0) = 0, format('非成員竟看得到信封列：%s', v_sum);
  assert (v_sum->'me') is null or v_sum->'me' = 'null'::jsonb, format('非成員竟有 me：%s', v_sum);
end;
$$;
rollback;

\echo 'month_summary 測試全部通過'
