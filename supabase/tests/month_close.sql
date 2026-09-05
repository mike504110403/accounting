-- 清帳（月結）測試 — 20260905000100_rules_v15.sql；語義對照 spec v1.5「清帳」／ADR-0009 決策 4。
--
-- 種子的形狀（見 supabase/seed.sql）：
--   成員 joined_at ＝ 上月月初；上月有帳目與補入，本月也有 → **首次可清月＝上月**。
--   上月：Mike 補入 3,000 先付 1,200；老婆 補入 2,000 先付 800；**沒有**收入也沒有共同錢包支出
--   （共同餘額是累計水位，上月放了就會破壞本月底的 17,000）。
--   → ending 1,800／1,200，income_amount ＝ 3,000，shared_paid ＝ 0。
--
-- 注意：psql 不會在 dollar-quoted 區塊內代換 :'VAR'，所以 DO 區塊裡的 UUID 一律寫死。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set LEDGER '10000000-0000-0000-0000-000000000001'

create function pg_temp.mc_claims(p_sub text) returns void
language plpgsql as $fx$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
end;
$fx$;

\echo '== month_close: c01. 可清條件的五條訊息（順序由上而下）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_cur date := (date_trunc('month', current_date))::date;
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_err text;
  v_blocked boolean;
begin
  -- ① 非月初。
  v_blocked := false;
  begin perform public.month_close_preview(v_l, v_last + 5);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = 'close_month: month must be first day', format('①訊息不對：%s', v_err);

  -- ② 當月尚未結束（台北時間）。
  v_blocked := false;
  begin perform public.month_close_preview(v_l, v_cur);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = 'close_month: month not ended', format('②訊息不對：%s', v_err);

  -- ⑤ 跳月：上上月不是「下一個可清月」。
  v_blocked := false;
  begin perform public.month_close_preview(v_l, (v_cur - interval '2 month')::date);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = format('close_month: must close %s first', to_char(v_last, 'YYYY-MM')),
    format('⑤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 上月是可清的（對照組）。
  perform public.month_close_preview(v_l, v_last);

  -- ③ 已清過（清完再清同一個月）。
  perform public.close_month(v_l, v_last, false);
  v_blocked := false;
  begin perform public.month_close_preview(v_l, v_last);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = 'close_month: already closed', format('③訊息不對：%s', v_err);

  -- 上月清完之後，下一個可清月是本月，而本月還沒結束（④ nothing to close 見 c02）。
  v_blocked := false;
  begin perform public.month_close_preview(v_l, v_cur);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = 'close_month: month not ended',
    format('清完上月後問本月，應先被「月份尚未結束」擋下：%s', v_err);
end;
$$;
rollback;

\echo '== month_close: c02. 沒有帳目也沒有補入的新帳本 → nothing to close =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_err text;
  v_blocked boolean := false;
begin
  -- 剛建的帳本：加入月＝本月，最早帳目／補入都沒有 → 下一個可清月 ≥ 本月。
  v_l := public.create_ledger('全新帳本');
  begin
    perform public.month_close_preview(v_l.id, (date_trunc('month', current_date) - interval '1 month')::date);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = 'close_month: nothing to close', format('訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== month_close: c03. 非成員不能預覽也不能清（42501）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_err text;
  v_state text;
  v_blocked boolean := false;
begin
  begin perform public.month_close_preview(v_l, v_last);
  exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate; end;
  assert v_blocked and v_err = 'month_close_preview: not a member' and v_state = '42501',
    format('preview 的非成員訊息不對：%s (%s)', v_err, v_state);
  raise notice '  預期的失敗：% (%)', v_err, v_state;

  v_blocked := false;
  begin perform public.close_month(v_l, v_last, true);
  exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate; end;
  assert v_blocked and v_err = 'close_month: not a member' and v_state = '42501',
    format('close_month 的非成員訊息不對：%s (%s)', v_err, v_state);
end;
$$;
rollback;

\echo '== month_close: c04. 預覽的形狀與數字（沒有 warnings 鍵，有 income_amount）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_p jsonb := public.month_close_preview(v_l, v_last);
  v_keys text;
  v_m jsonb;
begin
  select string_agg(k, ', ' order by k) into v_keys from jsonb_object_keys(v_p) k;
  assert v_keys = 'income_amount, members, month, shared_paid',
    format('preview 的鍵不對：%s', v_keys);
  assert not (v_p ? 'warnings'), 'v1.4 的 warnings 鍵應隨分攤一起消失';

  assert (v_p ->> 'month') = to_char(v_last, 'YYYY-MM-DD'), format('month 不對：%s', v_p ->> 'month');
  assert (v_p ->> 'shared_paid')::bigint = 0, format('shared_paid 應為 0（上月沒有共同錢包支出）：%s', v_p ->> 'shared_paid');
  assert (v_p ->> 'income_amount')::bigint = 3000, format('income_amount 應為 3000：%s', v_p ->> 'income_amount');

  assert jsonb_array_length(v_p -> 'members') = 2, 'members 應有兩位';
  v_m := (v_p -> 'members') -> 0;
  assert (v_m ->> 'member_id')::uuid = '20000000-0000-0000-0000-000000000001'::uuid,
    'members 應依 joined_at, id 排序，第一位是 Mike';
  assert (v_m ->> 'display_name') = 'Mike' and (v_m ->> 'topup')::bigint = 3000
     and (v_m ->> 'paid')::bigint = 1200 and (v_m ->> 'ending')::bigint = 1800,
    format('Mike 的明細不對：%s', v_m);
  v_m := (v_p -> 'members') -> 1;
  assert (v_m ->> 'topup')::bigint = 2000 and (v_m ->> 'paid')::bigint = 800
     and (v_m ->> 'ending')::bigint = 1200,
    format('老婆的明細不對：%s', v_m);
end;
$$;
rollback;

\echo '== month_close: c05. close_month(p_record_income => true)：一鍵記共同收入 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_p jsonb;
  v_row public.month_closes;
  v_e public.entries;
  v_cat public.categories;
begin
  v_p := public.month_close_preview(v_l, v_last);
  v_row := public.close_month(v_l, v_last, true);

  -- month_closes 恰好一列，且是這個月。
  assert (select count(*) from public.month_closes mc where mc.ledger_id = v_l) = 1,
    'month_closes 應該恰好一列';
  assert v_row.month = v_last, format('清帳月不對：%s', v_row.month);
  assert v_row.closed_by = '20000000-0000-0000-0000-000000000001'::uuid, 'closed_by 應是呼叫者';

  -- details 快照 ＝ preview 減掉 income_amount（同一段 SQL，逐鍵相同）。
  assert v_row.details = (v_p - 'income_amount'),
    format('details 快照與 preview 不一致：%s vs %s', v_row.details, v_p - 'income_amount');

  -- income_entry_id 指向一筆真的收入。
  assert v_row.income_entry_id is not null, 'p_record_income = true 時應該有 income_entry_id';
  select * into v_e from public.entries e where e.id = v_row.income_entry_id;
  assert v_e.kind = 'income', '記下的應該是收入';
  assert v_e.amount = 3000, format('金額應等於 income_amount 3000，實際 %s', v_e.amount);
  assert v_e.occurred_on = (v_last + interval '1 month - 1 day')::date,
    format('日期應是清帳月的最後一天，實際 %s', v_e.occurred_on);
  assert v_e.payer_id is null, '共同收入不該有付款人';
  assert v_e.is_adjustment = false, '清帳收入不是沖銷筆';
  assert v_e.note = format('%s／%s 清帳', to_char(v_last, 'YYYY'), to_char(v_last, 'MM')),
    format('備註不對（全形斜線）：%s', v_e.note);

  -- 分類「清帳轉入」自動建出來，是 income 分類，排在原有 income 分類之後。
  select * into v_cat from public.categories c where c.id = v_e.category_id;
  assert v_cat.name = '清帳轉入', format('分類名不對：%s', v_cat.name);
  assert v_cat.kind = 'income', '清帳轉入必須是 income 分類';
  assert v_cat.icon = 'savings', format('icon 不對：%s', v_cat.icon);
  assert v_cat.sort = 2, format('sort 應是原有 income 分類最大 sort + 1 ＝ 2，實際 %s', v_cat.sort);
  assert (select count(*) from public.categories c
           where c.ledger_id = v_l and c.name = '清帳轉入') = 1,
    '清帳轉入分類只該有一個';

  -- 共同餘額因此增加 3,000（清帳走的仍是「一筆收入紀錄」這條路）。
  -- 上月本身沒有收入也沒有共同錢包支出，所以清帳前的累計水位是 0。
  assert (public.month_summary(v_l, (v_last + interval '1 month - 1 day')::date) ->> 'shared_balance')::bigint
         = 3000,
    '清帳記的收入應該照常進共同餘額';
end;
$$;
rollback;

\echo '== month_close: c07. close_month(p_record_income => false)：不記收入 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_before int := (select count(*) from public.entries e where e.ledger_id = v_l);
  v_row public.month_closes;
begin
  v_row := public.close_month(v_l, v_last, false);
  assert v_row.income_entry_id is null, 'p_record_income = false 時 income_entry_id 應為 null';
  assert (select count(*) from public.entries e where e.ledger_id = v_l) = v_before,
    '不勾一鍵記收入時不該多出任何帳目';
  assert not exists (select 1 from public.categories c
                     where c.ledger_id = v_l and c.name = '清帳轉入'),
    '不記收入時也不該建「清帳轉入」分類';
  -- details 照樣完整（快照與勾不勾無關）。
  assert jsonb_array_length(v_row.details -> 'members') = 2, 'details 仍應有兩位成員';
end;
$$;
rollback;

\echo '== month_close: c08. income_amount <= 0 時即使勾了也不記 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
-- 這一段以 postgres 身分跑：fixture 要調 members.joined_at（前端沒有這欄的授權），
-- 而被測的 close_month／month_close_preview 都是 security definer，只認 request.jwt.claims。

do $$
declare
  v_l public.ledgers;
  v_a uuid;
  v_cat uuid;
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_p jsonb;
  v_row public.month_closes;
begin
  -- 另開一本帳：上月只有「先付」沒有補入 → Σending ＝ −500。
  v_l := public.create_ledger('負數清帳帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;
  update public.members set joined_at = v_last::timestamptz where id = v_a;
  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, created_by, payer_id)
  values (v_l.id, 'expense', 500, v_cat, v_last + 3, v_a, v_a);

  v_p := public.month_close_preview(v_l.id, v_last);
  assert ((v_p -> 'members') -> 0 ->> 'ending')::bigint = -500, format('ending 應為 −500：%s', v_p);
  assert (v_p ->> 'income_amount')::bigint = 0, format('Σending < 0 時 income_amount 應夾成 0：%s', v_p);

  v_row := public.close_month(v_l.id, v_last, true);
  assert v_row.income_entry_id is null, 'income_amount ＝ 0 時即使勾了也不該記收入';
  assert not exists (select 1 from public.categories c
                     where c.ledger_id = v_l.id and c.name = '清帳轉入'),
    'income_amount ＝ 0 時不該建「清帳轉入」分類';
end;
$$;
rollback;

\echo '== month_close: c09. 清帳後該月的帳目／細項／預算／補入一律鎖死（month closed:）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_entry uuid := '40000000-0000-0000-0000-000000000007';   -- 上月「上月買菜」（Mike 先付）
  v_cat uuid := '30000000-0000-0000-0000-000000000001';
  v_topup uuid;
  v_line uuid;
  v_blocked boolean;
  v_err text;
begin
  select t.id into v_topup from public.personal_topups t
  where t.ledger_id = v_l and t.month = v_last and t.member_id = '20000000-0000-0000-0000-000000000001';

  perform public.close_month(v_l, v_last, false);

  -- entries：insert／update／delete。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
    values (v_l, 'expense', 100, v_cat, v_last + 3, '補記', '20000000-0000-0000-0000-000000000001',
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('entries insert 應被鎖月擋：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  v_blocked := false;
  begin update public.entries set amount = 1 where id = v_entry;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('entries update 應被鎖月擋：%s', v_err);

  v_blocked := false;
  begin delete from public.entries where id = v_entry;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('entries delete 應被鎖月擋：%s', v_err);

  -- line_items（直接寫子表的路徑）。
  v_blocked := false;
  begin
    insert into public.line_items (entry_id, name, amount, sort) values (v_entry, '偷加', 1, 0);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('line_items insert 應被鎖月擋：%s', v_err);

  -- budget_allocation。
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values (v_l, '30000000-0000-0000-0000-000000000007', 100, v_last + 2,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('budget_allocation insert 應被鎖月擋：%s', v_err);

  -- personal_topups：insert／delete（update 沒有授權，另在 topups.sql t10 用 definer 身分驗）。
  v_blocked := false;
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by)
    values (v_l, '20000000-0000-0000-0000-000000000001', 100, v_last + 2,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('personal_topups insert 應被鎖月擋：%s', v_err);

  v_blocked := false;
  begin delete from public.personal_topups where id = v_topup;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%', format('personal_topups delete 訊息不對：%s', v_err);
  -- 訊息與帳目、細項、預算完全同格式（帶被擋那筆所屬的月），不另立字面。
  assert v_err = format('month closed: %s', to_char(v_last, 'YYYY-MM')),
    format('補入的鎖月訊息應與帳目同格式：%s', v_err);

  -- 對照組：本月（未清）照樣寫得動。
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
  values (v_l, 'expense', 100, v_cat, date_trunc('month', current_date)::date + 1, '本月照樣可以',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
end;
$$;
rollback;

\echo '== month_close: c10. 鎖定範圍是「最後清帳月（含）以前」，不是只鎖有紀錄的那幾個月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_older date := (date_trunc('month', current_date) - interval '5 month')::date;
  v_cat uuid := '30000000-0000-0000-0000-000000000001';
  v_blocked boolean := false;
  v_err text;
begin
  perform public.close_month(v_l, v_last, false);

  -- 五個月前從來沒有清帳紀錄，但它早於最後清帳月 → 一樣鎖。
  -- （不鎖的話，補記進去的那筆永遠不會落在「下一個可清月」，影響會永久留在補入剩餘裡。）
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
    values (v_l, 'expense', 100, v_cat, v_older + 3, '補記到更早的月',
            '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%',
    format('最後清帳月以前的月份都該鎖住：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== month_close: c11. 任一成員都能清，不需多簽 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_row public.month_closes;
begin
  v_row := public.close_month(v_l, v_last, true);
  assert v_row.closed_by = '20000000-0000-0000-0000-000000000002'::uuid,
    '老婆清的帳，closed_by 應是老婆';
  -- 收入筆的 created_by 也是實際清帳的人。
  assert (select e.created_by from public.entries e where e.id = v_row.income_entry_id)
         = '20000000-0000-0000-0000-000000000002'::uuid,
    '清帳收入的 created_by 應是清帳者';
end;
$$;
rollback;

\echo '== month_close: c12. 已清月照樣由帳目算，與 details 快照相等（不再回 0）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_row public.month_closes;
  v_s jsonb;
  v_snap jsonb;
  v_live jsonb;
begin
  v_row := public.close_month(v_l, v_last, false);
  v_s := public.month_summary(v_l, (v_last + interval '1 month - 1 day')::date);

  -- month_summary 的 members 與快照逐位相符（已清月的資料被鎖死，兩條路必然同值）。
  assert (v_s ->> 'shared_paid')::bigint = (v_row.details ->> 'shared_paid')::bigint,
    format('shared_paid 對不上：%s vs %s', v_s ->> 'shared_paid', v_row.details ->> 'shared_paid');
  foreach v_snap in array array(select jsonb_array_elements(v_row.details -> 'members')) loop
    select x into v_live from jsonb_array_elements(v_s -> 'members') x
     where x ->> 'member_id' = v_snap ->> 'member_id';
    assert (v_live ->> 'topup')::bigint = (v_snap ->> 'topup')::bigint
       and (v_live ->> 'paid')::bigint = (v_snap ->> 'paid')::bigint
       and (v_live ->> 'remaining')::bigint = (v_snap ->> 'ending')::bigint,
      format('已清月的即時計算與快照對不上：%s vs %s', v_live, v_snap);
  end loop;
end;
$$;
rollback;

\echo '== month_close: c13. month_closes 對前端只讀，非成員看不到 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_blocked boolean;
  v_err text;
begin
  perform public.close_month(v_l, v_last, false);
  assert (select count(*) from public.month_closes) = 1, '成員應該讀得到清帳紀錄';

  -- 不可撤銷：連 delete 都沒有授權。
  v_blocked := false;
  begin delete from public.month_closes;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked, '清帳紀錄竟然刪得掉（清帳是不可撤銷的）';
  raise notice '  預期的失敗：%', v_err;

  v_blocked := false;
  begin update public.month_closes set details = '{}'::jsonb;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked, '清帳紀錄竟然改得動';
end;
$$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select public.close_month('10000000-0000-0000-0000-000000000001',
                          (date_trunc('month', current_date) - interval '1 month')::date, false)::text as _c \gset
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims2 \gset
set local role authenticated;
do $$
begin
  assert (select count(*) from public.month_closes) = 0, '非成員竟然看得到別人帳本的清帳紀錄';
end;
$$;
rollback;

\echo '== month_close: c14. 收入筆必須先於 month_closes 落地（順序錯就會被自己的鎖月擋）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_row public.month_closes;
  v_blocked boolean := false;
  v_err text;
begin
  v_row := public.close_month(v_l, v_last, true);
  -- 收入筆真的落在被鎖住的那個月裡（＝它一定是在 month_closes 之前寫進去的）。
  assert (select (date_trunc('month', e.occurred_on::timestamp))::date
            from public.entries e where e.id = v_row.income_entry_id) = v_last,
    '清帳收入應落在清帳月';

  -- 反證：現在同一個月再插一筆一模一樣的收入，一定被鎖月擋。
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by)
    select v_l, 'income', e.amount, e.category_id, e.occurred_on, e.note, e.created_by
    from public.entries e where e.id = v_row.income_entry_id;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like 'month closed:%',
    format('清完之後那個月應該連收入都寫不進去：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== month_close: c15. 清完可續清下一月（首次＝最早月，之後＝上次＋1）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
-- 這一段以 postgres 身分跑：fixture 要調 members.joined_at（前端沒有這欄的授權），
-- 而被測的 close_month／month_close_preview 都是 security definer，只認 request.jwt.claims。

do $$
declare
  v_l public.ledgers;
  v_a uuid;
  v_cat uuid;
  v_m3 date := (date_trunc('month', current_date) - interval '3 month')::date;
  v_m2 date := (date_trunc('month', current_date) - interval '2 month')::date;
  v_m1 date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_err text;
  v_blocked boolean := false;
begin
  v_l := public.create_ledger('連續清帳帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;
  update public.members set joined_at = v_m3::timestamptz where id = v_a;
  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;

  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by) values
    (v_l.id, v_a, 1000, v_m3 + 1, v_a),
    (v_l.id, v_a, 1000, v_m2 + 1, v_a),
    (v_l.id, v_a, 1000, v_m1 + 1, v_a);
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, created_by, payer_id) values
    (v_l.id, 'expense', 100, v_cat, v_m3 + 2, v_a, v_a),
    (v_l.id, 'expense', 100, v_cat, v_m2 + 2, v_a, v_a),
    (v_l.id, 'expense', 100, v_cat, v_m1 + 2, v_a, v_a);

  -- 首次可清月＝三個來源的最早月（這裡三者都是 v_m3）。
  begin perform public.month_close_preview(v_l.id, v_m1);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = format('close_month: must close %s first', to_char(v_m3, 'YYYY-MM')),
    format('首次可清月應是 %s：%s', v_m3, v_err);

  perform public.close_month(v_l.id, v_m3, false);
  perform public.close_month(v_l.id, v_m2, false);
  perform public.close_month(v_l.id, v_m1, false);
  assert (select count(*) from public.month_closes mc where mc.ledger_id = v_l.id) = 3,
    '三個月都該清得掉';

  -- 全部清完之後，下一個可清月是本月，本月還沒結束。
  v_blocked := false;
  begin perform public.month_close_preview(v_l.id, (date_trunc('month', current_date))::date);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = 'close_month: month not ended', format('訊息不對：%s', v_err);
end;
$$;
rollback;

\echo '== month_close: c16. 只有補入沒有帳目的月份也算「最早可清月」=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
-- 這一段以 postgres 身分跑：fixture 要調 members.joined_at（前端沒有這欄的授權），
-- 而被測的 close_month／month_close_preview 都是 security definer，只認 request.jwt.claims。

do $$
declare
  v_l public.ledgers;
  v_a uuid;
  v_m2 date := (date_trunc('month', current_date) - interval '2 month')::date;
  v_m1 date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_err text;
  v_blocked boolean := false;
begin
  v_l := public.create_ledger('只有補入的帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;
  -- 加入月＝上月，但兩個月前有一筆補入 → 最早可清月要往前推到補入那個月。
  update public.members set joined_at = v_m1::timestamptz where id = v_a;
  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by)
  values (v_l.id, v_a, 1000, v_m2 + 1, v_a);

  begin perform public.month_close_preview(v_l.id, v_m1);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = format('close_month: must close %s first', to_char(v_m2, 'YYYY-MM')),
    format('最早可清月應由補入決定（%s）：%s', v_m2, v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 清得掉，而且明細只有補入沒有先付。
  assert ((public.month_close_preview(v_l.id, v_m2) -> 'members') -> 0 ->> 'ending')::bigint = 1000,
    '只有補入的月份 ending 應等於補入';
end;
$$;
rollback;

\echo '== month_close: c17. 內部 helper 不給前端執行 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  v_blocked := false;
  begin perform public.month_close_details('10000000-0000-0000-0000-000000000001',
                                           (date_trunc('month', current_date) - interval '1 month')::date);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like '%permission denied%',
    format('month_close_details 不該給前端執行：%s', v_err);

  v_blocked := false;
  begin perform public.month_close_guard('10000000-0000-0000-0000-000000000001',
                                         (date_trunc('month', current_date) - interval '1 month')::date);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like '%permission denied%',
    format('month_close_guard 不該給前端執行：%s', v_err);

  v_blocked := false;
  begin perform public.month_close_income_amount('{"members":[]}'::jsonb);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like '%permission denied%',
    format('month_close_income_amount 不該給前端執行：%s', v_err);

  v_blocked := false;
  begin perform public.raise_if_month_closed('10000000-0000-0000-0000-000000000001',
                                             (date_trunc('month', current_date))::date);
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err like '%permission denied%',
    format('raise_if_month_closed 不該給前端執行：%s', v_err);
end;
$$;
rollback;

\echo '== month_close: c18. 鎖月檢查與 close_month 取同一把 advisory lock（共享／排他成對）=='
begin;
do $$
declare
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_key bigint := hashtextextended('10000000-0000-0000-0000-000000000001', 0);
  v_cat uuid := '30000000-0000-0000-0000-000000000001';
begin
  -- 這條守的是一個真的會發生的競態（security ＋ db review 同報）：
  -- close_month 取排他鎖、算好快照、還沒寫 month_closes 的那個窗口裡，
  -- 另一個 session 補記一筆該月的帳目會「查不到 month_closes 列」而放行 →
  -- 那筆錢沒被算進快照，該月卻立刻鎖死，改不掉也永遠不會再被清一次。
  -- 修法是讓 raise_if_month_closed 取**共享**鎖：寫入之間不互斥，但與 close_month 的排他鎖互斥。
  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text, true);

  -- 一筆未清月的正常寫入就會觸發 a_entries_month_closed_trg → raise_if_month_closed。
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
  values (v_l, 'expense', 100, v_cat, date_trunc('month', current_date)::date + 1, '取鎖用',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');

  -- 交易還沒結束，advisory 共享鎖必須還握在手上，而且 key 與 close_month 的排他鎖逐字相同。
  assert exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory'
      and l.pid = pg_backend_pid()
      and l.granted
      and l.mode = 'ShareLock'
      and l.classid = (((v_key >> 32) & 4294967295))::oid
      and l.objid  = ((v_key & 4294967295))::oid
      and l.objsubid = 1
  ), '鎖月檢查沒有取到與 close_month 同 key 的共享 advisory lock';

  -- 第二道（catalog）：定義裡真的有那一行，改壞了在這裡也會紅。
  assert pg_get_functiondef('public.raise_if_month_closed(uuid, date)'::regprocedure)
         like '%pg_advisory_xact_lock_shared(hashtextextended(p_ledger::text, 0))%',
    'raise_if_month_closed 的定義裡找不到共享 advisory lock';
  assert pg_get_functiondef('public.close_month(uuid, date, boolean)'::regprocedure)
         like '%pg_advisory_xact_lock(hashtextextended(p_ledger::text, 0))%',
    'close_month 的排他鎖不見了（或換了 key）';
end;
$$;
rollback;

\echo '== month_close: c19. 已清月的 line_items／budget_allocation 連 UPDATE／DELETE 都擋 =='
begin;
do $$
declare
  -- 以 postgres 身分跑：前端對 budget_allocation 本來就沒有 UPDATE／DELETE 授權（budget.sql 段 e 驗過），
  -- 這一段要驗的是「即使繞過授權層（service_role、人工救援），鎖月 trigger 仍是最後一道」。
  v_l uuid := '10000000-0000-0000-0000-000000000001';
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_entry uuid := '40000000-0000-0000-0000-000000000007';   -- 上月「上月買菜」
  v_li uuid;
  v_ba uuid;
  v_blocked boolean;
  v_err text;
  v_expect text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text, true);
  v_expect := format('month closed: %s', to_char(v_last, 'YYYY-MM'));

  -- 清帳前先在上月放一列細項（種子的上月帳目沒有細項），預算則用種子既有的上月那筆。
  insert into public.line_items (entry_id, name, amount, sort)
  values (v_entry, '上月細項', 100, 0) returning id into v_li;
  select b.id into v_ba from public.budget_allocation b
   where b.ledger_id = v_l and b.month = v_last order by b.category_id limit 1;
  assert v_ba is not null, '前置條件不成立：種子上月應有預算';

  perform public.close_month(v_l, v_last, false);

  -- line_items：UPDATE。
  v_blocked := false;
  begin update public.line_items set amount = 1 where id = v_li;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = v_expect, format('line_items update 應被鎖月擋：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- line_items：DELETE。
  v_blocked := false;
  begin delete from public.line_items where id = v_li;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = v_expect, format('line_items delete 應被鎖月擋：%s', v_err);

  -- budget_allocation：UPDATE。
  v_blocked := false;
  begin update public.budget_allocation set amount = 1 where id = v_ba;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = v_expect, format('budget_allocation update 應被鎖月擋：%s', v_err);

  -- budget_allocation：DELETE。
  v_blocked := false;
  begin delete from public.budget_allocation where id = v_ba;
  exception when others then v_blocked := true; v_err := sqlerrm; end;
  assert v_blocked and v_err = v_expect, format('budget_allocation delete 應被鎖月擋：%s', v_err);

  -- 對照組：本月（未清）的同兩張表照樣改得動。
  update public.budget_allocation set amount = 6100
   where ledger_id = v_l and month = (date_trunc('month', current_date))::date
     and category_id = '30000000-0000-0000-0000-000000000001';
  update public.line_items set amount = 90
   where entry_id = '40000000-0000-0000-0000-000000000003' and name = '雞蛋';
end;
$$;
rollback;

\echo '== month_close: c20. income_amount 越過 int 上界時給看得懂的錯，不是 integer out of range =='
begin;
do $$
declare
  -- 以 postgres 身分跑：fixture 要調 joined_at。
  v_l public.ledgers;
  v_a uuid;
  v_last date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_p jsonb;
  v_blocked boolean := false;
  v_err text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text, true);
  v_l := public.create_ledger('大額清帳帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;
  update public.members set joined_at = v_last::timestamptz where id = v_a;

  -- 兩筆各 20 億的補入：明細算得出來（bigint），但落地要塞進 entries.amount（int）就爆了。
  insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by) values
    (v_l.id, v_a, 2000000000, v_last + 1, v_a),
    (v_l.id, v_a, 2000000000, v_last + 2, v_a);

  -- 預覽照樣算得出來（這就是明細一路走 bigint 的理由）。
  v_p := public.month_close_preview(v_l.id, v_last);
  assert (v_p ->> 'income_amount')::bigint = 4000000000,
    format('預覽應該算得出 40 億，實際 %s', v_p ->> 'income_amount');

  -- 勾了一鍵記收入 → 落地時擋在看得懂的訊息上。
  begin
    perform public.close_month(v_l.id, v_last, true);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '40 億的清帳收入竟然記得進 entries.amount（int）';
  assert v_err = 'close_month: income amount exceeds limit',
    format('應該是看得懂的訊息，而不是 integer out of range：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 不勾就沒事：清帳本身不受 int 上界影響（快照是 bigint）。
  perform public.close_month(v_l.id, v_last, false);
  assert (select (mc.details -> 'members' -> 0 ->> 'ending')::bigint
            from public.month_closes mc where mc.ledger_id = v_l.id) = 4000000000,
    '快照應該存得下 40 億';
end;
$$;
rollback;

\echo 'month_close.sql PASS'
