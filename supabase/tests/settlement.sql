-- 結算多簽 / 鎖定 / void 測試（ADR-0002）。
-- 種子可結算的 entry（shared + expense + open + payer 非 null + split <> common）：
--   Mike 付 567 + 1520 = 2087，老婆付 1280 + 420 + 680 = 2380
--   兩人各分攤 283.50+640+760+210+340 = 2233.50
--   兩人精確淨額：Mike -146.5、老婆 +146.5
--   最大餘數法（review 20）：全員先 floor（-147 / 146，Σ=-1），差額 1 依小數部分由大到小補；
--   兩人小數同為 .5，以 member_id 決定順序 → Mike 拿到那 1 → nets = {Mike -146, 老婆 +146}，Σ=0。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set WIFE_M '20000000-0000-0000-0000-000000000002'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set E_BUYFOOD '40000000-0000-0000-0000-000000000005'

\echo '== settlement: 發起 → 淨額、涵蓋範圍、required signers =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
  v_signers uuid[];
  v_blocked boolean := false;
  v_err text;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');

  assert v_s.status = 'pending', format('新結算應為 pending，實際 %s', v_s.status);
  assert v_s.initiated_by = '20000000-0000-0000-0000-000000000001'::uuid, 'initiated_by 不是發起人';
  assert (v_s.nets ->> '20000000-0000-0000-0000-000000000001')::int = -146,
    format('Mike 淨額應為 -146，實際 %s', v_s.nets ->> '20000000-0000-0000-0000-000000000001');
  assert (v_s.nets ->> '20000000-0000-0000-0000-000000000002')::int = 146,
    format('老婆淨額應為 146，實際 %s', v_s.nets ->> '20000000-0000-0000-0000-000000000002');
  assert (select coalesce(sum(kv.value::int), 0) from jsonb_each_text(v_s.nets) kv) = 0,
    'Σnets 必須恰好為 0（最大餘數法）';

  assert (select count(*) from public.settlement_entries se where se.settlement_id = v_s.id) = 5,
    '涵蓋的 entry 應為 5 筆代墊支出';
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 5,
    '涵蓋的 entry 應全部轉為 settling';
  -- 共同錢包 / common 的支出不入結算。
  assert (select settled_state from public.entries e where e.id = '40000000-0000-0000-0000-000000000003') = 'open',
    '共同錢包支出不該進結算';

  select array_agg(rs) into v_signers from public.required_signers(v_s.id) rs;
  assert v_signers = array['20000000-0000-0000-0000-000000000002'::uuid],
    format('需簽者應只有老婆（發起人自動視為已簽），實際 %s', v_signers);

  -- 應失敗①：發起人不是需簽者，不能自己簽。
  begin
    perform public.approve_settlement(v_s.id);
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '發起人竟然能簽自己發起的結算';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：已有 pending 時不能再發起。
  v_blocked := false;
  begin
    perform public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能同時開兩個 pending 結算';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== settlement: settling 期間改金額 → settlement void、entries 回 open =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 5, '應有 5 筆 settling';

  update public.entries set amount = 600 where id = '40000000-0000-0000-0000-000000000005';

  assert (select status from public.settlements s where s.id = v_s.id) = 'void',
    format('settling 期間改金額後 settlement 應為 void，實際 %s', (select status from public.settlements s where s.id = v_s.id));
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 0,
    '被 void 後涵蓋的 entry 應全部回 open';
  assert (select count(*) from public.entries e
          join public.settlement_entries se on se.entry_id = e.id
          where se.settlement_id = v_s.id and e.settled_state = 'open') = 5,
    '涵蓋的 5 筆應回到 open';
end;
$$;
rollback;

\echo '== settlement: settling 期間改分攤 → 一樣 void =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  update public.entry_splits set share = 300.00
    where entry_id = '40000000-0000-0000-0000-000000000005'
      and member_id = '20000000-0000-0000-0000-000000000001';
  assert (select status from public.settlements s where s.id = v_s.id) = 'void',
    'settling 期間改 entry_splits 後 settlement 應為 void';
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 0,
    '被 void 後涵蓋的 entry 應全部回 open';
end;
$$;
rollback;

\echo '== settlement: settling 期間只改備註／分類 → 不 void（trigger 欄位限定） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  -- void trigger 只監看 amount / payer_id / split_method / scope / kind，
  -- 備註、分類、細項屬於「不影響金額分配」的欄位，改了不該打斷結算。
  update public.entries set note = '補個備註', category_id = '30000000-0000-0000-0000-000000000002'
    where id = '40000000-0000-0000-0000-000000000005';
  insert into public.line_items (entry_id, name, amount) values ('40000000-0000-0000-0000-000000000005', '蔥', 20);
  assert (select status from public.settlements s where s.id = v_s.id) = 'pending',
    format('只改備註不該 void，實際 %s', (select status from public.settlements s where s.id = v_s.id));
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 5,
    '只改備註後涵蓋的 entry 應仍在 settling';
end;
$$;
rollback;

\echo '== settlement: 整列 update 但值不變 → 不 void（trigger 比值不比有沒有被寫） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');

  -- 模擬 PostgREST／supabase_flutter 的整列 update：所有**可寫**欄位都進 SET，
  -- 但金額相關欄位的值沒變，只有 note 真的改了。
  -- 注意 ledger_id／created_by／settled_state 不在欄位級授權清單裡（review 3），
  -- 前端整列送回時必須先把這三欄剔除，否則會是 permission denied。
  update public.entries set
      kind          = kind,
      scope         = scope,
      amount        = amount,
      category_id   = category_id,
      occurred_on   = occurred_on,
      note          = '整列送回來的備註',
      payer_id      = payer_id,
      split_method  = split_method,
      is_adjustment = is_adjustment
    where id = '40000000-0000-0000-0000-000000000005';

  assert (select status from public.settlements s where s.id = v_s.id) = 'pending',
    format('整列 update 但值不變不該 void，實際 %s', (select status from public.settlements s where s.id = v_s.id));
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 5,
    '整列 update 後涵蓋的 entry 應仍在 settling';
  assert (select note from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = '整列送回來的備註',
    '備註應該有改到';

  -- 反面：把不可寫欄位也塞進 SET（即使值不變）會被欄位級授權擋掉。
  declare
    v_blocked boolean := false;
    v_err text;
  begin
    begin
      update public.entries set note = note, created_by = created_by
        where id = '40000000-0000-0000-0000-000000000005';
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    assert v_blocked, '整列送回 created_by 竟然沒被擋';
    raise notice '  預期的失敗（前端整列 update 要剔除 created_by／ledger_id／settled_state）：%', v_err;
  end;

  -- entry_splits 同理：整列送回、值沒變 → 不 void。
  update public.entry_splits set entry_id = entry_id, member_id = member_id, share = share
    where entry_id = '40000000-0000-0000-0000-000000000005';
  assert (select status from public.settlements s where s.id = v_s.id) = 'pending',
    '整列 update entry_splits 但值不變不該 void';

  -- 值真的變了才 void。
  update public.entries set amount = amount + 1 where id = '40000000-0000-0000-0000-000000000005';
  assert (select status from public.settlements s where s.id = v_s.id) = 'void',
    '金額真的變了就該 void';
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 0,
    'void 後涵蓋的 entry 應全部回 open';
end;
$$;
rollback;

\echo '== settlement: settling 期間改分攤金額（值真的變）→ void =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  update public.entry_splits set share = share + 1
    where entry_id = '40000000-0000-0000-0000-000000000005'
      and member_id = '20000000-0000-0000-0000-000000000001';
  assert (select status from public.settlements s where s.id = v_s.id) = 'void',
    '分攤金額真的變了就該 void';
end;
$$;
rollback;

\echo '== settlement: mike 發起 → 老婆簽 → settled；之後改金額被鎖 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  assert v_s.status = 'pending', '發起後應為 pending';
end;
$$;

-- 換成老婆
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid;
  v_s public.settlements;
  v_blocked boolean := false;
  v_err text;
begin
  select s.id into v_id from public.settlements s
   where s.ledger_id = '10000000-0000-0000-0000-000000000001' and s.status = 'pending';
  assert v_id is not null, '老婆應看得到待簽的結算';

  -- 應失敗①：不能代簽別人（RLS 只允許插自己的 member_id）。
  begin
    insert into public.settlement_approvals (settlement_id, member_id)
    values (v_id, '20000000-0000-0000-0000-000000000001');
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '老婆竟然能代 mike 簽名';
  raise notice '  預期的失敗：%', v_err;

  v_s := public.approve_settlement(v_id);
  -- 落地路徑只改 settled_state，不得反過來觸發 void trigger 把自己作廢。
  assert v_s.status <> 'void', '多簽落地竟然把自己 void 掉了（trigger 自撞）';
  assert v_s.status = 'settled', format('簽完應為 settled，實際 %s', v_s.status);
  assert v_s.settled_at is not null, 'settled_at 應有值';
  assert (select count(*) from public.entries e
          join public.settlement_entries se on se.entry_id = e.id
          where se.settlement_id = v_id and e.settled_state = 'settled') = 5,
    '涵蓋的 5 筆應轉 settled';
  assert (select count(*) from public.settlement_approvals a where a.settlement_id = v_id) = 1,
    '應只有老婆一筆簽名（發起人不入 approvals）';
end;
$$;

-- 換回 mike，驗鎖定
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 應失敗②：settled 後金額鎖住。
  begin
    update public.entries set amount = 999 where id = '40000000-0000-0000-0000-000000000005';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settled 的 entry 金額竟然改得動';
  assert v_err like '%entry settled%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗③：settled 後 payer / split_method 一樣鎖住。
  v_blocked := false;
  begin
    update public.entries set split_method = 'ratio' where id = '40000000-0000-0000-0000-000000000005';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settled 的 entry split_method 竟然改得動';

  -- 應失敗④：settled 後分攤金額也鎖住。
  v_blocked := false;
  begin
    update public.entry_splits set share = 1.00 where entry_id = '40000000-0000-0000-0000-000000000005';
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settled 的 entry_splits 竟然改得動';
  raise notice '  預期的失敗：%', v_err;

  -- 可以改的：分類、備註、細項（ADR-0002）。
  update public.entries set note = '全聯買菜（補註）', category_id = '30000000-0000-0000-0000-000000000002'
    where id = '40000000-0000-0000-0000-000000000005';
  assert (select note from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = '全聯買菜（補註）',
    'settled 後備註應可改';
  insert into public.line_items (entry_id, name, amount) values ('40000000-0000-0000-0000-000000000005', '補記蔥', 20);
  assert exists (select 1 from public.line_items li where li.entry_id = '40000000-0000-0000-0000-000000000005' and li.name = '補記蔥'),
    'settled 後細項應可新增';
end;
$$;
rollback;

\echo '== settlement: 需簽者名單是快照，竄改 nets 無法繞過多簽（應失敗，review 2）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
  v_blocked boolean;
  v_err text;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  assert (select count(*) from public.settlement_signers ss where ss.settlement_id = v_s.id) = 1,
    '需簽者應快照成 1 位（老婆）';

  -- 應失敗①：發起人改不動 nets（修前可把老婆淨額改成 0，需簽者名單當場變空）。
  v_blocked := false;
  begin
    update public.settlements
       set nets = jsonb_set(nets, '{20000000-0000-0000-0000-000000000002}', '0'::jsonb)
     where id = v_s.id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '發起人竟然改得動 nets';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：自己插一筆簽名想觸發 finalize（快照名單裡沒有發起人）。
  v_blocked := false;
  begin
    insert into public.settlement_approvals (settlement_id, member_id)
    values (v_s.id, '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '發起人竟然能自己簽自己發起的結算';
  raise notice '  預期的失敗：%', v_err;

  assert (select status from public.settlements s where s.id = v_s.id) = 'pending',
    '老婆還沒簽，結算不該落地';
end;
$$;
rollback;

\echo '== settlement: 結算狀態機（終態不可改，review 3）=='
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
-- 用 postgres 身分測 trigger 本身（證明擋的是狀態機，不只是權限）。
reset role;
do $$
declare
  v_id uuid := current_setting('app.test_settlement', true)::uuid;
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：pending → pending 以外的非法狀態（enum 只有三個值，這裡測終態）。
  update public.settlements set status = 'void' where id = v_id;
  v_blocked := false;
  begin
    update public.settlements set status = 'settled' where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'void 之後竟然還能改回 settled';
  assert v_err like '%status void is final%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：nets／initiated_by／ledger_id 不可變。
  v_blocked := false;
  begin
    update public.settlements set nets = '{}'::jsonb where id = v_id;
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'nets 竟然改得動';
  assert v_err like '%nets is immutable%', format('錯誤訊息不對：%s', v_err);
end;
$$;
rollback;

\echo '== settlement: 刪掉 settling 的 entry → settlement void、其餘回 open（review 4）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 5, '應有 5 筆 settling';

  delete from public.entries where id = '40000000-0000-0000-0000-000000000005';

  assert (select status from public.settlements s where s.id = v_s.id) = 'void',
    format('刪掉 settling 的 entry 後 settlement 應為 void，實際 %s',
           (select status from public.settlements s where s.id = v_s.id));
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 0,
    '其餘 entries 應全部回 open，不能卡在 settling';
  assert (select count(*) from public.entries e where e.settled_state = 'open'
            and e.id in (select se.entry_id from public.settlement_entries se where se.settlement_id = v_s.id)) = 4,
    '剩下 4 筆涵蓋 entry 應回 open';
  assert not exists (select 1 from public.entries e where e.id = '40000000-0000-0000-0000-000000000005'),
    '那筆 entry 應該真的被刪掉了';
end;
$$;
rollback;

\echo '== settlement: settled 的 entry 不可刪、分攤不可刪（應失敗，review 5）=='
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
begin
  perform public.approve_settlement(current_setting('app.test_settlement', true)::uuid);
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
-- 第一道：delete policy（review 15）。RLS 過濾掉該列 → 影響 0 列，不會 raise。
do $$
declare
  v_rows int;
begin
  assert (select settled_state from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = 'settled',
    '前置條件：該筆應已 settled';

  delete from public.entries where id = '40000000-0000-0000-0000-000000000005';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, 'settled 的 entry 竟然刪得掉（delete policy 沒擋住）';
  assert exists (select 1 from public.entries e where e.id = '40000000-0000-0000-0000-000000000005'),
    'settled 的 entry 應該還在';

  delete from public.entry_splits where entry_id = '40000000-0000-0000-0000-000000000005';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, 'settled 的 entry_splits 竟然刪得掉（delete policy 沒擋住）';
  assert (select count(*) from public.entry_splits s where s.entry_id = '40000000-0000-0000-0000-000000000005') = 2,
    'settled 的分攤應該還在';
end;
$$;

-- 第二道：before delete trigger。用 postgres 身分繞過 RLS，證明 policy 之外還有 trigger。
reset role;
do $$
declare
  v_blocked boolean;
  v_err text;
begin
  v_blocked := false;
  begin
    delete from public.entries where id = '40000000-0000-0000-0000-000000000005';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settled 的 entry 竟然刪得掉（trigger 沒擋住）';
  assert v_err like '%entry settled: delete blocked%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗（trigger 層）：%', v_err;

  v_blocked := false;
  begin
    delete from public.entry_splits where entry_id = '40000000-0000-0000-0000-000000000005';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settled 的 entry_splits 竟然刪得掉（trigger 沒擋住）';
  assert v_err like '%split locked%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗（trigger 層）：%', v_err;
end;
$$;
rollback;

\echo '== settlement: 未結帳的 entry 連分攤一起刪得掉（cascade 不被誤擋）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  delete from public.entries where id = '40000000-0000-0000-0000-000000000005';
  assert not exists (select 1 from public.entries e where e.id = '40000000-0000-0000-0000-000000000005'),
    'open 的 entry 應該刪得掉';
  assert not exists (select 1 from public.entry_splits s where s.entry_id = '40000000-0000-0000-0000-000000000005'),
    '分攤應隨 cascade 一起刪掉';
end;
$$;
rollback;

\echo '== settlement: 沒有分攤列的代墊不納入結算、分攤加總不符要 raise（review 6）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
  v_sum bigint;
begin
  -- 一筆 equal 但完全沒有 entry_splits 的代墊：修前會整筆算進「付出」卻沒人分攤，Σnets 直接爆掉。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 10000,
          '30000000-0000-0000-0000-000000000001', current_date, '沒有分攤的代墊',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'equal');

  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  assert (select count(*) from public.settlement_entries se where se.settlement_id = v_s.id) = 5,
    format('沒有分攤列的那筆不該納入，涵蓋數應為 5，實際 %s',
           (select count(*) from public.settlement_entries se where se.settlement_id = v_s.id));

  select coalesce(sum(kv.value::int), 0) into v_sum from jsonb_each_text(v_s.nets) kv;
  assert v_sum = 0, format('Σnets 應守恆為 0，實際 %s', v_sum);
end;
$$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_entry uuid;
  v_blocked boolean := false;
  v_err text;
begin
  -- 分攤加總與主筆金額不符（1000 vs 100+100）→ 發起時就該 raise，不能算出歪掉的淨額。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 1000,
          '30000000-0000-0000-0000-000000000001', current_date, '分攤湊不齊',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'amount')
  returning id into v_entry;
  insert into public.entry_splits (entry_id, member_id, share) values
    (v_entry, '20000000-0000-0000-0000-000000000001', 100.00),
    (v_entry, '20000000-0000-0000-0000-000000000002', 100.00);

  begin
    perform public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '分攤加總不符竟然還能發起結算';
  assert v_err like '%splits do not sum to amount%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== settlement: cancel_settlement 取消結算（review 1）=='
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
-- 非成員不能取消
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  begin
    perform public.cancel_settlement(current_setting('app.test_settlement', true)::uuid);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然能取消別人的結算';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
-- 需簽者（老婆）可以取消
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_id uuid := current_setting('app.test_settlement', true)::uuid;
  v_s public.settlements;
  v_blocked boolean := false;
  v_err text;
begin
  v_s := public.cancel_settlement(v_id);
  assert v_s.status = 'void', format('取消後應為 void，實際 %s', v_s.status);
  assert (select count(*) from public.entries e where e.settled_state = 'settling') = 0,
    '取消後涵蓋的 entries 應全部回 open';
  assert (select count(*) from public.entries e
          join public.settlement_entries se on se.entry_id = e.id
          where se.settlement_id = v_id and e.settled_state = 'open') = 5,
    '5 筆涵蓋 entry 應回 open';

  -- 應失敗：已經 void 的結算不能再取消。
  begin
    perform public.cancel_settlement(v_id);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'void 的結算竟然還能再取消一次';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== settlement: 三人帳本的淨額用最大餘數法，Σnets 恰好為 0（review 20）=='
begin;
-- 以 postgres 身分把三人帳本佈好（種子只有兩個使用者）。
do $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
    email_change, phone_change, phone_change_token, reauthentication_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         extensions.crypt('password', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}'::jsonb,
         jsonb_build_object('full_name', u.nm), now(), now(),
         '', '', '', '', '', '', '', ''
  from (values
    ('aaaaaaaa-0000-0000-0000-000000000000'::uuid, 'a@test.local', 'A'),
    ('bbbbbbbb-0000-0000-0000-000000000000'::uuid, 'b@test.local', 'B'),
    ('cccccccc-0000-0000-0000-000000000000'::uuid, 'c@test.local', 'C')
  ) as u(id, email, nm);

  insert into public.ledgers (id, name, invite_code, default_ratio)
  values ('aaaa0000-0000-0000-0000-00000000000f', '三人帳本', 'TRIOTEST01', '{}'::jsonb);

  insert into public.members (id, ledger_id, user_id, display_name) values
    ('aaaa1111-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-00000000000f', 'aaaaaaaa-0000-0000-0000-000000000000', 'A'),
    ('bbbb1111-0000-0000-0000-000000000002', 'aaaa0000-0000-0000-0000-00000000000f', 'bbbbbbbb-0000-0000-0000-000000000000', 'B'),
    ('cccc1111-0000-0000-0000-000000000003', 'aaaa0000-0000-0000-0000-00000000000f', 'cccccccc-0000-0000-0000-000000000000', 'C');

  insert into public.categories (id, ledger_id, kind, name, icon, sort)
  values ('aaaa2222-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-00000000000f', 'expense', '食品', 'restaurant', 0);

  -- A 代墊 19 元，B、C 各分攤 9.5，A 分攤 0。
  -- 精確淨額：A +19、B -9.5、C -9.5 → 舊的 round() 會得到 19/-10/-10，Σ = -1。
  insert into public.entries (id, ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('aaaa3333-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-00000000000f',
          'expense', 'shared', 19, 'aaaa2222-0000-0000-0000-000000000001', current_date, '三人分帳',
          'aaaa1111-0000-0000-0000-000000000001', 'aaaa1111-0000-0000-0000-000000000001', 'amount');
  insert into public.entry_splits (entry_id, member_id, share) values
    ('aaaa3333-0000-0000-0000-000000000001', 'aaaa1111-0000-0000-0000-000000000001', 0.00),
    ('aaaa3333-0000-0000-0000-000000000001', 'bbbb1111-0000-0000-0000-000000000002', 9.50),
    ('aaaa3333-0000-0000-0000-000000000001', 'cccc1111-0000-0000-0000-000000000003', 9.50);
end;
$$;

select set_config('request.jwt.claims', json_build_object('sub', 'aaaaaaaa-0000-0000-0000-000000000000', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
  v_sum bigint;
begin
  v_s := public.initiate_settlement('aaaa0000-0000-0000-0000-00000000000f');
  select coalesce(sum(kv.value::int), 0) into v_sum from jsonb_each_text(v_s.nets) kv;
  assert v_sum = 0, format('三人帳本的 Σnets 必須恰好為 0（舊的 round() 會是 -1），實際 %s；nets=%s', v_sum, v_s.nets);
  assert (v_s.nets ->> 'aaaa1111-0000-0000-0000-000000000001')::int = 19,
    format('A 應為 +19，實際 %s', v_s.nets ->> 'aaaa1111-0000-0000-0000-000000000001');
  -- B、C 精確都是 -9.5，最大餘數法的那 1 元依 member_id 順序給 B。
  assert (v_s.nets ->> 'bbbb1111-0000-0000-0000-000000000002')::int = -9,
    format('B 應為 -9（拿到餘數），實際 %s', v_s.nets ->> 'bbbb1111-0000-0000-0000-000000000002');
  assert (v_s.nets ->> 'cccc1111-0000-0000-0000-000000000003')::int = -10,
    format('C 應為 -10，實際 %s', v_s.nets ->> 'cccc1111-0000-0000-0000-000000000003');
  assert (select count(*) from public.settlement_signers ss where ss.settlement_id = v_s.id) = 2,
    '需簽者應為 B、C 兩位';
end;
$$;
rollback;

\echo '== settlement: 已結帳鎖 occurred_on、settling 期間改日期會 void（review 21）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_s public.settlements;
begin
  v_s := public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  -- settling 期間改日期＝改月份歸屬，必須打掉重算。
  update public.entries set occurred_on = occurred_on - 40
    where id = '40000000-0000-0000-0000-000000000005';
  assert (select status from public.settlements s where s.id = v_s.id) = 'void',
    format('settling 期間改 occurred_on 應 void，實際 %s', (select status from public.settlements s where s.id = v_s.id));
end;
$$;
rollback;

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
begin
  perform public.approve_settlement(current_setting('app.test_settlement', true)::uuid);
end;
$$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 應失敗：已結帳的帳目不能搬日期（會讓統計與歷史結算對不上，ADR-0002）。
  begin
    update public.entries set occurred_on = occurred_on - 40
      where id = '40000000-0000-0000-0000-000000000005';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settled 的 entry 竟然改得動 occurred_on';
  assert v_err like '%occurred_on locked%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== settlement: 沒有可結算的 entry 時應 raise（應失敗） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 先把代墊筆全部改成共同錢包出，讓候選集合為空。
  update public.entries set payer_id = null, split_method = 'common'
   where ledger_id = '10000000-0000-0000-0000-000000000001' and payer_id is not null and scope = 'shared';
  begin
    perform public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '沒有可結算的 entry 竟然還能發起';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== settlement: 非成員不能發起（應失敗） =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  begin
    perform public.initiate_settlement('10000000-0000-0000-0000-000000000001');
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員竟然能對別人的帳本發起結算';
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo 'settlement.sql PASS'
