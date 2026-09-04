-- month_summary RPC 測試 — 20260904000200_rules_v14.sql；語義對照 spec v1.4「餘額與預算」／ADR-0008。
-- fixture 一律開新帳本（不吃 seed 的既有收支）。手算基準：
--   期初共同 10,000；A 補入額 10,000、B 補入額 8,000（B 以 join_ledger 加入，本月加入）
--   cat1 預算 5,000／共同錢包花 3,000；cat2 預算 1,000／共同錢包花 1,500
--   cat3 沒設預算／A 代墊 1,000 均分（未結算）；共同收入 2,000；A 私人支出 300
--   → shared_balance ＝ 10,000 ＋ 2,000 − 3,000 − 1,500 ＝ 7,500（代墊不動共同）
--     budget_total 6,000；spent_total 5,500（已花含代墊，不分 payer）
--     overspend_total 1,500（cat2 超 500 ＋ cat3 超 1,000）
--     me.personal_balance ＝ 10,000 − 300 − 1,000 ＝ 8,700；month_net ＝ −1,300
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'

create function pg_temp.ms_claims(p_sub text) returns void
language plpgsql as $fx$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
end;
$fx$;

-- p_adv_cat：代墊那筆掛哪個分類（3 ＝ 沒設預算的 cat3，1 ＝ 有預算的 cat1）。
-- p_settle：是否把代墊結算簽完。
create function pg_temp.ms_fixture(p_adv_cat int default 3, p_settle boolean default false)
returns void
language plpgsql
as $fx$
declare
  v_l public.ledgers;
  v_a uuid;
  v_b uuid;
  v_cat1 uuid;
  v_cat2 uuid;
  v_cat3 uuid;
  v_inc uuid;
  v_adv uuid;
  v_month date := date_trunc('month', current_date)::date;
  v_s public.settlements;
begin
  perform pg_temp.ms_claims('11111111-1111-1111-1111-111111111111');
  v_l := public.create_ledger('月摘要測試帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;

  perform pg_temp.ms_claims('22222222-2222-2222-2222-222222222222');
  perform public.join_ledger(v_l.invite_code);
  select m.id into v_b from public.members m where m.ledger_id = v_l.id and m.id <> v_a;
  perform pg_temp.ms_claims('11111111-1111-1111-1111-111111111111');

  update public.ledgers set opening_balance_shared = 10000 where id = v_l.id;
  update public.members set monthly_topup = 10000 where id = v_a;
  update public.members set monthly_topup =  8000 where id = v_b;

  select c.id into v_cat1 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;
  select c.id into v_cat2 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort offset 1 limit 1;
  select c.id into v_cat3 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort offset 2 limit 1;
  select c.id into v_inc  from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'income' order by c.sort limit 1;

  -- 預算影子紀錄：每分類每月一筆、正數。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by) values
    (v_l.id, v_cat1, 5000, v_month, v_a),
    (v_l.id, v_cat2, 1000, v_month, v_a);

  -- 共同錢包支出（只動共同餘額）。
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, created_by, payer_id, split_method) values
    (v_l.id, 'expense', 'shared', 3000, v_cat1, current_date, v_a, null, 'common'),
    (v_l.id, 'expense', 'shared', 1500, v_cat2, current_date, v_a, null, 'common'),
    (v_l.id, 'income',  'shared', 2000, v_inc,  current_date, v_a, null, 'common');

  -- A 私人支出 300（只動 A 的個人餘額）。
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'private', 300, v_cat1, current_date, v_a, v_a, 'common');

  -- A 代墊 1,000 均分。
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'shared', 1000,
          case when p_adv_cat = 1 then v_cat1 else v_cat3 end,
          current_date, v_a, v_a, 'equal')
  returning id into v_adv;
  insert into public.entry_splits (entry_id, member_id, share) values (v_adv, v_a, 500), (v_adv, v_b, 500);

  if p_settle then
    v_s := public.initiate_settlement(v_l.id);
    perform pg_temp.ms_claims('22222222-2222-2222-2222-222222222222');
    perform public.approve_settlement(v_s.id);
    perform pg_temp.ms_claims('11111111-1111-1111-1111-111111111111');
  end if;

  perform set_config('app.ms_ledger', v_l.id::text, true);
  perform set_config('app.ms_a', v_a::text, true);
  perform set_config('app.ms_b', v_b::text, true);
  perform set_config('app.ms_cat1', v_cat1::text, true);
  perform set_config('app.ms_cat2', v_cat2::text, true);
  perform set_config('app.ms_cat3', v_cat3::text, true);
  perform set_config('app.ms_until', ((v_month + interval '1 month - 1 day')::date)::text, true);
end;
$fx$;

\echo '== month_summary: m1. 共同餘額／預算影子／個人餘額（v1.4 手算基準）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_a uuid := current_setting('app.ms_a')::uuid;
  v_cat1 uuid := current_setting('app.ms_cat1')::uuid;
  v_cat2 uuid := current_setting('app.ms_cat2')::uuid;
  v_cat3 uuid := current_setting('app.ms_cat3')::uuid;
  v_until date := current_setting('app.ms_until')::date;
  v_sum jsonb;
  v_c1 jsonb;
  v_c2 jsonb;
  v_c3 jsonb;
begin
  v_sum := public.month_summary(v_l, v_until);

  assert (v_sum->>'shared_balance')::int = 10000 + 2000 - 3000 - 1500,
    format('shared_balance 不對（代墊 1,000 不該扣共同）：%s', v_sum->>'shared_balance');
  assert (v_sum->>'budget_total')::int = 6000, format('budget_total 不對：%s', v_sum->>'budget_total');
  assert (v_sum->>'spent_total')::int = 5500,
    format('spent_total 不對（已花含代墊、不分 payer）：%s', v_sum->>'spent_total');
  assert (v_sum->>'overspend_total')::int = 1500,
    format('overspend_total 不對（cat2 超 500 ＋ cat3 超 1,000）：%s', v_sum->>'overspend_total');

  select c into v_c1 from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = v_cat1;
  assert (v_c1->>'allocated')::int = 5000 and (v_c1->>'spent')::int = 3000
     and (v_c1->>'remaining')::int = 2000 and (v_c1->>'over')::int = 0,
    format('cat1 預算列不對：%s', v_c1);

  select c into v_c2 from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = v_cat2;
  assert (v_c2->>'allocated')::int = 1000 and (v_c2->>'spent')::int = 1500
     and (v_c2->>'remaining')::int = 0 and (v_c2->>'over')::int = 500,
    format('cat2 預算列不對：%s', v_c2);

  -- 沒設預算但有共同支出的分類也要列出來（代墊那筆掛在這裡）。
  select c into v_c3 from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = v_cat3;
  assert (v_c3->>'allocated')::int = 0 and (v_c3->>'spent')::int = 1000
     and (v_c3->>'remaining')::int = 0 and (v_c3->>'over')::int = 1000,
    format('cat3 預算列不對：%s', v_c3);

  -- 個人：補入額 10,000 × 1 個未清帳月 − 私人 300 − 未結算代墊全額 1,000。
  assert (v_sum->'me'->>'member_id')::uuid = v_a, format('me.member_id 不對：%s', v_sum->'me');
  assert (v_sum->'me'->>'monthly_topup')::int = 10000, format('me.monthly_topup 不對：%s', v_sum->'me');
  assert (v_sum->'me'->>'personal_balance')::bigint = 10000 - 300 - 1000,
    format('personal_balance 不對：%s', v_sum->'me'->>'personal_balance');
  assert (v_sum->'me'->>'month_net')::bigint = -1300,
    format('month_net 不對：%s', v_sum->'me'->>'month_net');
end;
$$;
rollback;

\echo '== month_summary: m1b. 結算簽完後改為各自扣份額（付款人與對方各一條）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture(p_settle => true) as _fx \gset
set local role authenticated;
do $$
declare
  v_sum jsonb;
begin
  v_sum := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                current_setting('app.ms_until')::date);
  -- A：10,000 − 300（私人）− 500（自己的份額，不再是全額 1,000）
  assert (v_sum->'me'->>'personal_balance')::bigint = 10000 - 300 - 500,
    format('結算後 A 的 personal_balance 不對：%s', v_sum->'me'->>'personal_balance');
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_sum jsonb;
begin
  v_sum := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                current_setting('app.ms_until')::date);
  assert (v_sum->'me'->>'member_id')::uuid = current_setting('app.ms_b')::uuid,
    format('me 應是呼叫者 B：%s', v_sum->'me');
  -- B：8,000 − 500（自己的份額）；A 的私人支出不進 B 的餘額
  assert (v_sum->'me'->>'personal_balance')::bigint = 8000 - 500,
    format('結算後 B 的 personal_balance 不對：%s', v_sum->'me'->>'personal_balance');
end;
$$;
rollback;

\echo '== month_summary: m1c. 代墊也算進分類已花（掛 cat1 → cat1 已花 4,000）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture(p_adv_cat => 1) as _fx \gset
set local role authenticated;
do $$
declare
  v_sum jsonb;
  v_c1 jsonb;
begin
  v_sum := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                current_setting('app.ms_until')::date);
  select c into v_c1 from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = current_setting('app.ms_cat1')::uuid;
  assert (v_c1->>'spent')::int = 4000,
    format('cat1 已花應含代墊那筆（3,000 ＋ 1,000）：%s', v_c1);
  assert (v_c1->>'remaining')::int = 1000 and (v_c1->>'over')::int = 0,
    format('cat1 剩餘／超支不對：%s', v_c1);
  assert (v_sum->>'spent_total')::int = 5500, format('spent_total 不對：%s', v_sum->>'spent_total');
  assert (v_sum->>'overspend_total')::int = 500, format('overspend_total 不對：%s', v_sum->>'overspend_total');
end;
$$;
rollback;

\echo '== month_summary: m1d. v1.3 的 shared_available／envelope_total 兩個鍵已移除 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_sum jsonb;
begin
  v_sum := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                current_setting('app.ms_until')::date);
  assert not (v_sum ? 'shared_available'), format('shared_available 應該不存在：%s', v_sum);
  assert not (v_sum ? 'envelope_total'), format('envelope_total 應該不存在：%s', v_sum);
  assert v_sum ? 'budget_total' and v_sum ? 'spent_total', format('新鍵應該在：%s', v_sum);
end;
$$;
rollback;

\echo '== month_summary: m1e. allocated 不受 p_until 日期影響（預算是當月影子紀錄，整月生效）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_m uuid;
  v_cat uuid;
  v_month date := date_trunc('month', current_date)::date;
  v_sum jsonb;
  v_c jsonb;
begin
  v_l := public.create_ledger('預算日期測試帳本');
  select m.id into v_m from public.members m where m.ledger_id = v_l.id;
  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;

  -- 預算設在 20 號、共同支出記在 25 號，但只問到 10 號。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
  values (v_l.id, v_cat, 5000, v_month + 19, v_m);
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'shared', 1200, v_cat, v_month + 24, v_m, null, 'common');

  v_sum := public.month_summary(v_l.id, v_month + 9);
  select c into v_c from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = v_cat;

  -- 預算：整月生效，不因為問的日期早於設定日就消失。
  assert (v_c->>'allocated')::int = 5000,
    format('allocated 不該被 p_until 篩掉（預算是當月的影子紀錄）：%s', v_c);
  -- 已花：逐筆累加，25 號那筆還沒發生。
  assert (v_c->>'spent')::int = 0, format('spent 應該只算 occurred_on <= p_until 的：%s', v_c);
  assert (v_c->>'remaining')::int = 5000 and (v_c->>'over')::int = 0,
    format('剩餘／超支不對：%s', v_c);
  assert (v_sum->>'budget_total')::int = 5000 and (v_sum->>'spent_total')::int = 0,
    format('合計不對：%s', v_sum);
end;
$$;
rollback;

\echo '== month_summary: m1f. p_until 不夾上界（看得到下個月），只有補入額的月份列舉夾在本月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
-- 下個月先設好 cat1 的預算，並記一筆下個月的共同錢包支出。
-- 前端的月份切換沒有上界（下個月的預算本來就可以先設），所以問下個月必須拿到下個月的數字。
insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
values (current_setting('app.ms_ledger')::uuid, current_setting('app.ms_cat1')::uuid,
        7000, (date_trunc('month', current_date) + interval '1 month')::date, '下月 cat1',
        current_setting('app.ms_a')::uuid);
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values (current_setting('app.ms_ledger')::uuid, 'expense', 'shared', 2222,
        current_setting('app.ms_cat1')::uuid,
        (date_trunc('month', current_date) + interval '1 month')::date + 3,
        '下月共同錢包', current_setting('app.ms_a')::uuid, null, 'common');
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_cat1 uuid := current_setting('app.ms_cat1')::uuid;
  v_eom date := current_setting('app.ms_until')::date;
  v_next_eom date := (date_trunc('month', current_date) + interval '2 month - 1 day')::date;
  v_now jsonb;
  v_next jsonb;
  v_far jsonb;
  v_c jsonb;
begin
  -- ① 本月：原本的數字不能被下個月那兩筆影響（回歸防線）。
  v_now := public.month_summary(v_l, v_eom);
  select c into v_c from jsonb_array_elements(v_now->'categories') c
   where (c->>'category_id')::uuid = v_cat1;
  assert (v_c->>'allocated')::int = 5000 and (v_c->>'spent')::int = 3000,
    format('本月 cat1 不該被下個月的資料汙染：%s', v_c);
  assert (v_now->'me'->>'personal_balance')::bigint = 10000 - 300 - 1000,
    format('本月個人餘額：%s', v_now->'me'->>'personal_balance');

  -- ② 下個月：allocated／spent／categories／month_net 全都要照使用者問的那個月算。
  v_next := public.month_summary(v_l, v_next_eom);
  select c into v_c from jsonb_array_elements(v_next->'categories') c
   where (c->>'category_id')::uuid = v_cat1;
  assert (v_c->>'allocated')::int = 7000,
    format('問下個月就該拿到下個月的預算 7,000（拿到本月的 5,000 ＝ 夾擠套錯範圍）：%s', v_c);
  assert (v_c->>'spent')::int = 2222 and (v_c->>'remaining')::int = 4778 and (v_c->>'over')::int = 0,
    format('下個月的已花／剩餘不對：%s', v_c);
  assert (v_next->>'budget_total')::int = 7000 and (v_next->>'spent_total')::int = 2222,
    format('下個月的合計不對：%s', v_next);
  -- 共同餘額是累計值，會含下個月那筆共同錢包支出。
  assert (v_next->>'shared_balance')::int = 10000 + 2000 - 3000 - 1500 - 2222,
    format('下個月的共同餘額不對：%s', v_next->>'shared_balance');
  -- 關鍵：補入額**不會**因為問了下個月就多算一個月（下個月的錢還沒補進來）。
  assert (v_next->'me'->>'personal_balance')::bigint = 10000 - 300 - 1000,
    format('問下個月不該多算一個月的補入額：%s', v_next->'me'->>'personal_balance');
  assert (v_next->'me'->>'month_net')::bigint = 0,
    format('下個月沒有影響個人餘額的帳目，month_net 應為 0：%s', v_next->'me');

  -- ③ 很遠的未來：月份列舉仍夾在本月（N ＝ 1），不是九萬個月的補入額。
  v_far := public.month_summary(v_l, date '9999-12-31');
  assert (v_far->'me'->>'personal_balance')::bigint = 10000 - 300 - 1000,
    format('p_until 給極遠未來時 N 仍應只算到本月：%s', v_far->'me'->>'personal_balance');
  -- 9999-12 那個月沒有預算也沒有支出，所以分類列是空的。
  assert coalesce(jsonb_array_length(v_far->'categories'), 0) = 0,
    format('9999-12 不該有分類列：%s', v_far->'categories');
  assert (v_far->>'budget_total')::int = 0 and (v_far->>'spent_total')::int = 0,
    format('9999-12 的合計應為 0：%s', v_far);
  -- 共同餘額是累計到 p_until，所以與問下個月相同。
  assert (v_far->>'shared_balance')::int = (v_next->>'shared_balance')::int,
    format('共同餘額應累計到 p_until：%s vs %s', v_far->>'shared_balance', v_next->>'shared_balance');
end;
$$;
rollback;

\echo '== month_summary: m1g. 共同支出加總越過 int 上界時，仍要算得出來 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
-- 單筆 amount 是 int（上限約 21.4 億），但同一個月同一個分類加起來輕鬆越過。
-- 兩筆 11 億的共同錢包支出：合計 22 億 > 2,147,483,647。
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values
  (current_setting('app.ms_ledger')::uuid, 'expense', 'shared', 1100000000,
   current_setting('app.ms_cat2')::uuid, current_date, '大額一',
   current_setting('app.ms_a')::uuid, null, 'common'),
  (current_setting('app.ms_ledger')::uuid, 'expense', 'shared', 1100000000,
   current_setting('app.ms_cat2')::uuid, current_date, '大額二',
   current_setting('app.ms_a')::uuid, null, 'common');
set local role authenticated;
do $$
declare
  v_sum jsonb;
  v_c2 jsonb;
begin
  -- 改回 sum(amount)::int 這段會是 integer out of range。
  v_sum := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                current_setting('app.ms_until')::date);
  select c into v_c2 from jsonb_array_elements(v_sum->'categories') c
   where (c->>'category_id')::uuid = current_setting('app.ms_cat2')::uuid;

  -- cat2 原本花 1,500、預算 1,000，再加兩筆 11 億。
  assert (v_c2->>'spent')::bigint = 1500 + 2200000000,
    format('cat2 已花應為 2,200,001,500：%s', v_c2->>'spent');
  assert (v_c2->>'over')::bigint = 1500 + 2200000000 - 1000,
    format('cat2 超支應為 2,200,000,500（上界是 spent 而不是 allocated）：%s', v_c2->>'over');
  assert (v_c2->>'allocated')::int = 1000, format('allocated 仍是單筆預算：%s', v_c2);

  assert (v_sum->>'spent_total')::bigint = 3000 + 1000 + 1500 + 2200000000,
    format('spent_total 不對：%s', v_sum->>'spent_total');
  assert (v_sum->>'overspend_total')::bigint = 1000 + 1500 + 2200000000 - 1000,
    format('overspend_total 不對：%s', v_sum->>'overspend_total');
  -- 共同餘額同樣是累計值。
  assert (v_sum->>'shared_balance')::bigint = 10000 + 2000 - 3000 - 1500 - 2200000000,
    format('shared_balance 不對：%s', v_sum->>'shared_balance');
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
  -- RLS 濾掉一切：期初讀不到（null）、分類空、me 為 null——不外洩任何數字。
  assert v_sum->>'shared_balance' is null, format('非成員竟看得到 shared_balance：%s', v_sum);
  assert coalesce(jsonb_array_length(v_sum->'categories'), 0) = 0, format('非成員竟看得到分類列：%s', v_sum);
  assert (v_sum->'me') is null or v_sum->'me' = 'null'::jsonb, format('非成員竟有 me：%s', v_sum);
end;
$$;
rollback;

\echo 'month_summary 測試全部通過'
