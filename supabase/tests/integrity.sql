-- 結構完整性測試：跨帳本 FK、分攤守恆 constraint、併發唯一性、索引與邀請碼（review 13／14／16／18／19／22）
-- 這一檔多數以 postgres 身分跑：要驗的是「即使繞過 RLS，資料層本身也擋得住」。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set WIFE_M '20000000-0000-0000-0000-000000000002'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set CAT '30000000-0000-0000-0000-000000000001'

\echo '== integrity: 結構前置檢查（索引、唯一鍵、constraint trigger）=='
do $$
begin
  -- review 13：同一帳本只能有一個 pending settlement。
  assert exists (select 1 from pg_indexes
                 where schemaname = 'public' and indexname = 'settlements_one_pending_per_ledger_idx'),
    '缺少 pending settlement 的 partial unique index';
  -- review 22：category_id 是 on delete restrict，沒索引刪分類會全表掃。
  assert exists (select 1 from pg_index x
                 join pg_class i on i.oid = x.indexrelid
                 join pg_class t on t.oid = x.indrelid
                 join pg_attribute a on a.attrelid = t.oid and a.attnum = x.indkey[0]
                 where t.relname = 'entries' and a.attname = 'category_id'),
    'entries.category_id 缺索引';
  -- review 14：分攤守恆是 deferred constraint trigger。
  assert exists (select 1 from pg_trigger
                 where tgname = 'entry_splits_sum_check_trg' and tgconstraint <> 0 and tgdeferrable),
    'entry_splits 缺 deferred constraint trigger';
  -- review 18：複合 FK 的被參照唯一鍵。
  assert (select count(*) from pg_constraint
          where conname in ('categories_id_ledger_key', 'members_id_ledger_key', 'entries_id_ledger_key')) = 3,
    '缺少 (id, ledger_id) 唯一鍵';
end;
$$;

\echo '== integrity: 同一帳本不能有兩個 pending settlement（應失敗，review 13）=='
begin;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  insert into public.settlements (ledger_id, initiated_by, nets, status)
  values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '{}'::jsonb, 'pending');
  begin
    insert into public.settlements (ledger_id, initiated_by, nets, status)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', '{}'::jsonb, 'pending');
  exception when unique_violation then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '同一帳本竟然能同時有兩個 pending settlement';
  raise notice '  預期的失敗：%', v_err;

  -- 但 void／settled 的舊結算不受限（partial index 只管 pending）。
  update public.settlements set status = 'void'
    where ledger_id = '10000000-0000-0000-0000-000000000001' and status = 'pending';
  insert into public.settlements (ledger_id, initiated_by, nets, status)
  values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', '{}'::jsonb, 'pending');
  assert (select count(*) from public.settlements where status = 'pending') = 1,
    '結掉舊的之後應該可以再開一個';
end;
$$;
rollback;

\echo '== integrity: 分攤加總必須等於主筆金額（deferred constraint，review 14）=='
begin;
do $$
declare
  v_entry uuid;
  v_blocked boolean := false;
  v_err text;
begin
  -- 先建 entry、再建 splits（同交易）是允許的流程，deferred 就是為了這個。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 1000,
          '30000000-0000-0000-0000-000000000001', current_date, '守恆測試',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'amount')
  returning id into v_entry;

  -- 加總不符：deferred 所以此刻不報，要等 commit（或 set constraints immediate）。
  insert into public.entry_splits (entry_id, member_id, share) values
    (v_entry, '20000000-0000-0000-0000-000000000001', 100.00),
    (v_entry, '20000000-0000-0000-0000-000000000002', 100.00);
  begin
    execute 'set constraints all immediate';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '分攤加總不符竟然沒被 constraint 擋下';
  assert v_err like '%do not sum to amount%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

begin;
do $$
declare
  v_entry uuid;
begin
  -- 對照組①：加總相符 → 通過。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 1000,
          '30000000-0000-0000-0000-000000000001', current_date, '守恆測試 ok',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'amount')
  returning id into v_entry;
  insert into public.entry_splits (entry_id, member_id, share) values
    (v_entry, '20000000-0000-0000-0000-000000000001', 400.00),
    (v_entry, '20000000-0000-0000-0000-000000000002', 600.00);
  execute 'set constraints all immediate';

  -- 對照組②：把分攤全部清掉（改走共同錢包）→ 也要能過，不能被守恆卡死。
  delete from public.entry_splits where entry_id = v_entry;
  execute 'set constraints all immediate';
  assert not exists (select 1 from public.entry_splits s where s.entry_id = v_entry), '分攤應可清空';
end;
$$;
rollback;

\echo '== integrity: 只改金額不動分攤，交易結束時要 raise（review I）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- e-5 是 567、分攤 283.50×2。只改金額不動分攤 → 守恆被破壞。
  -- 修前只有 entry_splits 側有守恆，這種改法一路過關，要到發起結算才被擋。
  update public.entries set amount = 99999 where id = '40000000-0000-0000-0000-000000000005';
  begin
    execute 'set constraints all immediate';
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '只改金額不動分攤竟然過關了（entries 側沒有守恆）';
  assert v_err like '%do not sum to amount%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== integrity: upsert_entry 同交易改金額＋分攤（review I）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_e public.entries;
begin
  -- 改金額同時把分攤重寫，走 RPC 一個交易做完 → 守恆成立。
  v_e := public.upsert_entry(
    jsonb_build_object(
      'id', '40000000-0000-0000-0000-000000000005',
      'ledger_id', '10000000-0000-0000-0000-000000000001',
      'amount', 1000),
    jsonb_build_array(
      jsonb_build_object('member_id', '20000000-0000-0000-0000-000000000001', 'share', 400),
      jsonb_build_object('member_id', '20000000-0000-0000-0000-000000000002', 'share', 600)),
    jsonb_build_array(
      jsonb_build_object('name', '雞蛋', 'amount', 89),
      jsonb_build_object('name', '牛奶', 'amount', 95))
  );
  execute 'set constraints all immediate';

  assert v_e.amount = 1000, format('金額應改成 1000，實際 %s', v_e.amount);
  assert (select sum(s.share) from public.entry_splits s where s.entry_id = v_e.id) = 1000.00,
    '分攤應重寫成合計 1000';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_e.id) = 2, '分攤應為兩列';
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 2,
    '細項應全刪重建成兩列';
  assert v_e.settled_state = 'open', 'upsert_entry 不該動到 settled_state';
  assert v_e.created_by = '20000000-0000-0000-0000-000000000001'::uuid, 'created_by 不該被改';
end;
$$;
rollback;

\echo '== integrity: upsert_entry 的 null＝不動子表、[]＝清空（review K）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_e public.entries;
begin
  -- e-5 種子狀態：2 列分攤、3 列細項。
  assert (select count(*) from public.entry_splits s where s.entry_id = '40000000-0000-0000-0000-000000000005') = 2,
    '前置條件：e-5 應有 2 列分攤';
  assert (select count(*) from public.line_items li where li.entry_id = '40000000-0000-0000-0000-000000000005') = 3,
    '前置條件：e-5 應有 3 列細項';

  -- 只帶 note、不帶子表 → 兩張子表都不該被動到。
  -- （舊版兩個參數預設 '[]'，這樣呼叫會把分攤與細項全部清光。）
  v_e := public.upsert_entry(jsonb_build_object(
    'id', '40000000-0000-0000-0000-000000000005',
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'note', '只改備註'));
  execute 'set constraints all immediate';

  assert v_e.note = '只改備註', '備註應該有改到';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_e.id) = 2,
    format('沒帶 p_splits 就不該動分攤，實際剩 %s 列',
           (select count(*) from public.entry_splits s where s.entry_id = v_e.id));
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 3,
    format('沒帶 p_line_items 就不該動細項，實際剩 %s 列',
           (select count(*) from public.line_items li where li.entry_id = v_e.id));

  -- 明確帶 [] 才是清空，而且只清帶到的那一張。
  v_e := public.upsert_entry(
    jsonb_build_object('id', '40000000-0000-0000-0000-000000000005',
                       'ledger_id', '10000000-0000-0000-0000-000000000001'),
    null, '[]'::jsonb);
  execute 'set constraints all immediate';
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 0,
    '帶 [] 應該把細項清空';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_e.id) = 2,
    '沒帶 p_splits，分攤仍不該被動到';
end;
$$;
rollback;

\echo '== integrity: 已結帳的帳目只改備註，兩張子表都不動（review K）=='
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
  v_e public.entries;
begin
  assert (select settled_state from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = 'settled',
    '前置條件：e-5 應已 settled';

  -- 已結帳的帳目仍可改備註／分類／細項（ADR-0002）。
  -- 舊版會連帶把分攤刪掉（被 policy 擋成 0 列）卻把細項真的刪掉，兩張子表行為不對稱。
  v_e := public.upsert_entry(jsonb_build_object(
    'id', '40000000-0000-0000-0000-000000000005',
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'note', '結帳後補註'));
  execute 'set constraints all immediate';

  assert v_e.note = '結帳後補註', '已結帳的帳目應該還能改備註';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_e.id) = 2,
    '已結帳的分攤不該被動到';
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 3,
    '已結帳的細項不該被動到';
end;
$$;
rollback;

\echo '== integrity: 同交易改壞再改回來，commit 應該過（review L）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
begin
  -- deferred trigger 若拿事件當下的 NEW 去比對，這裡會誤擋；
  -- 改成 commit 時重讀當前列就不會。
  update public.entries set amount = 99999 where id = '40000000-0000-0000-0000-000000000005';
  update public.entries set amount = 567   where id = '40000000-0000-0000-0000-000000000005';
  execute 'set constraints all immediate';
  assert (select amount from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = 567,
    '金額應回到 567';
end;
$$;
rollback;

\echo '== integrity: upsert_entry 新增一筆帶分攤的帳目 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_e public.entries;
  v_blocked boolean := false;
  v_err text;
begin
  v_e := public.upsert_entry(
    jsonb_build_object(
      'ledger_id', '10000000-0000-0000-0000-000000000001',
      'kind', 'expense', 'scope', 'shared', 'amount', 300,
      'category_id', '30000000-0000-0000-0000-000000000001',
      'occurred_on', current_date, 'note', '走 RPC 新增',
      'payer_id', '20000000-0000-0000-0000-000000000002',
      'split_method', 'equal'),
    jsonb_build_array(
      jsonb_build_object('member_id', '20000000-0000-0000-0000-000000000001', 'share', 150),
      jsonb_build_object('member_id', '20000000-0000-0000-0000-000000000002', 'share', 150)),
    '[]'::jsonb);
  execute 'set constraints all immediate';

  assert v_e.created_by = '20000000-0000-0000-0000-000000000002'::uuid,
    'created_by 應強制為呼叫者自己的 member id';
  assert v_e.settled_state = 'open', '新增的帳目一定是 open';
  assert (select count(*) from public.entry_splits s where s.entry_id = v_e.id) = 2, '分攤應寫入兩列';

  -- 應失敗：非成員的帳本。
  begin
    perform public.upsert_entry(jsonb_build_object('ledger_id', gen_random_uuid(), 'kind', 'expense',
                                                   'amount', 1, 'category_id', '30000000-0000-0000-0000-000000000001',
                                                   'occurred_on', current_date));
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '非成員的帳本竟然寫得進去';
  assert v_err like '%not a member%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== integrity: 跨帳本引用一律擋（應失敗，review 18）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_other public.ledgers;
begin
  v_other := public.create_ledger('別人的帳本');
  perform set_config('app.other_ledger', v_other.id::text, true);
  perform set_config('app.other_category',
    (select c.id::text from public.categories c where c.ledger_id = v_other.id order by c.sort limit 1), true);
  perform set_config('app.other_member',
    (select m.id::text from public.members m where m.ledger_id = v_other.id limit 1), true);
end;
$$;
reset role;
do $$
declare
  v_other_cat uuid := current_setting('app.other_category', true)::uuid;
  v_other_member uuid := current_setting('app.other_member', true)::uuid;
  v_entry uuid;
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：拿別的帳本的分類記帳。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                                created_by, split_method)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 100,
            v_other_cat, current_date, '跨帳本分類',
            '20000000-0000-0000-0000-000000000001', 'common');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能用別的帳本的分類記帳';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：拿別的帳本的成員當付款人。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                                created_by, payer_id, split_method)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 100,
            '30000000-0000-0000-0000-000000000001', current_date, '跨帳本付款人',
            '20000000-0000-0000-0000-000000000001', v_other_member, 'equal');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能用別的帳本的成員當付款人';

  -- 應失敗③：把別的帳本的成員塞進分攤。
  insert into public.entries (ledger_id, kind, scope, amount, category_id, occurred_on, note,
                              created_by, payer_id, split_method)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 'shared', 100,
          '30000000-0000-0000-0000-000000000001', current_date, '跨帳本分攤',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'equal')
  returning id into v_entry;
  v_blocked := false;
  begin
    insert into public.entry_splits (entry_id, member_id, share) values (v_entry, v_other_member, 100.00);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能把別的帳本的成員塞進分攤';
  assert v_err like '%another ledger%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗④：清單項目掛別的帳本的分類。
  v_blocked := false;
  begin
    insert into public.list_items (ledger_id, title, category_id)
    values ('10000000-0000-0000-0000-000000000001', '跨帳本清單', v_other_cat);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '清單竟然能掛別的帳本的分類';

  -- 應失敗⑤：撥款掛別的帳本的分類。
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', v_other_cat, 100, current_date,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '撥款竟然能掛別的帳本的分類';
  assert v_err like '%budget_allocation_category_same_ledger%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗⑥：settlement_entries 收別的帳本的 entry。
  v_blocked := false;
  begin
    insert into public.settlements (id, ledger_id, initiated_by, nets, status)
    values ('99999999-9999-9999-9999-999999999999',
            current_setting('app.other_ledger', true)::uuid, v_other_member, '{}'::jsonb, 'pending');
    insert into public.settlement_entries (settlement_id, entry_id)
    values ('99999999-9999-9999-9999-999999999999', v_entry);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, 'settlement 竟然能涵蓋別的帳本的 entry';
  assert v_err like '%another ledger%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== integrity: 0017 的 drop→backfill→add 順序（review P）=='
begin;
-- 重現「套用 0017 之前」的環境：拿掉新 check、把所有帳本降回 6 碼、裝回舊的 6 碼 check。
alter table public.ledgers drop constraint ledgers_invite_code_check;
update public.ledgers set invite_code = 'A7K3QZ' where id = '10000000-0000-0000-0000-000000000001';
insert into public.ledgers (id, name, invite_code, default_ratio)
values ('bbbb0000-0000-0000-0000-00000000000f', '舊帳本', 'B8L4RY', '{}'::jsonb);
alter table public.ledgers add constraint ledgers_invite_code_check check (invite_code ~ '^[A-Z0-9]{6}$');

do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 錯的順序（先 backfill 再 drop）：舊的 6 碼 check 還在，寫 10 碼一定被擋。
  begin
    update public.ledgers set invite_code = public.gen_invite_code()
     where invite_code !~ '^[A-Z0-9]{10}$';
  exception when check_violation then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '舊 check 還在的情況下，backfill 竟然沒被擋（那 P 就不是問題了）';
  raise notice '  這就是 P：先 backfill 再 drop 會炸 → %', v_err;
end;
$$;

do $$
declare
  v_code text;
begin
  -- 正確順序：drop → backfill → add，就是 0017 現在的寫法。
  alter table public.ledgers drop constraint if exists ledgers_invite_code_check;
  update public.ledgers set invite_code = public.gen_invite_code()
   where invite_code !~ '^[A-Z0-9]{10}$';
  alter table public.ledgers add constraint ledgers_invite_code_check
    check (invite_code ~ '^[A-Z0-9]{10}$');

  select invite_code into v_code from public.ledgers where id = 'bbbb0000-0000-0000-0000-00000000000f';
  assert v_code ~ '^[A-Z0-9]{10}$', format('舊帳本的邀請碼應被補成 10 碼，實際 %s', v_code);
  assert v_code <> 'B8L4RY', '舊邀請碼應該被換掉（這也是 O 記在已知風險的那件事）';
  assert (select count(*) from public.ledgers where invite_code !~ '^[A-Z0-9]{10}$') = 0,
    '所有帳本的邀請碼都該補成 10 碼';
end;
$$;
rollback;

\echo '== integrity: 已結帳的帳目不接受重寫子表（應失敗，review Q）=='
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
  v_blocked boolean;
  v_err text;
  v_e public.entries;
begin
  assert (select settled_state from public.entries e where e.id = '40000000-0000-0000-0000-000000000005') = 'settled',
    '前置條件：e-5 應已 settled';

  -- 應失敗①：帶 p_line_items。修前這會「分攤被 policy 擋成 0 列而保住、細項真的被刪掉」，
  -- 一半成功一半失敗而且沒有任何錯誤訊息。
  v_blocked := false;
  begin
    perform public.upsert_entry(
      jsonb_build_object('id', '40000000-0000-0000-0000-000000000005',
                         'ledger_id', '10000000-0000-0000-0000-000000000001'),
      null, '[]'::jsonb);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已結帳的帳目竟然能重寫細項';
  assert v_err like '%child tables locked%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：帶 p_splits 也一樣。
  v_blocked := false;
  begin
    perform public.upsert_entry(
      jsonb_build_object('id', '40000000-0000-0000-0000-000000000005',
                         'ledger_id', '10000000-0000-0000-0000-000000000001'),
      '[]'::jsonb, null);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '已結帳的帳目竟然能重寫分攤';

  -- 子表都沒被動到（沒有半套狀態）。
  assert (select count(*) from public.entry_splits s where s.entry_id = '40000000-0000-0000-0000-000000000005') = 2,
    '分攤不該被動到';
  assert (select count(*) from public.line_items li where li.entry_id = '40000000-0000-0000-0000-000000000005') = 3,
    '細項不該被動到';

  -- 對照組：子表都不帶（null）只改備註，仍然可以。
  v_e := public.upsert_entry(jsonb_build_object(
    'id', '40000000-0000-0000-0000-000000000005',
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'note', '結帳後補註'));
  assert v_e.note = '結帳後補註', '已結帳的帳目應該還能改備註';
end;
$$;
rollback;

\echo '== integrity: 邀請碼 10 碼、CSPRNG、不重複（review 19）=='
begin;
do $$
declare
  v_codes text[];
begin
  select array_agg(public.gen_invite_code()) into v_codes from generate_series(1, 50);
  assert (select bool_and(c ~ '^[A-Z0-9]{10}$') from unnest(v_codes) c),
    '邀請碼格式應為 10 碼大寫英數';
  assert (select count(distinct c) from unnest(v_codes) c) = 50, '50 次抽樣不該出現重複';
  assert (select bool_and(c !~ '[01IO]') from unnest(v_codes) c),
    '邀請碼不該含易混淆字元 0/1/I/O';
  assert (select invite_code from public.ledgers where id = '10000000-0000-0000-0000-000000000001') = 'A7K3QZM4XB',
    '種子邀請碼應為 10 碼';
end;
$$;
rollback;

\echo 'integrity.sql PASS'
