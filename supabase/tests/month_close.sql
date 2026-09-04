-- 清帳（month_closes／month_close_preview／close_month／已清帳月份鎖定 trigger）測試
-- — spec v1.4「清帳」節、ADR-0008。
-- 身分模擬與 rls.sql 相同：request.jwt.claims + set local role authenticated。
-- 一段只驗一條規則，各自獨立 fixture，全部包在 begin/rollback 裡。
--
-- fixture 用 pg_temp 的暫時函式建（psql 連線結束即消失，不留在資料庫裡）：
-- 各段的 fixture 完全一樣，重抄五遍只會讓「哪一條斷言在驗什麼」更難看出來。
-- 建 fixture 那段以 postgres 身分跑（設 joined_at／monthly_topup 是前端沒有的路徑），
-- 被驗的 seam（RPC、RLS、trigger）一律切成 authenticated 再打。

-- 段號依檔內位置單調遞增，一律 cNN（帶 c 前綴，一眼看得出不是 brief 驗收標準的 1～18）。
-- 段號 → 驗收標準對照：
--   c01 ← AC 11
--   c02 ← AC 12
--   c03 ← AC 13
--   c04 ← sec m1（無分攤列的拆帳筆不擋清帳）
--   c05 ← B.2 補入額適用區間
--   c06 ← AC 14
--   c07 ← AC 14（任一成員可清）
--   c08 ← AC 15
--   c09 ← AC 15（N=0）
--   c10 ← db N2（已清帳單一定義）
--   c11 ← AC 16
--   c12 ← AC 17
--   c13 ← db M3（鎖定範圍含更早月份）
--   c14 ← sec m6（預算 UPDATE／DELETE）
--   c15 ← sec m2（補入額上下界）
--   c16 ← sec m7（details 必須 definer）
--   c17 ← sec m3（最大餘數法）
--   c18 ← sec m3（三人取整）
--   c19 ← code T6（子表 trigger 直測）
--   c20 ← B.5（trigger 執行順序）
--   c21 ← sec n6（金額越過 int 上界仍算得出來）

\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'

create function pg_temp.mc_claims(p_sub text) returns void
language plpgsql as $fx$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
end;
$fx$;

-- 共用 fixture：帳本 L、成員 A（Mike，建帳本者）與 B（老婆，join_ledger 加入），
-- 兩人都在「上上月」加入，補入額 A 1,000 / B 8,000。
-- 上上月四筆帳：
--   A 私人支出 2,000        → A net −2,000
--   A 代墊 1,000 均分 500/500 → 未結算時 A net −1,000；結算後 A −500、B −500
--   共同錢包支出 2,000       → 不進個人，shared_delta −2,000
--   共同收入 3,000           → 不進個人，shared_delta +3,000
-- 結算後（p_settle）：A topup 1,000 + net(−2,500) = ending −1,500（負：共同帳戶補 A）
--                     B topup 8,000 + net(  −500) = ending  7,500（正：B 轉給共同帳戶）
--                     shared_delta = 3,000 − 2,000 = 1,000
create function pg_temp.mc_fixture(p_settle boolean default false,
                                   p_close_prev2 boolean default false)
returns void
language plpgsql
as $fx$
declare
  v_l public.ledgers;
  v_a uuid;
  v_b uuid;
  v_cat uuid;
  v_cat2 uuid;
  v_inc uuid;
  v_cur date := date_trunc('month', (now() at time zone 'Asia/Taipei'))::date;
  v_prev date;
  v_prev2 date;
  v_adv uuid;
  v_priv uuid;
  v_s public.settlements;
begin
  v_prev  := (v_cur - interval '1 month')::date;
  v_prev2 := (v_cur - interval '2 month')::date;

  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');
  v_l := public.create_ledger('清帳測試帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;

  perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');
  perform public.join_ledger(v_l.invite_code);
  select m.id into v_b from public.members m where m.ledger_id = v_l.id and m.id <> v_a;

  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');

  update public.members set joined_at = v_prev2 + 2, monthly_topup = 1000 where id = v_a;
  update public.members set joined_at = v_prev2 + 3, monthly_topup = 8000 where id = v_b;

  select c.id into v_cat  from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;
  select c.id into v_cat2 from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort offset 1 limit 1;
  select c.id into v_inc  from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'income' order by c.sort limit 1;

  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'private', 2000, v_cat, v_prev2 + 4, 'A 私人支出', v_a, v_a, 'common')
  returning id into v_priv;

  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'shared', 1000, v_cat, v_prev2 + 5, 'A 代墊', v_a, v_a, 'equal')
  returning id into v_adv;
  insert into public.entry_splits (entry_id, member_id, share) values
    (v_adv, v_a, 500), (v_adv, v_b, 500);

  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'shared', 2000, v_cat2, v_prev2 + 6, '共同錢包支出', v_a, null, 'common');

  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l.id, 'income', 'shared', 3000, v_inc, v_prev2 + 7, '共同收入', v_a, null, 'common');

  if p_settle then
    v_s := public.initiate_settlement(v_l.id);
    perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');
    perform public.approve_settlement(v_s.id);
    perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');
  end if;

  if p_close_prev2 then
    perform public.close_month(v_l.id, v_prev2);
  end if;

  perform set_config('app.mc_ledger', v_l.id::text, true);
  perform set_config('app.mc_a', v_a::text, true);
  perform set_config('app.mc_b', v_b::text, true);
  perform set_config('app.mc_cat', v_cat::text, true);
  perform set_config('app.mc_adv', v_adv::text, true);
  perform set_config('app.mc_priv', v_priv::text, true);
  perform set_config('app.mc_cur', v_cur::text, true);
  perform set_config('app.mc_prev', v_prev::text, true);
  perform set_config('app.mc_prev2', v_prev2::text, true);
end;
$fx$;

\echo '== month_close: c01. 當月不可清（month not ended）、非月初被擋 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture() as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_cur date := current_setting('app.mc_cur')::date;
  v_blocked boolean := false;
  v_err text;
begin
  begin
    perform public.month_close_preview(v_l, v_cur);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '當月竟然清得了';
  assert v_err like '%month not ended%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 非月初：先被「必須是月初」擋掉（訊息不能是 month not ended）。
  v_blocked := false;
  begin
    perform public.month_close_preview(v_l, v_cur - 10);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非月初竟然清得了';
  assert v_err like '%month must be first day%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== month_close: c02. 必須按序：首次可清月＝最早帳目月，跳月被擋 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture() as _fx \gset
-- 這段要驗「首次可清月＝最早帳目月」，所以把兩位成員的加入月挪回當月
-- （否則最早的是加入月 = 上上月，least() 取到的會是同一個月，看不出差別）。
update public.members set joined_at = now()
 where ledger_id = current_setting('app.mc_ledger')::uuid;
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_prev date := current_setting('app.mc_prev')::date;
  v_prev2 date := current_setting('app.mc_prev2')::date;
  v_blocked boolean := false;
  v_err text;
begin
  begin
    perform public.month_close_preview(v_l, v_prev);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然可以跳過上上月直接清上月';
  assert v_err like format('%%must close %s first%%', to_char(v_prev2, 'YYYY-MM')),
    format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== month_close: c03. 該月有未結算代墊 → unsettled；結算後 preview 明細正確 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => false) as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_prev2 date := current_setting('app.mc_prev2')::date;
  v_blocked boolean := false;
  v_err text;
begin
  begin
    perform public.month_close_preview(v_l, v_prev2);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '有未結算代墊竟然清得了';
  assert v_err like '%unsettled entries in month%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_a uuid := current_setting('app.mc_a')::uuid;
  v_b uuid := current_setting('app.mc_b')::uuid;
  v_prev2 date := current_setting('app.mc_prev2')::date;
  v_p jsonb;
  v_ra jsonb;
  v_rb jsonb;
begin
  v_p := public.month_close_preview(v_l, v_prev2);
  assert v_p->>'month' = to_char(v_prev2, 'YYYY-MM-DD'), format('month 不對：%s', v_p->>'month');
  assert jsonb_array_length(v_p->'members') = 2, format('members 筆數不對：%s', v_p);

  -- 排序：joined_at, id → A 在前。
  v_ra := v_p->'members'->0;
  v_rb := v_p->'members'->1;
  assert (v_ra->>'member_id')::uuid = v_a, format('members[0] 應是 A：%s', v_ra);
  assert (v_rb->>'member_id')::uuid = v_b, format('members[1] 應是 B：%s', v_rb);
  -- 明細要能直接餵給清帳頁的列表（spec：每位成員一列，顯示名字）。
  assert v_ra->>'display_name' = (select m.display_name from public.members m where m.id = v_a),
    format('members[0] 的 display_name 不對：%s', v_ra);
  assert v_rb->>'display_name' = (select m.display_name from public.members m where m.id = v_b),
    format('members[1] 的 display_name 不對：%s', v_rb);

  -- A：topup 1,000、net −2,000（私人）−500（已結算份額）＝ −2,500、ending −1,500（負＝共同補他）
  assert (v_ra->>'topup')::int = 1000, format('A topup 不對：%s', v_ra);
  assert (v_ra->>'net')::int = -2500, format('A net 不對：%s', v_ra);
  assert (v_ra->>'ending')::int = -1500, format('A ending 不對：%s', v_ra);
  -- B：topup 8,000、net −500、ending 7,500（正＝他轉給共同）
  assert (v_rb->>'topup')::int = 8000, format('B topup 不對：%s', v_rb);
  assert (v_rb->>'net')::int = -500, format('B net 不對：%s', v_rb);
  assert (v_rb->>'ending')::int = 7500, format('B ending 不對：%s', v_rb);

  -- shared_delta ＝ 共同收入 3,000 − 共同錢包支出 2,000（代墊不算）
  assert (v_p->>'shared_delta')::int = 1000, format('shared_delta 不對：%s', v_p->>'shared_delta');
  -- 一切正常時提醒是空陣列（不是缺鍵，前端才不用寫 null 判斷）。
  assert v_p ? 'warnings' and jsonb_array_length(v_p->'warnings') = 0,
    format('正常情境不該有提醒：%s', v_p->'warnings');
end;
$$;
rollback;

\echo '== month_close: c04. 沒有分攤列的拆帳筆不擋清帳（與 initiate_settlement 同判準）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- 代墊筆但「沒有任何 entry_splits」：initiate_settlement 根本撿不到它（它要求 exists splits），
-- 所以它永遠 settle 不了。清帳若拿 settled_state 一刀切就會被它卡死、那個月永遠清不掉。
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values (current_setting('app.mc_ledger')::uuid, 'expense', 'shared', 700,
        current_setting('app.mc_cat')::uuid, current_setting('app.mc_prev2')::date + 8,
        'A 代墊但沒填分攤', current_setting('app.mc_a')::uuid,
        current_setting('app.mc_a')::uuid, 'equal');
set local role authenticated;
do $$
declare
  v_p jsonb;
  v_ra jsonb;
begin
  -- 不該被擋。
  v_p := public.month_close_preview(current_setting('app.mc_ledger')::uuid,
                                    current_setting('app.mc_prev2')::date);
  assert v_p is not null, '沒有分攤列的拆帳筆不該擋住清帳';
  -- 但它會由付款人全額承擔，清帳又不可撤銷 → 預覽要先講一聲。
  -- DB 只回結構（是哪一類、幾筆），中文文案是前端的事。
  assert jsonb_array_length(v_p->'warnings') = 1,
    format('應該剛好一則提醒：%s', v_p->'warnings');
  assert v_p->'warnings'->0->>'code' = 'unsplit_advances',
    format('提醒的 code 不對：%s', v_p->'warnings'->0);
  assert (v_p->'warnings'->0->>'count')::int = 1,
    format('提醒的 count 不對（那個月只有一筆沒分攤的代墊）：%s', v_p->'warnings'->0);
  raise notice '  預期的提醒：%', v_p->'warnings'->0;
  -- 而且它仍然算「本人未結算代墊的全額」：A 的 net 從 −2,500 變 −3,200。
  select m into v_ra from jsonb_array_elements(v_p->'members') m
   where (m->>'member_id')::uuid = current_setting('app.mc_a')::uuid;
  assert (v_ra->>'net')::int = -3200, format('A net 應含那筆 700 的全額：%s', v_ra);
  assert (v_ra->>'ending')::int = 1000 - 3200, format('A ending 不對：%s', v_ra);
end;
$$;
rollback;

\echo '== month_close: c05. 加入月晚於清帳月的成員，該月沒有補入額 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- B 改成「本月才加入」：上上月他還不在，那個月不該有補入額。
update public.members set joined_at = now() where id = current_setting('app.mc_b')::uuid;
set local role authenticated;
do $$
declare
  v_p jsonb;
  v_rb jsonb;
begin
  v_p := public.month_close_preview(current_setting('app.mc_ledger')::uuid,
                                    current_setting('app.mc_prev2')::date);
  select m into v_rb from jsonb_array_elements(v_p->'members') m
   where (m->>'member_id')::uuid = current_setting('app.mc_b')::uuid;
  assert (v_rb->>'topup')::int = 0, format('B 在加入前的月份不該有補入額：%s', v_rb);
  assert (v_rb->>'net')::int = -500, format('B 的份額仍要算：%s', v_rb);
  assert (v_rb->>'ending')::int = -500, format('B 的月末餘額不對：%s', v_rb);
end;
$$;
rollback;

\echo '== month_close: c06. close_month 落地、details 與 preview 相同、重清被擋、可續清下一月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_a uuid := current_setting('app.mc_a')::uuid;
  v_b uuid := current_setting('app.mc_b')::uuid;
  v_prev date := current_setting('app.mc_prev')::date;
  v_prev2 date := current_setting('app.mc_prev2')::date;
  v_preview jsonb;
  v_row public.month_closes;
  v_ra jsonb;
  v_rb jsonb;
  v_blocked boolean := false;
  v_err text;
begin
  v_preview := public.month_close_preview(v_l, v_prev2);
  v_row := public.close_month(v_l, v_prev2);

  assert v_row.ledger_id = v_l and v_row.month = v_prev2, format('close 回傳不對：%s', v_row);
  assert v_row.closed_by = v_a, format('closed_by 應是呼叫者：%s', v_row.closed_by);
  -- 落地的 details 是**事實快照**，不含預覽當下才有意義的 warnings。
  assert not (v_row.details ? 'warnings'),
    format('落地的 details 不該帶 warnings：%s', v_row.details);
  assert v_row.details = v_preview - 'warnings',
    format('details 應與 preview（扣掉 warnings）相同：%s vs %s', v_row.details, v_preview);
  assert (select count(*) from public.month_closes mc where mc.ledger_id = v_l) = 1,
    'month_closes 應該剛好一列';

  -- 落地的 details 自己也要手算對（不只跟 preview 比對，不然兩邊一起錯還是綠的）。
  -- A：topup 1,000 ＋ net(−2,000 私人 −500 已結算份額) ＝ −1,500（負：共同帳戶補 A）
  -- B：topup 8,000 ＋ net(−500) ＝ 7,500（正：B 轉給共同帳戶）
  select m into v_ra from jsonb_array_elements(v_row.details->'members') m
   where (m->>'member_id')::uuid = v_a;
  select m into v_rb from jsonb_array_elements(v_row.details->'members') m
   where (m->>'member_id')::uuid = v_b;
  assert (v_ra->>'ending')::int = -1500, format('落地的 A ending 不對：%s', v_ra);
  assert (v_rb->>'ending')::int = 7500, format('落地的 B ending 不對：%s', v_rb);
  -- 每列都要帶得動清帳頁列表所需的名字。
  assert (select bool_and(m ? 'display_name' and length(m->>'display_name') > 0)
          from jsonb_array_elements(v_row.details->'members') m),
    format('details.members 每列都要有非空的 display_name：%s', v_row.details);

  -- 同月再清 → 看得懂的訊息（不是 unique violation）。
  begin
    perform public.close_month(v_l, v_prev2);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '同月竟然清得了第二次';
  assert v_err like '%already closed%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 順序推進：接著可以清上月（上月沒有帳目，ending ＝ 補入額）。
  v_row := public.close_month(v_l, v_prev);
  assert v_row.month = v_prev, format('第二次清帳月份不對：%s', v_row.month);
  assert ((v_row.details->'members'->0)->>'net')::int = 0, format('上月 net 應為 0：%s', v_row.details);
  assert ((v_row.details->'members'->0)->>'ending')::int = 1000, format('上月 A ending 應為 1,000：%s', v_row.details);
  assert (v_row.details->>'shared_delta')::int = 0, format('上月 shared_delta 應為 0：%s', v_row.details);
end;
$$;
rollback;

\echo '== month_close: c07. 任一成員都能清帳：A 清上上月後，由 B 接著清上月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
set local role authenticated;
-- 先由 A（建帳本的人）清上上月。
do $$
declare
  v_row public.month_closes;
begin
  v_row := public.close_month(current_setting('app.mc_ledger')::uuid,
                              current_setting('app.mc_prev2')::date);
  assert v_row.closed_by = current_setting('app.mc_a')::uuid,
    format('第一次清帳的 closed_by 應是 A：%s', v_row.closed_by);
end;
$$;
-- 換 B（沒發起過任何清帳的另一位成員）接著清下一月：清帳不需多簽、也不限發起人。
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_row public.month_closes;
  v_ra jsonb;
  v_rb jsonb;
begin
  v_row := public.close_month(current_setting('app.mc_ledger')::uuid,
                              current_setting('app.mc_prev')::date);
  assert v_row.month = current_setting('app.mc_prev')::date,
    format('B 清的月份不對：%s', v_row.month);
  assert v_row.closed_by = current_setting('app.mc_b')::uuid,
    format('closed_by 應是實際執行的 B：%s', v_row.closed_by);
  assert (select count(*) from public.month_closes mc
           where mc.ledger_id = current_setting('app.mc_ledger')::uuid) = 2,
    '兩個月都清完後應有兩列清帳紀錄';

  -- 上月沒有任何帳目 → 每個人的 ending 就是自己的補入額。
  select m into v_ra from jsonb_array_elements(v_row.details->'members') m
   where (m->>'member_id')::uuid = current_setting('app.mc_a')::uuid;
  select m into v_rb from jsonb_array_elements(v_row.details->'members') m
   where (m->>'member_id')::uuid = current_setting('app.mc_b')::uuid;
  assert (v_ra->>'ending')::int = 1000, format('上月 A ending 應為 1,000：%s', v_ra);
  assert (v_rb->>'ending')::int = 8000, format('上月 B ending 應為 8,000：%s', v_rb);
  assert (v_row.details->>'shared_delta')::int = 0,
    format('上月沒有共同收支，shared_delta 應為 0：%s', v_row.details);
end;
$$;
rollback;

\echo '== month_close: c08. 清帳後 month_summary 的個人餘額不再含該月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- 三個月都要有帳，Σnet 才不會退化成「只有一個月」：
-- 上月 A 私人收入 800、本月 A 私人支出 150（上上月的 net 是 fixture 的 −2,500）。
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values
  (current_setting('app.mc_ledger')::uuid, 'income', 'private', 800,
   current_setting('app.mc_cat')::uuid, current_setting('app.mc_prev')::date + 6, '上月接案',
   current_setting('app.mc_a')::uuid, current_setting('app.mc_a')::uuid, 'common'),
  (current_setting('app.mc_ledger')::uuid, 'expense', 'private', 150,
   current_setting('app.mc_cat')::uuid, current_setting('app.mc_cur')::date + 2, '本月私人',
   current_setting('app.mc_a')::uuid, current_setting('app.mc_a')::uuid, 'common');
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_cur date := current_setting('app.mc_cur')::date;
  v_prev2 date := current_setting('app.mc_prev2')::date;
  v_until date := (v_cur + interval '1 month - 1 day')::date;
  v_before bigint;
  v_after bigint;
begin
  -- 清帳前（無 closes）：加入月＝上上月、p_until＝本月底 → N ＝ 3
  --   3 × 1,000 ＋ [上上月 −2,500 ＋ 上月 +800 ＋ 本月 −150] ＝ 3,000 − 1,850 ＝ 1,150
  v_before := (public.month_summary(v_l, v_until)->'me'->>'personal_balance')::bigint;
  assert v_before = 3 * 1000 + (-2500 + 800 - 150),
    format('清帳前個人餘額不對（應為 1,150）：%s', v_before);

  perform public.close_month(v_l, v_prev2);

  -- 清帳後：上上月整項（補入額與淨變動都）移除 → N ＝ 2
  --   2 × 1,000 ＋ [上月 +800 ＋ 本月 −150] ＝ 2,000 ＋ 650 ＝ 2,650
  v_after := (public.month_summary(v_l, v_until)->'me'->>'personal_balance')::bigint;
  assert v_after = 2 * 1000 + (800 - 150),
    format('清帳後個人餘額不對（應為 2,650）：%s', v_after);

  -- 差額 ＝ 被移除那個月的 topup ＋ net
  assert v_before - v_after = 1000 + (-2500),
    format('清前清後差額應等於 topup + net：%s', v_before - v_after);
end;
$$;
rollback;

\echo '== month_close: c09. 加入月晚於 p_until 所在月 → N ＝ 0，個人餘額只剩 Σnet =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values
  (current_setting('app.mc_ledger')::uuid, 'income', 'private', 800,
   current_setting('app.mc_cat')::uuid, current_setting('app.mc_prev')::date + 6, '上月接案',
   current_setting('app.mc_a')::uuid, current_setting('app.mc_a')::uuid, 'common'),
  (current_setting('app.mc_ledger')::uuid, 'expense', 'private', 150,
   current_setting('app.mc_cat')::uuid, current_setting('app.mc_cur')::date + 2, '本月私人',
   current_setting('app.mc_a')::uuid, current_setting('app.mc_a')::uuid, 'common');
-- A 的加入月挪到「下個月」：[加入月, p_until 所在月] 是空區間 → 一次補入額都不給。
update public.members
   set joined_at = (current_setting('app.mc_cur')::date + interval '1 month' + interval '3 day')
 where id = current_setting('app.mc_a')::uuid;
set local role authenticated;
do $$
declare
  v_cur date := current_setting('app.mc_cur')::date;
  v_until date := (v_cur + interval '1 month - 1 day')::date;
  v_me jsonb;
begin
  v_me := public.month_summary(current_setting('app.mc_ledger')::uuid, v_until)->'me';
  assert (v_me->>'monthly_topup')::int = 1000, format('補入額本身還是要回報：%s', v_me);
  -- N ＝ 0 → 0 × 1,000 ＋ [−2,500 ＋ 800 − 150] ＝ −1,850
  assert (v_me->>'personal_balance')::int = -2500 + 800 - 150,
    format('加入月晚於 p_until 時個人餘額應只剩 Σnet（−1,850）：%s', v_me->>'personal_balance');
end;
$$;
rollback;

\echo '== month_close: c10. 「已清帳」只有一個定義：月份 ≤ 最後清帳月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- 上上上月先放一筆 A 的私人支出 400（那時還沒鎖，放得進去）。
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values (current_setting('app.mc_ledger')::uuid, 'expense', 'private', 400,
        current_setting('app.mc_cat')::uuid,
        (current_setting('app.mc_cur')::date - interval '3 month')::date + 6,
        '上上上月私人', current_setting('app.mc_a')::uuid,
        current_setting('app.mc_a')::uuid, 'common');
-- 依序清三個月（首次可清月＝最早帳目月＝上上上月）。
select public.close_month(current_setting('app.mc_ledger')::uuid,
        (current_setting('app.mc_cur')::date - interval '3 month')::date) as _c1 \gset
select public.close_month(current_setting('app.mc_ledger')::uuid,
        current_setting('app.mc_prev2')::date) as _c2 \gset
select public.close_month(current_setting('app.mc_ledger')::uuid,
        current_setting('app.mc_prev')::date) as _c3 \gset
-- 模擬雲端人工救援：有人刪掉了**中間**那一列（不是最後一列）。
-- 這時「有沒有清帳紀錄」與「月份 ≤ 最後清帳月」兩種判準就會分岔——
-- 鎖月 trigger 照樣擋著上上上月（<= max），個人餘額若改用「有沒有那一列」判，
-- 那個月的帳目就會偷偷回到餘額裡，而且改不動（因為被鎖），永遠對不平。
delete from public.month_closes
 where ledger_id = current_setting('app.mc_ledger')::uuid
   and month = (current_setting('app.mc_cur')::date - interval '3 month')::date;
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_cur date := current_setting('app.mc_cur')::date;
  v_prev3 date := (v_cur - interval '3 month')::date;
  v_until date := (v_cur + interval '1 month - 1 day')::date;
  v_me jsonb;
begin
  assert (select count(*) from public.month_closes mc where mc.ledger_id = v_l) = 2,
    '前置條件：中間那列應該已經被刪掉';
  assert not exists (select 1 from public.month_closes mc
                      where mc.ledger_id = v_l and mc.month = v_prev3),
    '前置條件：上上上月不該還有清帳紀錄';

  v_me := public.month_summary(v_l, v_until)->'me';
  -- 最後清帳月＝上月，所以只有本月進得了個人餘額：1 × 補入額 1,000 ＋ 本月淨變動 0。
  -- 上上上月那筆 −400 與上上月的 −2,500 都必須留在線外。
  assert (v_me->>'personal_balance')::bigint = 1000,
    format('個人餘額應只算「> 最後清帳月」的月份（預期 1,000）：%s', v_me->>'personal_balance');

  -- 反面：鎖月 trigger 對上上上月照樣是鎖著的（兩個判準必須是同一把尺的兩面）。
  declare
    v_blocked boolean := false;
    v_err text;
  begin
    begin
      insert into public.entries
        (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
      values (v_l, 'expense', 'private', 100, current_setting('app.mc_cat')::uuid,
              v_prev3 + 9, '想補記', current_setting('app.mc_a')::uuid,
              current_setting('app.mc_a')::uuid, 'common');
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    assert v_blocked, '上上上月沒有清帳紀錄，但它 ≤ 最後清帳月，仍該鎖著';
    assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);
  end;
end;
$$;
rollback;

\echo '== month_close: c11. 已清帳月份鎖定：entries／子表／撥款都擋 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true, p_close_prev2 => true) as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_a uuid := current_setting('app.mc_a')::uuid;
  v_cat uuid := current_setting('app.mc_cat')::uuid;
  v_priv uuid := current_setting('app.mc_priv')::uuid;
  v_cur date := current_setting('app.mc_cur')::date;
  v_prev date := current_setting('app.mc_prev')::date;
  v_prev2 date := current_setting('app.mc_prev2')::date;
  v_open uuid;
  v_blocked boolean;
  v_err text;
begin
  -- ① insert entry 到已清月
  v_blocked := false;
  begin
    insert into public.entries
      (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
    values (v_l, 'expense', 'private', 100, v_cat, v_prev2 + 9, '想補記', v_a, v_a, 'common');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然新增得了帳目';
  assert v_err like format('%%month closed: %s%%', to_char(v_prev2, 'YYYY-MM')),
    format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- ② update 已清月帳目的備註
  v_blocked := false;
  begin
    update public.entries set note = '偷改' where id = v_priv;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然改得動帳目';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  -- ③ delete 已清月帳目
  v_blocked := false;
  begin
    delete from public.entries where id = v_priv;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然刪得掉帳目';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  -- ④ 把未鎖月的帳目日期改進鎖月
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l, 'expense', 'private', 150, v_cat, v_prev + 3, '上月私人', v_a, v_a, 'common')
  returning id into v_open;
  v_blocked := false;
  begin
    update public.entries set occurred_on = v_prev2 + 10 where id = v_open;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能把帳目日期改進已清月';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  -- ⑤ 子表：直接寫已清月帳目的細項／分攤
  v_blocked := false;
  begin
    insert into public.line_items (entry_id, name, amount, sort) values (v_priv, '偷加細項', 10, 0);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然加得了細項';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  v_blocked := false;
  begin
    insert into public.entry_splits (entry_id, member_id, share) values (v_priv, v_a, 1);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然加得了分攤';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  -- ⑥ upsert_entry 改已清月帳目的細項
  v_blocked := false;
  begin
    perform public.upsert_entry(
      jsonb_build_object('id', v_priv, 'ledger_id', v_l, 'note', '改細項'),
      null,
      jsonb_build_array(jsonb_build_object('name', '偷加', 'amount', 10, 'sort', 0)));
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'upsert_entry 竟然改得動已清月的帳目';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  -- ⑦ 撥款到已清月
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
    values (v_l, v_cat, 500, v_prev2 + 1, '補設上上月預算', v_a);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月竟然設得了預算';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);

  -- 對照組：沒清的月份照樣寫得動。
  update public.entries set note = '上月可以改' where id = v_open;
  assert (select e.note from public.entries e where e.id = v_open) = '上月可以改',
    '未清月的帳目應該改得動';
  insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
  values (v_l, v_cat, 500, v_cur + 1, '本月預算', v_a);
end;
$$;
rollback;

\echo '== month_close: c12. month_closes 對前端只讀，非成員看不到 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true, p_close_prev2 => true) as _fx \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_a uuid := current_setting('app.mc_a')::uuid;
  v_prev date := current_setting('app.mc_prev')::date;
  v_id uuid;
  v_blocked boolean;
  v_err text;
begin
  assert (select count(*) from public.month_closes mc where mc.ledger_id = v_l) = 1,
    '成員應讀得到自己帳本的清帳紀錄';
  select mc.id into v_id from public.month_closes mc where mc.ledger_id = v_l;

  v_blocked := false;
  begin
    insert into public.month_closes (ledger_id, month, closed_by, details)
    values (v_l, v_prev, v_a, '{}'::jsonb);
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然直接 insert 得了清帳紀錄';
  assert v_err like '%permission denied%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  v_blocked := false;
  begin
    update public.month_closes set details = '{}'::jsonb where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然改得動清帳紀錄';

  v_blocked := false;
  begin
    delete from public.month_closes where id = v_id;
  exception when insufficient_privilege then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '前端竟然刪得掉清帳紀錄（清帳不可撤銷）';
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_solo public.ledgers;
  v_blocked boolean := false;
  v_err text;
begin
  -- 老婆是這個 fixture 帳本的成員，所以非成員視角要另開一本 Mike 獨有的帳來驗。
  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');
  v_solo := public.create_ledger('Mike 一個人的清帳帳本');
  perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');

  assert (select count(*) from public.month_closes mc where mc.ledger_id = v_solo.id) = 0,
    '非成員不該看得到別人帳本的清帳紀錄';

  begin
    perform public.month_close_preview(v_solo.id, current_setting('app.mc_prev2')::date);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然預覽得了別人帳本的清帳';
  assert v_err like '%not a member%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- close_month 也要自己擋，不能靠「closed_by 填不出來」之類的巧合。
  -- 這條專門守 B.4 開頭那個明文成員檢查：拿掉它就會變成別的錯誤訊息。
  v_blocked := false;
  begin
    perform public.close_month(v_solo.id, current_setting('app.mc_prev2')::date);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然清得了別人帳本的帳';
  assert v_err like '%close_month: not a member%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== month_close: c13. 鎖定範圍是「最後清帳月（含）以前」，不是只鎖有紀錄的那幾個月 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true, p_close_prev2 => true) as _fx \gset
-- 再清一個月：現在 month_closes 有「上上月」與「上月」兩列，最後清帳月＝上月。
select public.close_month(current_setting('app.mc_ledger')::uuid,
                          current_setting('app.mc_prev')::date) as _c2 \gset
set local role authenticated;
do $$
declare
  v_l uuid := current_setting('app.mc_ledger')::uuid;
  v_a uuid := current_setting('app.mc_a')::uuid;
  v_cat uuid := current_setting('app.mc_cat')::uuid;
  v_cur date := current_setting('app.mc_cur')::date;
  v_prev3 date := (current_setting('app.mc_cur')::date - interval '3 month')::date;
  v_open uuid;
  v_blocked boolean;
  v_err text;
begin
  -- 上上上月**沒有**清帳紀錄，但它比最後清帳月更早：補記進去的話永遠不會是「下一個可清月」，
  -- 那筆的影響就永久留在個人餘額裡清不掉。所以也要擋。
  v_blocked := false;
  begin
    insert into public.entries
      (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
    values (v_l, 'expense', 'private', 100, v_cat, v_prev3 + 9, '補記更早的月份', v_a, v_a, 'common');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '比最後清帳月更早的月份竟然補記得進去';
  -- 訊息要帶「被擋的那個月」（自己動到的那筆屬於哪個月），不是最後清帳月。
  assert v_err like format('%%month closed: %s%%', to_char(v_prev3, 'YYYY-MM')),
    format('錯誤訊息應帶被擋的月份 %s，實際：%s', to_char(v_prev3, 'YYYY-MM'), v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 把本月的帳目日期改到上上上月，同樣要擋。
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l, 'expense', 'private', 150, v_cat, v_cur + 2, '本月私人', v_a, v_a, 'common')
  returning id into v_open;
  v_blocked := false;
  begin
    update public.entries set occurred_on = v_prev3 + 5 where id = v_open;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能把帳目日期改到比最後清帳月更早的月份';
  assert v_err like format('%%month closed: %s%%', to_char(v_prev3, 'YYYY-MM')),
    format('錯誤訊息不對：%s', v_err);

  -- 對照組：本月（晚於最後清帳月）照樣寫得動。
  update public.entries set note = '本月可以改' where id = v_open;
  assert (select e.note from public.entries e where e.id = v_open) = '本月可以改',
    '晚於最後清帳月的帳目應該改得動';
end;
$$;
rollback;

\echo '== month_close: c14. 鎖定範圍內的預算連 UPDATE／DELETE 都擋（繞過欄位授權的路徑）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- 先在還沒清帳時設一筆上上月的預算，再清掉那個月。
insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, note, created_by)
values (current_setting('app.mc_ledger')::uuid, current_setting('app.mc_cat')::uuid,
        3000, current_setting('app.mc_prev2')::date + 1, '上上月預算', current_setting('app.mc_a')::uuid);
select public.close_month(current_setting('app.mc_ledger')::uuid,
                          current_setting('app.mc_prev2')::date) as _c \gset
-- 這段刻意**不切 authenticated**：前端本來就沒有 budget_allocation 的 UPDATE／DELETE 授權，
-- 這裡驗的是 service_role／postgres 那條繞過欄位授權的路徑也要被 trigger 擋。
do $$
declare
  v_id uuid;
  v_blocked boolean;
  v_err text;
begin
  select b.id into v_id from public.budget_allocation b
   where b.ledger_id = current_setting('app.mc_ledger')::uuid;

  v_blocked := false;
  begin
    update public.budget_allocation set amount = 9999 where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月的預算竟然改得動';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  v_blocked := false;
  begin
    delete from public.budget_allocation where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已清月的預算竟然刪得掉';
  assert v_err like '%month closed%', format('錯誤訊息不對：%s', v_err);
end;
$$;
rollback;

\echo '== month_close: c15. 每月補入額有上下界（0 ≤ x ≤ 一億）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  -- 上界：個人餘額是「補入額 × 月份數 ＋ Σ淨變動」，沒有上界就能讓乘法在 int 裡溢位。
  v_blocked := false;
  begin
    update public.members set monthly_topup = 100000001
      where id = '20000000-0000-0000-0000-000000000002';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '補入額竟然可以超過一億';
  assert v_err like '%members_monthly_topup_range%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 下界：負數也擋。
  v_blocked := false;
  begin
    update public.members set monthly_topup = -1
      where id = '20000000-0000-0000-0000-000000000002';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '補入額竟然可以是負數';
  assert v_err like '%members_monthly_topup_range%', format('錯誤訊息不對：%s', v_err);

  -- 邊界內可以改。
  update public.members set monthly_topup = 100000000
    where id = '20000000-0000-0000-0000-000000000002';
  assert (select m.monthly_topup from public.members m
           where m.id = '20000000-0000-0000-0000-000000000002') = 100000000,
    '上界值本身應該可以設';
end;
$$;
rollback;

\echo '== month_close: c16. month_close_details 必須是 security definer（B 也要算得出 A 的私人淨額）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_p jsonb;
  v_ra jsonb;
begin
  -- A 的淨變動裡有 2,000 的**私人**支出，而私人筆的 RLS 只有 A 自己看得到。
  -- 由 B 呼叫時仍要算得出 A 的 −2,500／−1,500——這只有 security definer 才成立。
  -- 把 month_close_details 改成 security invoker，這條會變成 −500／+500。
  v_p := public.month_close_preview(current_setting('app.mc_ledger')::uuid,
                                    current_setting('app.mc_prev2')::date);
  select m into v_ra from jsonb_array_elements(v_p->'members') m
   where (m->>'member_id')::uuid = current_setting('app.mc_a')::uuid;
  assert (v_ra->>'net')::int = -2500,
    format('B 看到的 A net 應含 A 的私人支出（−2,500）：%s', v_ra);
  assert (v_ra->>'ending')::int = -1500, format('B 看到的 A ending 不對：%s', v_ra);
end;
$$;
rollback;

\echo '== month_close: c17. 已結算份額用最大餘數法取整（合計恰等於主筆金額）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
-- 兩人均分 567：283.50／283.50。逐筆 round() 兩邊都會變 284，合計 568 ≠ 567（憑空多一元）。
-- 最大餘數法：兩邊 floor 成 283（合計 566），餘 1 由「小數大者優先、同小數比 member_id」補給一個人。
do $$
declare
  v_l public.ledgers;
  v_a uuid;
  v_b uuid;
  v_cat uuid;
  v_e uuid;
  v_s public.settlements;
begin
  v_l := public.create_ledger('取整測試帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;
  perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');
  perform public.join_ledger(v_l.invite_code);
  select m.id into v_b from public.members m where m.ledger_id = v_l.id and m.id <> v_a;
  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');

  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;

  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'shared', 567, v_cat, current_date, '567 均分', v_a, v_a, 'equal')
  returning id into v_e;
  insert into public.entry_splits (entry_id, member_id, share) values
    (v_e, v_a, 283.50), (v_e, v_b, 283.50);

  -- 走真正的結算路徑：只有 settled 的筆才會落到「各扛自己份額」那一段。
  v_s := public.initiate_settlement(v_l.id);
  perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');
  perform public.approve_settlement(v_s.id);
  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');
  assert (select e.settled_state from public.entries e where e.id = v_e) = 'settled',
    '前置條件：那筆應該已經 settled';

  perform set_config('app.mc_e567', v_e::text, true);
  perform set_config('app.mc_r_a', v_a::text, true);
  perform set_config('app.mc_r_b', v_b::text, true);
end;
$$;
do $$
declare
  v_e uuid := current_setting('app.mc_e567')::uuid;
  v_lo uuid := least(current_setting('app.mc_r_a')::uuid, current_setting('app.mc_r_b')::uuid);
  v_hi uuid := greatest(current_setting('app.mc_r_a')::uuid, current_setting('app.mc_r_b')::uuid);
  v_sum bigint;
begin
  select sum(ef.delta) into v_sum from public.entry_member_effects ef where ef.entry_id = v_e;
  assert v_sum = -567, format('整數份額合計必須恰等於主筆金額，實際 %s', -v_sum);
  -- 小數完全並列（都是 .50）→ 由 member_id 決定誰扛那多出來的一元，結果必須穩定可預期。
  assert (select ef.delta from public.entry_member_effects ef
           where ef.entry_id = v_e and ef.member_id = v_lo) = -284,
    'member_id 較小的那位應該扛 284';
  assert (select ef.delta from public.entry_member_effects ef
           where ef.entry_id = v_e and ef.member_id = v_hi) = -283,
    'member_id 較大的那位應該扛 283';
end;
$$;
rollback;

\echo '== month_close: c18. 三人 100 元 → 34／33／33，多的那一元落在小數最大者 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
-- 造第三個使用者（欄位寫法照 seed.sql；整段包在 rollback 裡）。
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change, phone_change, phone_change_token, reauthentication_token
) values
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333',
   'authenticated', 'authenticated', 'third@test.local',
   extensions.crypt('password', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"老三"}'::jsonb, now(), now(),
   '', '', '', '', '', '', '', '');
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_cat uuid;
  v_e uuid;
  v_s public.settlements;
begin
  v_l := public.create_ledger('三人取整測試帳本');
  select m.id into v_a from public.members m where m.ledger_id = v_l.id;
  perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');
  perform public.join_ledger(v_l.invite_code);
  perform pg_temp.mc_claims('33333333-3333-3333-3333-333333333333');
  perform public.join_ledger(v_l.invite_code);
  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');
  select m.id into v_b from public.members m
   where m.ledger_id = v_l.id and m.user_id = '22222222-2222-2222-2222-222222222222';
  select m.id into v_c from public.members m
   where m.ledger_id = v_l.id and m.user_id = '33333333-3333-3333-3333-333333333333';

  select c.id into v_cat from public.categories c
   where c.ledger_id = v_l.id and c.kind = 'expense' order by c.sort limit 1;

  -- 100 元三人分：33.34／33.33／33.33（numeric(12,2) 分不乾淨，前端就是這樣存的）。
  insert into public.entries
    (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
  values (v_l.id, 'expense', 'shared', 100, v_cat, current_date, '100 三人分', v_a, v_a, 'equal')
  returning id into v_e;
  insert into public.entry_splits (entry_id, member_id, share) values
    (v_e, v_a, 33.34), (v_e, v_b, 33.33), (v_e, v_c, 33.33);

  v_s := public.initiate_settlement(v_l.id);
  perform pg_temp.mc_claims('22222222-2222-2222-2222-222222222222');
  perform public.approve_settlement(v_s.id);
  perform pg_temp.mc_claims('33333333-3333-3333-3333-333333333333');
  perform public.approve_settlement(v_s.id);
  perform pg_temp.mc_claims('11111111-1111-1111-1111-111111111111');
  assert (select e.settled_state from public.entries e where e.id = v_e) = 'settled',
    '前置條件：那筆應該已經 settled';

  perform set_config('app.mc_e100', v_e::text, true);
  perform set_config('app.mc_r_a', v_a::text, true);
end;
$$;
do $$
declare
  v_e uuid := current_setting('app.mc_e100')::uuid;
  v_a uuid := current_setting('app.mc_r_a')::uuid;
  v_sum bigint;
begin
  select sum(ef.delta) into v_sum from public.entry_member_effects ef where ef.entry_id = v_e;
  assert v_sum = -100, format('三人份額合計應為 100，實際 %s', -v_sum);
  -- 小數最大者（.34）扛多出來的那一元。
  assert (select ef.delta from public.entry_member_effects ef
           where ef.entry_id = v_e and ef.member_id = v_a) = -34,
    '小數最大（33.34）的那位應該扛 34';
  assert (select count(*) from public.entry_member_effects ef
           where ef.entry_id = v_e and ef.delta = -33) = 2,
    '另外兩位應該都是 33';
end;
$$;
rollback;

\echo '== month_close: c19. 子表鎖月 trigger 直測：只碰 line_items／entry_splits，完全不動主筆 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- 先在還沒清帳時放一筆細項與一筆分攤（清帳後就加不進去了），再清掉那個月。
-- 分攤掛在那筆**私人**帳目上：私人筆不進結算，parent 會一直是 open，
-- 這樣「刪分攤」才走得到鎖月 trigger——已 settled 的 parent 其分攤會先被
-- entry_splits_delete policy（qual 含 settled_state <> 'settled'）濾成 0 列而靜默 no-op。
insert into public.line_items (entry_id, name, amount, sort)
values (current_setting('app.mc_priv')::uuid, '清帳前就有的細項', 50, 0);
insert into public.entry_splits (entry_id, member_id, share)
values (current_setting('app.mc_priv')::uuid, current_setting('app.mc_a')::uuid, 1);
select public.close_month(current_setting('app.mc_ledger')::uuid,
                          current_setting('app.mc_prev2')::date) as _c \gset
set local role authenticated;
do $$
declare
  v_priv uuid := current_setting('app.mc_priv')::uuid;
  v_adv uuid := current_setting('app.mc_adv')::uuid;
  v_a uuid := current_setting('app.mc_a')::uuid;
  v_b uuid := current_setting('app.mc_b')::uuid;
  v_li uuid;
  v_note_before text;
  v_blocked boolean;
  v_err text;
begin
  -- 這一整段**沒有任何一句 update／delete 打在 entries 上**，所以擋下來的一定是子表自己的
  -- a_entry_splits_month_closed_trg／a_line_items_month_closed_trg，不是主筆那支。
  select e.note into v_note_before from public.entries e where e.id = v_priv;
  select li.id into v_li from public.line_items li where li.entry_id = v_priv;

  -- line_items：insert／update／delete 各一條
  v_blocked := false;
  begin
    insert into public.line_items (entry_id, name, amount, sort) values (v_priv, '偷加', 10, 1);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已鎖月的帳目竟然加得了細項';
  assert v_err like '%month closed%', format('細項 insert 的錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗（line_items insert）：%', v_err;

  v_blocked := false;
  begin
    update public.line_items set name = '偷改' where id = v_li;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已鎖月的帳目竟然改得動細項';
  assert v_err like '%month closed%', format('細項 update 的錯誤訊息不對：%s', v_err);

  v_blocked := false;
  begin
    delete from public.line_items where id = v_li;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已鎖月的帳目竟然刪得掉細項';
  assert v_err like '%month closed%', format('細項 delete 的錯誤訊息不對：%s', v_err);

  -- entry_splits：insert／update／delete 各一條（掛在私人筆上，parent 仍是 open）
  v_blocked := false;
  begin
    insert into public.entry_splits (entry_id, member_id, share) values (v_priv, v_b, 1);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已鎖月的帳目竟然加得了分攤';
  assert v_err like '%month closed%', format('分攤 insert 的錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗（entry_splits insert）：%', v_err;

  v_blocked := false;
  begin
    update public.entry_splits set share = 99 where entry_id = v_priv and member_id = v_a;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已鎖月的帳目竟然改得動分攤';
  assert v_err like '%month closed%', format('分攤 update 的錯誤訊息不對：%s', v_err);

  v_blocked := false;
  begin
    delete from public.entry_splits where entry_id = v_priv and member_id = v_a;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已鎖月的帳目竟然刪得掉分攤';
  assert v_err like '%month closed%', format('分攤 delete 的錯誤訊息不對：%s', v_err);

  -- 順帶驗鎖月排在 settled 鎖之前：已結算代墊的分攤改 share，訊息要是 month closed
  -- 而不是 entry settled: split locked（兩支 trigger 都會擋，字母序決定誰先開口）。
  v_blocked := false;
  begin
    update public.entry_splits set share = 1 where entry_id = v_adv and member_id = v_a;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已結算又已鎖月的分攤竟然改得動';
  assert v_err like '%month closed%', format('應先被鎖月擋下，實際：%s', v_err);

  -- 主筆自始至終沒被碰過（證明上面擋下來的都是子表那兩支）。
  assert (select e.note from public.entries e where e.id = v_priv) = v_note_before,
    '主筆不該被這段動到';
  assert (select count(*) from public.line_items li where li.entry_id = v_priv) = 1,
    '清帳前放的那筆細項應該還在';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_priv) = 1,
    '清帳前放的那筆分攤應該還在';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_adv) = 2,
    '代墊的兩筆分攤應該都還在';
end;
$$;
rollback;

\echo '== month_close: c20. 鎖月 trigger 的執行順序排在 entries 的 delete trigger 之前 =='
do $$
declare
  v_first text;
begin
  -- trigger 依名稱字母序執行。entries 的 before delete 還有 0010 的 void trigger，
  -- 那支會把 pending 結算標 void——鎖月檢查排在它後面的話，
  -- 「應該被擋下來的刪除」會先把別人的結算作廢一次。
  select t.tgname into v_first
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'entries'
    and not t.tgisinternal
    and (t.tgtype & 8) <> 0      -- DELETE
    and (t.tgtype & 2) <> 0      -- BEFORE
  order by t.tgname
  limit 1;
  assert v_first = 'a_entries_month_closed_trg',
    format('entries 的 before delete 第一支 trigger 應是鎖月檢查，實際 %s', v_first);
end;
$$;

\echo '== month_close: c21. 淨變動越過 int 上界時，預覽要算得出來而不是炸掉 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
select pg_temp.mc_fixture(p_settle => true) as _fx \gset
-- entries.amount 是 int（單筆上限約 21.4 億），但**一個月加起來**輕鬆就能越過。
-- 兩筆 11 億的私人支出：合計 22 億 > int 上界 2,147,483,647。
insert into public.entries
  (ledger_id, kind, scope, amount, category_id, occurred_on, note, created_by, payer_id, split_method)
values
  (current_setting('app.mc_ledger')::uuid, 'expense', 'private', 1100000000,
   current_setting('app.mc_cat')::uuid, current_setting('app.mc_prev2')::date + 10,
   '大額一', current_setting('app.mc_a')::uuid, current_setting('app.mc_a')::uuid, 'common'),
  (current_setting('app.mc_ledger')::uuid, 'expense', 'private', 1100000000,
   current_setting('app.mc_cat')::uuid, current_setting('app.mc_prev2')::date + 11,
   '大額二', current_setting('app.mc_a')::uuid, current_setting('app.mc_a')::uuid, 'common');
set local role authenticated;
do $$
declare
  v_p jsonb;
  v_ra jsonb;
begin
  -- 清帳不可撤銷，最不該在這裡因為型別炸掉；改回 ::int 這段會是 integer out of range。
  v_p := public.month_close_preview(current_setting('app.mc_ledger')::uuid,
                                    current_setting('app.mc_prev2')::date);
  select m into v_ra from jsonb_array_elements(v_p->'members') m
   where (m->>'member_id')::uuid = current_setting('app.mc_a')::uuid;

  -- 原本的 −2,500 再加上兩筆 11 億。
  assert (v_ra->>'net')::bigint = -2500 - 2200000000,
    format('A net 應為 −2,200,002,500：%s', v_ra->>'net');
  assert (v_ra->>'ending')::bigint = 1000 - 2500 - 2200000000,
    format('A ending 應為 −2,200,001,500：%s', v_ra->>'ending');

  -- month_summary 這一側也要撐得住。
  assert (public.month_summary(current_setting('app.mc_ledger')::uuid,
            (current_setting('app.mc_cur')::date + interval '1 month - 1 day')::date)
          ->'me'->>'personal_balance')::bigint = 3 * 1000 - 2500 - 2200000000,
    'month_summary 的個人餘額也要算得出來';
end;
$$;
rollback;

\echo 'month_close.sql PASS'
