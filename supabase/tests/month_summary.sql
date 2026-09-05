-- month_summary RPC 測試 — 20260905000100_rules_v15.sql；語義對照 spec v1.5「餘額、補入與預算」／ADR-0009。
-- fixture 一律開新帳本（不吃 seed 的既有收支）。手算基準：
--   A（Mike）補入 10,000；B（老婆）補入 8,000（以 join_ledger 加入）
--   共同收入 8,000；共同錢包付 cat1 3,000 ＋ cat2 1,500
--   A 先付 cat1 1,000 ＋ cat3 200；B 先付 cat1 500
--   預算 cat1 5,000、cat2 1,000（cat3 沒設）
--   → shared_balance ＝ 8,000 − 3,000 − 1,500 ＝ 3,500（**無期初**；成員先付不動它）
--     spent_total ＝ 6,200（全部支出，不分誰付）；budget_total ＝ 6,000
--     cat1 spent 4,500（三種付款來源都有）；cat2 over 500；cat3 over 200 → overspend_total 700
--     members：A {10000, 1200, 8800}、B {8000, 500, 7500}；shared_paid ＝ 4,500
--   （members 與 shared_paid 取 p_until 所在**整月**，不夾當日；其餘維持 occurred_on <= until）
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'

create function pg_temp.ms_claims(p_sub text) returns void
language plpgsql as $fx$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
end;
$fx$;

-- p_adjust：是否補一筆沖銷（is_adjustment、負金額）把 A 在 cat1 先付的 1,000 整筆回退。
create function pg_temp.ms_fixture(p_adjust boolean default false)
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
  v_month date := date_trunc('month', current_date)::date;
begin
  perform pg_temp.ms_claims('11111111-1111-1111-1111-111111111111');
  v_l := public.create_ledger('月摘要測試帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;

  perform pg_temp.ms_claims('22222222-2222-2222-2222-222222222222');
  perform public.join_ledger(v_l.invite_code);
  select m.id into v_b from public.members m where m.ledger_id = v_l.id and m.id <> v_a;
  perform pg_temp.ms_claims('11111111-1111-1111-1111-111111111111');

  -- 兩位成員是在同一個交易裡建的，joined_at 的 now() 完全相同，
  -- 排序（joined_at, id）就會由隨機的 uuid 決定 → 斷言時而紅時而綠。
  -- 這裡把加入時刻明確錯開（仍落在本月，不影響任何月份判準）。
  update public.members set joined_at = date_trunc('month', now()) + interval '1 hour' where id = v_a;
  update public.members set joined_at = date_trunc('month', now()) + interval '2 hour' where id = v_b;

  select c.id into v_cat1 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;
  select c.id into v_cat2 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort offset 1 limit 1;
  select c.id into v_cat3 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort offset 2 limit 1;
  select c.id into v_inc  from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'income' order by c.sort limit 1;

  -- 個人補入（v1.5：手動、一列一筆）。
  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by) values
    (v_l.id, v_a, 10000, v_month, v_a),
    (v_l.id, v_b,  8000, v_month, v_b);

  -- 預算影子紀錄：每分類每月一筆、正數。
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by) values
    (v_l.id, v_cat1, 5000, v_month, v_a),
    (v_l.id, v_cat2, 1000, v_month, v_a);

  insert into public.entries
    (ledger_id, kind, amount, category_id, occurred_on, created_by, payer_id) values
    -- 共同收入（payer 恆 null）
    (v_l.id, 'income',  8000, v_inc,  current_date, v_a, null),
    -- 共同錢包付（只扣共同餘額）
    (v_l.id, 'expense', 3000, v_cat1, current_date, v_a, null),
    (v_l.id, 'expense', 1500, v_cat2, current_date, v_a, null),
    -- 成員先付（只扣該成員該月補入剩餘）
    (v_l.id, 'expense', 1000, v_cat1, current_date, v_a, v_a),
    (v_l.id, 'expense',  200, v_cat3, current_date, v_a, v_a),
    (v_l.id, 'expense',  500, v_cat1, current_date, v_b, v_b);

  if p_adjust then
    -- 沖銷＝金額取負的反向紀錄，付款人／日期照抄原筆（spec「沖銷」）。
    insert into public.entries
      (ledger_id, kind, amount, category_id, occurred_on, created_by, payer_id, is_adjustment)
    values (v_l.id, 'expense', -1000, v_cat1, current_date, v_a, v_a, true);
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

\echo '== month_summary: m0. 種子資料的三個數（spec 驗收總表那一組）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  -- 這一段刻意直接吃 seed（不開新帳本）：spec「驗收總表／三個數」列的就是這組數字，
  -- 種子形狀一改就要在這裡紅。Mike 的 6,000 是**淨額**（原筆 7,000 ＋ 沖銷 −1,000），
  -- 所以它同時守住「先付要算進沖銷的負數筆」這條。
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_s jsonb := public.month_summary(v_l, null);
  v_m jsonb;
begin
  assert (v_s ->> 'shared_balance')::bigint = 17000,
    format('共同餘額應為 17000（20000 收入 − 3000 共同錢包），實際 %s', v_s ->> 'shared_balance');
  assert (v_s ->> 'spent_total')::bigint = 11000,
    format('本月支出合計應為 11000（3000 ＋ 7000 − 1000 ＋ 1200 ＋ 800），實際 %s', v_s ->> 'spent_total');
  assert (v_s ->> 'shared_paid')::bigint = 3000,
    format('共同錢包支出應為 3000，實際 %s', v_s ->> 'shared_paid');

  select x into v_m from jsonb_array_elements(v_s -> 'members') x
   where (x ->> 'member_id')::uuid = '20000000-0000-0000-0000-000000000001'::uuid;
  assert (v_m ->> 'topup')::bigint = 10000 and (v_m ->> 'paid')::bigint = 6000
     and (v_m ->> 'remaining')::bigint = 4000,
    format('Mike 應為 {10000, 6000, 4000}（先付是原筆 7000 減沖銷 1000 的淨額），實際 %s', v_m);

  select x into v_m from jsonb_array_elements(v_s -> 'members') x
   where (x ->> 'member_id')::uuid = '20000000-0000-0000-0000-000000000002'::uuid;
  assert (v_m ->> 'topup')::bigint = 10000 and (v_m ->> 'paid')::bigint = 2000
     and (v_m ->> 'remaining')::bigint = 8000,
    format('老婆應為 {10000, 2000, 8000}，實際 %s', v_m);

  -- 分類已花含三種付款來源：食品 ＝ 共同錢包 3000 ＋ Mike 淨 6000 ＋ 老婆 1200 ＝ 10200。
  select x into v_m from jsonb_array_elements(v_s -> 'categories') x
   where (x ->> 'category_id')::uuid = '30000000-0000-0000-0000-000000000001'::uuid;
  assert (v_m ->> 'spent')::bigint = 10200,
    format('食品已花應含共同錢包／Mike 先付／老婆 先付三種來源，實際 %s', v_m);
end;
$$;
rollback;

\echo '== month_summary: m1. 三個數（v1.5 手算基準）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_a uuid := current_setting('app.ms_a')::uuid;
  v_b uuid := current_setting('app.ms_b')::uuid;
  v_cat1 uuid := current_setting('app.ms_cat1')::uuid;
  v_cat2 uuid := current_setting('app.ms_cat2')::uuid;
  v_cat3 uuid := current_setting('app.ms_cat3')::uuid;
  v_until date := current_setting('app.ms_until')::date;
  v_s jsonb;
  v_m jsonb;
begin
  v_s := public.month_summary(v_l, v_until);

  -- 數 1：共同餘額 ＝ Σ共同收入 − Σ共同錢包支出。無期初，成員先付一律不動它。
  assert (v_s ->> 'shared_balance')::bigint = 3500,
    format('shared_balance 應為 3500，實際 %s', v_s ->> 'shared_balance');
  assert (v_s ->> 'shared_paid')::bigint = 4500,
    format('shared_paid 應為 4500，實際 %s', v_s ->> 'shared_paid');

  -- 數 3：分類預算影子（已花不分誰付）。
  assert (v_s ->> 'budget_total')::bigint = 6000, format('budget_total 不對：%s', v_s ->> 'budget_total');
  assert (v_s ->> 'spent_total')::bigint = 6200, format('spent_total 不對：%s', v_s ->> 'spent_total');
  assert (v_s ->> 'overspend_total')::bigint = 700, format('overspend_total 不對：%s', v_s ->> 'overspend_total');

  select x into v_m from jsonb_array_elements(v_s -> 'categories') x
   where (x ->> 'category_id')::uuid = v_cat1;
  assert (v_m ->> 'allocated')::bigint = 5000 and (v_m ->> 'spent')::bigint = 4500
     and (v_m ->> 'remaining')::bigint = 500 and (v_m ->> 'over')::bigint = 0,
    format('cat1 不對（應含共同錢包 3000 ＋ A 先付 1000 ＋ B 先付 500）：%s', v_m);

  select x into v_m from jsonb_array_elements(v_s -> 'categories') x
   where (x ->> 'category_id')::uuid = v_cat2;
  assert (v_m ->> 'spent')::bigint = 1500 and (v_m ->> 'over')::bigint = 500,
    format('cat2 不對：%s', v_m);

  select x into v_m from jsonb_array_elements(v_s -> 'categories') x
   where (x ->> 'category_id')::uuid = v_cat3;
  assert (v_m ->> 'allocated')::bigint = 0 and (v_m ->> 'spent')::bigint = 200
     and (v_m ->> 'over')::bigint = 200,
    format('cat3（沒設預算但有花）不對：%s', v_m);

  -- 數 2：個人補入剩餘（每人每月）。members 是全體成員，依 joined_at, id 排序。
  assert jsonb_array_length(v_s -> 'members') = 2, 'members 應該有兩位';
  v_m := (v_s -> 'members') -> 0;
  assert (v_m ->> 'member_id')::uuid = v_a, 'members 第一位應是先加入的 A';
  assert (v_m ->> 'display_name') = 'Mike', format('display_name 不對：%s', v_m ->> 'display_name');
  assert (v_m ->> 'topup')::bigint = 10000 and (v_m ->> 'paid')::bigint = 1200
     and (v_m ->> 'remaining')::bigint = 8800,
    format('A 的補入／先付／剩餘不對：%s', v_m);

  v_m := (v_s -> 'members') -> 1;
  assert (v_m ->> 'member_id')::uuid = v_b, 'members 第二位應是後加入的 B';
  assert (v_m ->> 'topup')::bigint = 8000 and (v_m ->> 'paid')::bigint = 500
     and (v_m ->> 'remaining')::bigint = 7500,
    format('B 的補入／先付／剩餘不對：%s', v_m);
end;
$$;
rollback;

\echo '== month_summary: m2. v1.4 的 me 鍵已移除，改為 members ＋ shared_paid =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_s jsonb := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                    current_setting('app.ms_until')::date);
  v_keys text;
begin
  select string_agg(k, ', ' order by k) into v_keys from jsonb_object_keys(v_s) k;
  assert v_keys = 'budget_total, categories, members, overspend_total, shared_balance, shared_paid, spent_total',
    format('month_summary 的鍵不對：%s', v_keys);
  assert not (v_s ? 'me'), 'v1.4 的 me 鍵應該已經移除';
  -- 每位成員三個數字都在。
  assert (select bool_and(m ? 'topup' and m ? 'paid' and m ? 'remaining' and m ? 'display_name')
          from jsonb_array_elements(v_s -> 'members') m),
    'members 每一列都要有 display_name／topup／paid／remaining';
end;
$$;
rollback;

\echo '== month_summary: m3. 沖銷筆整筆回退先付（負金額走同一條公式）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture(true) as _fx \gset
set local role authenticated;
do $$
declare
  v_s jsonb := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                    current_setting('app.ms_until')::date);
  v_a uuid := current_setting('app.ms_a')::uuid;
  v_cat1 uuid := current_setting('app.ms_cat1')::uuid;
  v_m jsonb;
begin
  -- A 先付 1,000 被沖掉 → paid 1,200 − 1,000 ＝ 200，剩餘回到 9,800。
  select x into v_m from jsonb_array_elements(v_s -> 'members') x where (x ->> 'member_id')::uuid = v_a;
  assert (v_m ->> 'paid')::bigint = 200 and (v_m ->> 'remaining')::bigint = 9800,
    format('沖銷後 A 的先付／剩餘不對：%s', v_m);

  -- 分類預算也沿原路整筆回退。
  select x into v_m from jsonb_array_elements(v_s -> 'categories') x
   where (x ->> 'category_id')::uuid = v_cat1;
  assert (v_m ->> 'spent')::bigint = 3500, format('沖銷後 cat1 已花不對：%s', v_m);
  assert (v_s ->> 'spent_total')::bigint = 5200, format('沖銷後 spent_total 不對：%s', v_s ->> 'spent_total');

  -- 沖銷的是成員先付的筆，共同餘額一分錢都不該動。
  assert (v_s ->> 'shared_balance')::bigint = 3500,
    format('沖銷成員先付的筆不該動共同餘額：%s', v_s ->> 'shared_balance');
end;
$$;
rollback;

\echo '== month_summary: m4. 補入剩餘可為負（先付超過補入時不夾 0）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_b uuid := current_setting('app.ms_b')::uuid;
  v_cat1 uuid := current_setting('app.ms_cat1')::uuid;
  v_s jsonb;
  v_m jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'role', 'authenticated')::text, true);
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, created_by, payer_id)
  values (v_l, 'expense', 20000, v_cat1, current_date, v_b, v_b);

  v_s := public.month_summary(v_l, current_setting('app.ms_until')::date);
  select x into v_m from jsonb_array_elements(v_s -> 'members') x where (x ->> 'member_id')::uuid = v_b;
  -- B 補入 8,000、先付 500 ＋ 20,000 → 剩餘 −12,500。
  assert (v_m ->> 'paid')::bigint = 20500 and (v_m ->> 'remaining')::bigint = -12500,
    format('B 的補入剩餘應為 −12500（可為負），實際：%s', v_m);
end;
$$;
rollback;

\echo '== month_summary: m5. 兩種口徑：categories／spent 夾 p_until，members／shared_paid 取整月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_a uuid := current_setting('app.ms_a')::uuid;
  v_month date := date_trunc('month', current_date)::date;
  v_s jsonb;
  v_m jsonb;
begin
  -- 問「月初那一天」。fixture 的支出與補入都記在 current_date。
  v_s := public.month_summary(v_l, v_month);

  -- 預算是當月影子紀錄，設定當下就整月生效 → allocated 不該被 p_until 夾掉。
  assert (v_s ->> 'budget_total')::bigint = 6000,
    format('allocated 不該被 p_until 夾掉：%s', v_s ->> 'budget_total');

  -- categories／spent_total 是逐筆累加的實際花費 → 受 occurred_on <= until 限制。
  if current_date > v_month then
    assert (v_s ->> 'spent_total')::bigint = 0,
      format('spent 應該受 occurred_on <= until 限制：%s', v_s ->> 'spent_total');
  end if;

  -- **members 與 shared_paid 取 until 所在整月，不夾當日**（spec 口徑是「每人每月」）：
  -- 月中查詢時，補入剩餘不該把「這個月稍晚才發生的先付」切掉——那會讓預算頁的剩餘虛高，
  -- 也會與 month_closes.details 的快照對不起來。
  assert (v_s ->> 'shared_paid')::bigint = 4500,
    format('shared_paid 應取整月（4500），實際 %s', v_s ->> 'shared_paid');
  select x into v_m from jsonb_array_elements(v_s -> 'members') x where (x ->> 'member_id')::uuid = v_a;
  assert (v_m ->> 'topup')::bigint = 10000 and (v_m ->> 'paid')::bigint = 1200
     and (v_m ->> 'remaining')::bigint = 8800,
    format('members 應取整月、不受 p_until 當日影響：%s', v_m);

  -- 交叉驗證：問月初與問月底，members 與 shared_paid 完全一樣（categories 則不一樣）。
  assert (v_s -> 'members') = (public.month_summary(v_l, current_setting('app.ms_until')::date) -> 'members'),
    '同一個月裡不管問哪一天，members 都該相同';
  assert (v_s ->> 'shared_paid') = (public.month_summary(v_l, current_setting('app.ms_until')::date) ->> 'shared_paid'),
    '同一個月裡不管問哪一天，shared_paid 都該相同';
end;
$$;
rollback;

\echo '== month_summary: m6. p_until 不夾上界——問下個月拿得到下個月的數 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_next date := (date_trunc('month', current_date) + interval '2 month - 1 day')::date;
  v_s jsonb := public.month_summary(v_l, v_next);
  v_m jsonb;
begin
  -- 下個月：預算與支出都還沒有 → 全 0；但共同餘額是「累計到 until」，仍是 3,500。
  assert (v_s ->> 'budget_total')::bigint = 0, format('下個月不該有預算：%s', v_s ->> 'budget_total');
  assert (v_s ->> 'spent_total')::bigint = 0, format('下個月不該有支出：%s', v_s ->> 'spent_total');
  assert (v_s ->> 'shared_balance')::bigint = 3500,
    format('共同餘額是累計值，看下個月仍應是 3500：%s', v_s ->> 'shared_balance');
  -- 成員列仍在（全體成員都要有一列），數字是 0。
  assert jsonb_array_length(v_s -> 'members') = 2, '下個月仍應列出全體成員';
  select x into v_m from jsonb_array_elements(v_s -> 'members') x limit 1;
  assert (v_m ->> 'topup')::bigint = 0 and (v_m ->> 'paid')::bigint = 0,
    format('下個月的補入／先付應為 0：%s', v_m);
end;
$$;
rollback;

\echo '== month_summary: m7. p_until 為 null ＝ 本月底 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
begin
  assert public.month_summary(v_l, null) = public.month_summary(v_l, current_setting('app.ms_until')::date),
    'p_until 給 null 應該等於問到本月底';
end;
$$;
rollback;

\echo '== month_summary: m8. 加總越過 int 上界時仍要算得出來（bigint）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.ms_ledger')::uuid;
  v_a uuid := current_setting('app.ms_a')::uuid;
  v_cat1 uuid := current_setting('app.ms_cat1')::uuid;
  v_s jsonb;
  v_m jsonb;
begin
  -- 單筆 amount 是 int，但一個月加起來輕鬆越過 int 上界（2,147,483,647）。
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, created_by, payer_id) values
    (v_l, 'expense', 2000000000, v_cat1, current_date, v_a, null),
    (v_l, 'expense', 2000000000, v_cat1, current_date, v_a, null);
  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by) values
    (v_l, v_a, 2000000000, current_date, v_a),
    (v_l, v_a, 2000000000, current_date, v_a);

  v_s := public.month_summary(v_l, current_setting('app.ms_until')::date);
  assert (v_s ->> 'spent_total')::bigint = 4000006200,
    format('spent_total 應為 4000006200（bigint），實際 %s', v_s ->> 'spent_total');
  assert (v_s ->> 'shared_balance')::bigint = -3999996500,
    format('shared_balance 應為 −3999996500，實際 %s', v_s ->> 'shared_balance');
  select x into v_m from jsonb_array_elements(v_s -> 'members') x where (x ->> 'member_id')::uuid = v_a;
  assert (v_m ->> 'topup')::bigint = 4000010000, format('topup 應為 4000010000：%s', v_m);
end;
$$;
rollback;

\echo '== month_summary: m9. security invoker——非成員呼叫看不到任何數字 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.ms_fixture() as _fx \gset
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims2 \gset
set local role authenticated;
do $$
declare
  v_s jsonb := public.month_summary(current_setting('app.ms_ledger')::uuid,
                                    current_setting('app.ms_until')::date);
begin
  assert (v_s ->> 'shared_balance')::bigint = 0, format('非成員竟然看得到共同餘額：%s', v_s);
  assert (v_s ->> 'spent_total')::bigint = 0, '非成員竟然看得到支出';
  assert (v_s ->> 'shared_paid')::bigint = 0, '非成員竟然看得到共同錢包支出';
  assert v_s -> 'categories' = '[]'::jsonb, '非成員竟然看得到分類';
  assert v_s -> 'members' = '[]'::jsonb, '非成員竟然看得到成員';
end;
$$;
rollback;

\echo 'month_summary 測試全部通過'
